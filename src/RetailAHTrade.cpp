/*
 * mod-retail-ah: requests that move items or money.
 *
 *   Q   quote a commodity purchase   -> QR:<req>:<entry>:<units found>:<total>:<capped>
 *   B   buy a commodity quantity     -> BR:<req>:<status>:<units bought>:<spent>:<units found>:<total>
 *   P   bid on / buy out one auction -> PR:<req>:<status>
 *   X   cancel an own auction        -> XR:<req>:<status>
 *   D   deposit preview for a post   -> DR:<req>:<deposit>:<available>:<stack size>
 *   PC  post a commodity             -> POR:<req>:<created>:<requested>:<status>
 *   PI  post copies of an item       -> POR:<req>:<created>:<requested>:<status>
 *
 * Buyouts, bids, cancels and posts are built into the stock client packets and handed to the
 * core's handlers, which re-check everything and do the bookkeeping. The module then looks at
 * the auction house to see whether the handler went through, since handlers don't return.
 * The one exception is buying part of a stack (BuyPart), which the stock protocol can't ask for.
 */

#include "RetailAH.h"
#include "AuctionHouseMgr.h"
#include "Bag.h"
#include "DatabaseEnv.h"
#include "Item.h"
#include "Log.h"
#include "ObjectMgr.h"
#include "Opcodes.h"
#include "Player.h"
#include "RBAC.h"
#include "ScriptMgr.h"
#include "World.h"
#include "WorldPacket.h"
#include "WorldSession.h"
#include <algorithm>
#include <array>

namespace RetailAH
{
    namespace
    {
        // Set while the sell handler runs, so the auction it creates can be picked up.
        bool sCapturing = false;
        ObjectGuid sCaptureOwner;
        std::vector<uint32> sCaptured;

        // Most auctions one purchase request may touch. Each whole auction bought is its own
        // transaction and three mails; the stock client can't do more than this per tick either.
        constexpr std::size_t MAX_TAKES = 100;

        struct Take
        {
            uint32 auctionId;  // looked up again when bought; earlier purchases free auctions
            uint32 count;      // less than the auction's count means the stack gets split
            uint32 price;
        };

        // What part of a stack costs: the seller's price for those units, rounded up.
        uint32 PartPrice(AuctionEntry const* auction, uint32 count)
        {
            return uint32((uint64(auction->buyout) * count + auction->itemCount - 1) / auction->itemCount);
        }

        // Cheapest units first, as retail fills a commodity order. Own auctions (any character on
        // the account) are skipped, since the core refuses them. `capped` is set when the plan
        // stopped at MAX_TAKES auctions rather than at the end of the listings.
        uint32 PlanPurchase(Context const& ctx, uint32 entry, uint32 quantity, std::vector<Take>& plan, uint64& total, bool& capped)
        {
            capped = false;
            VisibilityCache visibility(ctx.player);
            std::vector<AuctionEntry*> candidates;
            for (auto const& [id, auction] : ctx.house->GetAuctions())
            {
                if (auction->item_template != entry || !auction->buyout || !auction->itemCount)
                    continue;
                if (!visibility.Visible(auction) || IsOwnAuction(ctx.player, auction))
                    continue;
                candidates.push_back(auction);
            }

            std::sort(candidates.begin(), candidates.end(), [](AuctionEntry const* a, AuctionEntry const* b)
            {
                uint64 left = uint64(a->buyout) * b->itemCount;
                uint64 right = uint64(b->buyout) * a->itemCount;
                return left != right ? left < right : a->Id < b->Id;
            });

            plan.clear();
            total = 0;
            uint32 remaining = quantity;
            for (AuctionEntry* auction : candidates)
            {
                if (!remaining)
                    break;
                if (plan.size() >= MAX_TAKES)
                {
                    capped = true;
                    break;
                }

                if (auction->itemCount <= remaining)
                {
                    plan.push_back({ auction->Id, auction->itemCount, auction->buyout });
                    total += auction->buyout;
                    remaining -= auction->itemCount;
                    continue;
                }

                // A bid covers the whole stack, so a stack someone has bid on can't be split.
                if (auction->bidder)
                    continue;

                // The part left behind must still cost something.
                uint32 price = PartPrice(auction, remaining);
                if (!price || price >= auction->buyout)
                    continue;

                plan.push_back({ auction->Id, remaining, price });
                total += price;
                remaining = 0;
            }

            return quantity - remaining;
        }

        // Buys out a whole auction through the core. True when it's gone from the house.
        bool BuyOut(Context const& ctx, AuctionEntry* auction)
        {
            uint32 id = auction->Id;
            WorldPacket packet(CMSG_AUCTION_PLACE_BID, 8 + 4 + 4);
            packet << ctx.auctioneer->GetGUID();
            packet << uint32(id);
            packet << uint32(auction->buyout);
            ctx.player->GetSession()->HandleAuctionPlaceBid(packet);
            return !ctx.house->GetAuction(id);
        }

        // Buys `count` units out of a bigger stack. The seller's auction is replaced by one for
        // the rest of the stack (new id; same unit price, expiry and the rest of the deposit), and
        // the bought part is settled the way the core settles a buyout: sale-pending and payment
        // mails to the seller, the item by mail to the buyer, the house cut, the achievement
        // criteria and the OnAuctionSuccessful hook. The bought part never becomes a listed
        // auction, and everything, the split included, goes out in one transaction.
        // The caller has checked what the core's bid handler would: visible, not the player's
        // own, and affordable.
        bool BuyPart(Context const& ctx, AuctionEntry* auction, uint32 count, uint32 price)
        {
            Player* player = ctx.player;
            Item* item = sAuctionMgr->GetAItem(auction->item_guid);
            if (!item || !count || count >= auction->itemCount || item->GetCount() != auction->itemCount
                || auction->bidder || !player->HasEnoughMoney(price))
                return false;

            Item* part = item->CloneItem(count, nullptr);
            if (!part)
                return false;
            // CreateItem clamps to the item's current stack size, which can be smaller than what
            // was listed (mod-stack-size turned down): never charge for units that don't exist.
            if (part->GetCount() != count)
            {
                delete part;
                return false;
            }
            // Straight to the buyer, as the won mail would set it.
            part->SetOwnerGUID(player->GetGUID());

            uint32 const total = auction->itemCount;
            uint32 const partDeposit = uint32((uint64(auction->deposit) * count) / total);
            uint32 const partStart = std::min(price, std::max<uint32>(1, uint32((uint64(auction->startbid) * count) / total)));

            item->SetCount(total - count);
            // Auction items are loaded without an owner; the row must keep the seller's.
            item->SetOwnerGUID(auction->owner);
            item->SetState(ITEM_CHANGED, nullptr);

            AuctionEntry* rest = new AuctionEntry(*auction);
            rest->Id = sObjectMgr->GenerateAuctionID();
            rest->itemCount = total - count;
            rest->buyout = auction->buyout - price;
            rest->startbid = std::min(rest->buyout, auction->startbid > partStart ? auction->startbid - partStart : 1u);
            rest->deposit = auction->deposit - partDeposit;

            // Only lives for the mails and hooks below; never added to the house.
            AuctionEntry sold(*auction);
            sold.Id = sObjectMgr->GenerateAuctionID();
            sold.item_guid = part->GetGUID();
            sold.itemCount = count;
            sold.startbid = partStart;
            sold.buyout = price;
            sold.deposit = partDeposit;
            sold.bidder = player->GetGUID();
            sold.bid = price;

            CharacterDatabaseTransaction trans = CharacterDatabase.BeginTransaction();
            auction->DeleteFromDB(trans);
            item->SaveToDB(trans);
            rest->SaveToDB(trans);
            part->SaveToDB(trans);

            player->ModifyMoney(-int32(price));
            player->UpdateAchievementCriteria(ACHIEVEMENT_CRITERIA_TYPE_HIGHEST_AUCTION_BID, price);

            // The mails find the item through the auction manager, as for a listed auction.
            sAuctionMgr->AddAItem(part);
            sAuctionMgr->SendAuctionSalePendingMail(&sold, trans);
            sAuctionMgr->SendAuctionSuccessfulMail(&sold, trans);
            sAuctionMgr->SendAuctionWonMail(&sold, trans);
            sScriptMgr->OnAuctionSuccessful(ctx.house, &sold);
            sAuctionMgr->RemoveAItem(part->GetGUID());

            player->SaveInventoryAndGoldToDB(trans);
            CharacterDatabase.CommitTransaction(trans);

            if (player->GetSession()->HasPermission(rbac::RBAC_PERM_LOG_GM_TRADE))
            {
                LOG_GM(player->GetSession()->GetAccountId(), "GM {} (Account: {}) bought {} of auction: {} (Item: {} Count: {}) Price: {}",
                    player->GetName(), player->GetSession()->GetAccountId(), count, auction->Id, auction->item_template, total, price);
            }

            LOG_INFO("entities.player.auctionhouse", "AuctionHouse: Account: {}, Player [{}] (GUID: {}) bought {} of auction #{}: Item (Entry: {}) x{}, "
                "Price: {} copper, Owner GUID: {}; the other {} stay listed as auction #{}",
                player->GetSession()->GetAccountId(), player->GetName(), player->GetGUID().GetCounter(), count, auction->Id,
                auction->item_template, total, price, auction->owner.GetCounter(), rest->itemCount, rest->Id);

            // RemoveAuction deletes `auction`; its item stays registered and now belongs to `rest`.
            ctx.house->RemoveAuction(auction);
            ctx.house->AddAuction(rest);
            return true;
        }

        // ---- posting ---------------------------------------------------------------------------

        // The client's bag numbering: 0 is the backpack, 1-4 the equipped bags; slots from 1.
        Item* ItemAt(Player* player, uint32 bag, uint32 slot)
        {
            if (!slot)
                return nullptr;
            if (bag == 0)
            {
                if (slot > uint32(INVENTORY_SLOT_ITEM_END - INVENTORY_SLOT_ITEM_START))
                    return nullptr;
                return player->GetItemByPos(INVENTORY_SLOT_BAG_0, uint8(INVENTORY_SLOT_ITEM_START + slot - 1));
            }
            if (bag > uint32(INVENTORY_SLOT_BAG_END - INVENTORY_SLOT_BAG_START) || slot > MAX_BAG_SIZE)
                return nullptr;
            return player->GetItemByPos(uint8(INVENTORY_SLOT_BAG_START + bag - 1), uint8(slot - 1));
        }

        // The sell handler's own checks, so the preview and the post agree on what can go up.
        bool Postable(Item const* item)
        {
            return item && !sAuctionMgr->GetAItem(item->GetGUID()) && item->CanBeTraded() && !item->IsNotEmptyBag()
                && !item->IsInTrade() && !item->GetTemplate()->HasFlag(ITEM_FLAG_CONJURED)
                && !item->GetUInt32Value(ITEM_FIELD_DURATION);
        }

        // Which bag items count as "the same" as the one being posted. For gear the random
        // suffix must match too; commodities never have one.
        // Enchants and socketed gems count too, so a second copy with Crusader on it is never
        // posted at the plain copy's price.
        struct ItemKind
        {
            uint32 entry;
            int32 randomPropertyId;
            uint32 suffixFactor;
            bool exact;
            std::array<uint32, MAX_ENCHANTMENT_SLOT> enchants {};

            ItemKind(Item const* item, bool exact) : entry(item->GetEntry()), randomPropertyId(item->GetItemRandomPropertyId()),
                suffixFactor(item->GetItemSuffixFactor()), exact(exact)
            {
                for (uint8 slot = 0; slot < MAX_ENCHANTMENT_SLOT; ++slot)
                    enchants[slot] = item->GetEnchantmentId(EnchantmentSlot(slot));
            }

            bool Matches(Item const* item) const
            {
                if (item->GetEntry() != entry)
                    return false;
                if (!exact)
                    return true;
                if (item->GetItemRandomPropertyId() != randomPropertyId || item->GetItemSuffixFactor() != suffixFactor)
                    return false;
                for (uint8 slot = 0; slot < MAX_ENCHANTMENT_SLOT; ++slot)
                    if (item->GetEnchantmentId(EnchantmentSlot(slot)) != enchants[slot])
                        return false;
                return true;
            }
        };

        // Every postable item of that kind in the backpack and equipped bags.
        std::vector<Item*> BagItems(Player* player, ItemKind const& kind)
        {
            std::vector<Item*> items;
            auto consider = [&](Item* item)
            {
                if (item && kind.Matches(item) && Postable(item))
                    items.push_back(item);
            };

            for (uint8 slot = INVENTORY_SLOT_ITEM_START; slot < INVENTORY_SLOT_ITEM_END; ++slot)
                consider(player->GetItemByPos(INVENTORY_SLOT_BAG_0, slot));

            for (uint8 bagSlot = INVENTORY_SLOT_BAG_START; bagSlot < INVENTORY_SLOT_BAG_END; ++bagSlot)
                if (Bag* bag = player->GetBagByPos(bagSlot))
                    for (uint32 slot = 0; slot < bag->GetBagSize(); ++slot)
                        consider(bag->GetItemByPos(uint8(slot)));

            return items;
        }

        uint32 CountUnits(std::vector<Item*> const& items)
        {
            uint32 units = 0;
            for (Item const* item : items)
                units += item->GetCount();
            return units;
        }

        // The sell handler refuses more than 1000 of anything per item (mod-stack-size can raise
        // stacks past that), so a commodity auction never holds more.
        uint32 AuctionStack(ItemTemplate const* proto)
        {
            return std::min<uint32>(proto->GetMaxStackSize(), 1000);
        }

        bool ParseHours(std::string_view text, uint32& hours)
        {
            return ParseUInt(text, hours) && (hours == 12 || hours == 24 || hours == 48);
        }

        // Hands one auction's worth of items to the core. Returns the new auction's id, or 0.
        uint32 Sell(Context const& ctx, std::vector<std::pair<Item*, uint32>> const& picks, uint32 bid, uint32 buyout, uint32 hours)
        {
            WorldPacket packet(CMSG_AUCTION_SELL_ITEM, 8 + 4 + picks.size() * 12 + 12);
            packet << ctx.auctioneer->GetGUID();
            packet << uint32(picks.size());
            for (auto const& [item, count] : picks)
            {
                packet << item->GetGUID();
                packet << uint32(count);
            }
            packet << uint32(bid);
            packet << uint32(buyout);
            packet << uint32(hours * 60);  // the client sends minutes

            sCapturing = true;
            sCaptureOwner = ctx.player->GetGUID();
            sCaptured.clear();
            ctx.player->GetSession()->HandleAuctionSellItem(packet);
            sCapturing = false;

            return sCaptured.empty() ? 0 : sCaptured.front();
        }

        void SendPostResult(Context const& ctx, uint32 created, uint32 requested, std::string_view status)
        {
            Send(ctx.player, "POR:" + ctx.req + ":" + std::to_string(created) + ":" + std::to_string(requested)
                + ":" + std::string(status));
        }
    }

    void OnAuctionAdded(AuctionEntry const* auction)
    {
        if (sCapturing && auction && auction->owner == sCaptureOwner)
            sCaptured.push_back(auction->Id);
    }

    // Q:<req>:<entry>:<quantity>
    void HandleQuote(Context& ctx, std::vector<std::string_view> const& args)
    {
        uint32 entry = 0, quantity = 0;
        if (args.size() < 4 || !ParseUInt(args[2], entry) || !ParseUInt(args[3], quantity) || !quantity)
        {
            SendError(ctx, "bad");
            return;
        }

        std::vector<Take> plan;
        uint64 total = 0;
        bool capped = false;
        uint32 found = PlanPurchase(ctx, entry, quantity, plan, total, capped);
        Send(ctx.player, "QR:" + ctx.req + ":" + std::to_string(entry) + ":" + std::to_string(found) + ":" + std::to_string(total)
            + ":" + (capped ? "1" : "0"));
    }

    // B:<req>:<entry>:<quantity>:<most the player agreed to pay>
    // Status: ok, partial (some purchases failed), short (not enough listed any more),
    // price (the total went up since the quote), money.
    void HandleCommodityBuy(Context& ctx, std::vector<std::string_view> const& args)
    {
        uint32 entry = 0, quantity = 0;
        uint64 maxTotal = 0;
        uint32 maxLow = 0;
        if (args.size() < 5 || !ParseUInt(args[2], entry) || !ParseUInt(args[3], quantity) || !quantity
            || !ParseUInt(args[4], maxLow))
        {
            SendError(ctx, "bad");
            return;
        }
        maxTotal = maxLow;

        std::vector<Take> plan;
        uint64 total = 0;
        bool capped = false;
        uint32 found = PlanPurchase(ctx, entry, quantity, plan, total, capped);

        auto reply = [&](std::string_view status, uint32 bought, uint64 spent)
        {
            Send(ctx.player, "BR:" + ctx.req + ":" + std::string(status) + ":" + std::to_string(bought) + ":"
                + std::to_string(spent) + ":" + std::to_string(found) + ":" + std::to_string(total));
        };

        if (found < quantity)
            return reply("short", 0, 0);
        if (total > maxTotal)
            return reply("price", 0, 0);
        if (total > MAX_MONEY_AMOUNT || !ctx.player->HasEnoughMoney(uint32(total)))
            return reply("money", 0, 0);
        // The core's bid handler refuses trial accounts; BuyPart doesn't go through it.
        if (sWorld->getBoolConfig(CONFIG_TRIAL_RESTRICTION_AUCTION) && ctx.player->GetSession()->IsTrialAccount())
            return reply("fail", 0, 0);

        uint32 bought = 0;
        uint64 spent = 0;
        for (Take const& take : plan)
        {
            AuctionEntry* auction = ctx.house->GetAuction(take.auctionId);
            if (!auction)
                continue;
            bool done = take.count < auction->itemCount
                ? BuyPart(ctx, auction, take.count, take.price)
                : BuyOut(ctx, auction);
            if (done)
            {
                bought += take.count;
                spent += take.price;
            }
        }

        reply(bought == quantity ? "ok" : "partial", bought, spent);
    }

    // P:<req>:<auction id>:<price>   A price at or above the buyout buys it out.
    void HandlePlaceBid(Context& ctx, std::vector<std::string_view> const& args)
    {
        uint32 id = 0, price = 0;
        if (args.size() < 4 || !ParseUInt(args[2], id) || !ParseUInt(args[3], price) || !price)
        {
            SendError(ctx, "bad");
            return;
        }

        AuctionEntry* auction = ctx.house->GetAuction(id);
        if (!auction)
        {
            Send(ctx.player, "PR:" + ctx.req + ":gone");
            return;
        }
        if (auction->buyout && price > auction->buyout)
            price = auction->buyout;

        WorldPacket packet(CMSG_AUCTION_PLACE_BID, 8 + 4 + 4);
        packet << ctx.auctioneer->GetGUID();
        packet << uint32(id);
        packet << uint32(price);
        ctx.player->GetSession()->HandleAuctionPlaceBid(packet);

        auction = ctx.house->GetAuction(id);
        std::string status = "fail";
        if (!auction)
            status = "bought";
        else if (auction->bidder == ctx.player->GetGUID() && auction->bid == price)
            status = "bid";
        Send(ctx.player, "PR:" + ctx.req + ":" + status);
    }

    // X:<req>:<auction id>
    void HandleCancel(Context& ctx, std::vector<std::string_view> const& args)
    {
        uint32 id = 0;
        if (args.size() < 3 || !ParseUInt(args[2], id))
        {
            SendError(ctx, "bad");
            return;
        }

        AuctionEntry* auction = ctx.house->GetAuction(id);
        if (!auction || auction->owner != ctx.player->GetGUID())
        {
            Send(ctx.player, "XR:" + ctx.req + ":gone");
            return;
        }

        WorldPacket packet(CMSG_AUCTION_REMOVE_ITEM, 8 + 4);
        packet << ctx.auctioneer->GetGUID();
        packet << uint32(id);
        ctx.player->GetSession()->HandleAuctionRemoveItem(packet);

        Send(ctx.player, "XR:" + ctx.req + ":" + (ctx.house->GetAuction(id) ? "fail" : "ok"));
    }

    // D:<req>:<bag>:<slot>:<quantity>:<hours>
    // Commodities go up in full stacks plus one remainder, other items one per auction; the
    // deposit is the sum the sell handler will charge for exactly that.
    void HandleDeposit(Context& ctx, std::vector<std::string_view> const& args)
    {
        uint32 bag = 0, slot = 0, quantity = 0, hours = 0;
        if (args.size() < 6 || !ParseUInt(args[2], bag) || !ParseUInt(args[3], slot) || !ParseUInt(args[4], quantity)
            || !ParseHours(args[5], hours))
        {
            SendError(ctx, "bad");
            return;
        }

        Item* item = ItemAt(ctx.player, bag, slot);
        if (!Postable(item))
        {
            Send(ctx.player, "DR:" + ctx.req + ":0:0:0");
            return;
        }

        bool commodity = IsCommodity(item->GetTemplate());
        std::vector<Item*> items = BagItems(ctx.player, ItemKind(item, !commodity));
        uint32 stack = AuctionStack(item->GetTemplate());
        uint32 available = commodity ? CountUnits(items) : uint32(items.size());
        quantity = std::min(quantity, available);

        uint64 deposit = 0;
        uint32 seconds = hours * HOUR;
        if (commodity)
        {
            for (uint32 left = quantity; left; )
            {
                uint32 count = std::min(left, stack);
                deposit += AuctionHouseMgr::GetAuctionDeposit(ctx.houseEntry, seconds, item, count);
                left -= count;
            }
        }
        else
        {
            for (uint32 i = 0; i < quantity; ++i)
                deposit += AuctionHouseMgr::GetAuctionDeposit(ctx.houseEntry, seconds, items[i], items[i]->GetCount());
        }

        Send(ctx.player, "DR:" + ctx.req + ":" + std::to_string(deposit) + ":" + std::to_string(available) + ":"
            + std::to_string(stack));
    }

    // PC:<req>:<bag>:<slot>:<quantity>:<unit price>:<hours>
    // Posts `quantity` units of the item at bag/slot, gathered from every stack in the bags, as
    // full stacks plus a remainder. Buyout only: the starting bid equals the buyout.
    void HandlePostCommodity(Context& ctx, std::vector<std::string_view> const& args)
    {
        uint32 bag = 0, slot = 0, quantity = 0, unitPrice = 0, hours = 0;
        if (args.size() < 7 || !ParseUInt(args[2], bag) || !ParseUInt(args[3], slot) || !ParseUInt(args[4], quantity)
            || !ParseUInt(args[5], unitPrice) || !ParseHours(args[6], hours) || !quantity || !unitPrice)
        {
            SendError(ctx, "bad");
            return;
        }

        Item* first = ItemAt(ctx.player, bag, slot);
        if (!Postable(first) || !IsCommodity(first->GetTemplate()))
            return SendPostResult(ctx, 0, 0, "item");

        // `first` itself may be merged into an auction and deleted, so remember what it was.
        ItemKind const kind(first, false);
        uint32 const stack = AuctionStack(first->GetTemplate());
        if (uint64(unitPrice) * std::min(quantity, stack) > MAX_MONEY_AMOUNT)
            return SendPostResult(ctx, 0, 0, "price");

        if (CountUnits(BagItems(ctx.player, kind)) < quantity)
            return SendPostResult(ctx, 0, 0, "count");

        uint32 const requested = (quantity + stack - 1) / stack;
        uint32 created = 0;
        std::string status = "ok";
        for (uint32 left = quantity; left; )
        {
            uint32 count = std::min(left, stack);

            // Rescan each time: the handler deletes or shrinks the stacks it takes from.
            std::vector<Item*> items = BagItems(ctx.player, kind);

            // Small stacks first, which tidies the bags as a side effect.
            std::stable_sort(items.begin(), items.end(), [](Item const* a, Item const* b) { return a->GetCount() < b->GetCount(); });

            std::vector<std::pair<Item*, uint32>> picks;
            uint32 gathered = 0;
            for (Item* it : items)
            {
                if (gathered == count || picks.size() >= MAX_AUCTION_ITEMS)
                    break;
                uint32 take = std::min(it->GetCount(), count - gathered);
                picks.emplace_back(it, take);
                gathered += take;
            }
            if (gathered < count)
            {
                status = "count";
                break;
            }

            uint32 buyout = unitPrice * count;
            uint32 deposit = AuctionHouseMgr::GetAuctionDeposit(ctx.houseEntry, hours * HOUR, picks.front().first, count);
            if (!ctx.player->HasEnoughMoney(deposit))
            {
                status = "money";
                break;
            }

            if (!Sell(ctx, picks, buyout, buyout, hours))
            {
                status = "fail";
                break;
            }

            ++created;
            left -= count;
        }

        SendPostResult(ctx, created, requested, status);
    }

    // PI:<req>:<bag>:<slot>:<quantity>:<bid>:<buyout>:<hours>
    // Posts the item at bag/slot, and then identical ones from the bags until `quantity`
    // auctions are up, each with this bid and buyout (buyout 0 = bid only).
    void HandlePostItem(Context& ctx, std::vector<std::string_view> const& args)
    {
        uint32 bag = 0, slot = 0, quantity = 0, bid = 0, buyout = 0, hours = 0;
        if (args.size() < 8 || !ParseUInt(args[2], bag) || !ParseUInt(args[3], slot) || !ParseUInt(args[4], quantity)
            || !ParseUInt(args[5], bid) || !ParseUInt(args[6], buyout) || !ParseHours(args[7], hours) || !quantity)
        {
            SendError(ctx, "bad");
            return;
        }

        if (!bid || bid > MAX_MONEY_AMOUNT || buyout > MAX_MONEY_AMOUNT || (buyout && buyout < bid))
            return SendPostResult(ctx, 0, 0, "price");

        Item* first = ItemAt(ctx.player, bag, slot);
        if (!Postable(first) || IsCommodity(first->GetTemplate()))
            return SendPostResult(ctx, 0, 0, "item");

        std::vector<Item*> items = BagItems(ctx.player, ItemKind(first, true));
        // The one the player picked goes first.
        std::stable_partition(items.begin(), items.end(), [first](Item const* it) { return it == first; });
        if (items.size() < quantity)
            return SendPostResult(ctx, 0, 0, "count");

        uint32 created = 0;
        std::string status = "ok";
        for (uint32 i = 0; i < quantity; ++i)
        {
            Item* item = items[i];
            uint32 deposit = AuctionHouseMgr::GetAuctionDeposit(ctx.houseEntry, hours * HOUR, item, item->GetCount());
            if (!ctx.player->HasEnoughMoney(deposit))
            {
                status = "money";
                break;
            }
            if (!Sell(ctx, { { item, item->GetCount() } }, bid, buyout, hours))
            {
                status = "fail";
                break;
            }
            ++created;
        }

        SendPostResult(ctx, created, quantity, status);
    }
}
