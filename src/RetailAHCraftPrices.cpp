/*
 * mod-retail-ah: auction house prices for the RetailProfessions addon's profit view, which
 * suggests what to craft and sell. Asked from the profession window, so no auctioneer is needed;
 * the prices are the house of the player's own faction (the neutral one with two-side trading).
 *
 *   K:<req>:<entry>,<entry>,...   at most MAX_ENTRIES
 *     -> KR:<req>:<house cut %>:<history days>
 *        KD rows <entry>,<lowest buyout per unit>,<units listed>,<AH bot pays>,<vendor price>,
 *                <vendor pays>,<units traded>,<copper traded>,<flags>
 *        KE:<req>
 *
 * - The lowest buyout and the units leave out the player's own auctions (and their alts'), so
 *   the answer is what they compete with. 0 when nothing is listed.
 * - AH bot pays: what mod-ah-bot-plus's buyer takes on every look (RetailAHBot.cpp), 0 when it
 *   doesn't buy the item or isn't running.
 * - Vendor price: what a vendor sells it for, when one sells it without limit or tokens (thread,
 *   vials, flux); 0 otherwise. Vendor pays: what a vendor gives for one.
 * - Traded: every auction of the item that sold in the last HISTORY_DAYS days, to anyone, read
 *   from the gold ledger at startup and kept up in memory since. Without the ledger only what
 *   sold since startup.
 * - flags 1: the era gate hides the item from this player and they own none, so no auction
 *   prices. The level gate doesn't apply: a crafter prices what they make, whatever level it
 *   needs. flags 2: it binds when picked up (or is a quest item), so it can't be auctioned.
 */

#include "RetailAH.h"
#include "AuctionHouseMgr.h"
#include "DatabaseEnv.h"
#include "GameTime.h"
#include "Log.h"
#include "ObjectMgr.h"
#include "Player.h"
#include <deque>
#include <unordered_map>
#include <unordered_set>

namespace RetailAH::CraftPrices
{
    namespace
    {
        constexpr std::size_t MAX_ENTRIES = 40;
        constexpr uint32 HISTORY_DAYS = 14;

        enum RowFlags : uint32
        {
            ROW_LOCKED = 0x1,
            ROW_SOULBOUND = 0x2,
        };

        struct Trade
        {
            uint32 time;
            uint32 count;
            uint32 price;
        };

        // Item entry -> its sales in the window, oldest first.
        std::unordered_map<uint32, std::deque<Trade>> sHistory;

        // Items a vendor sells without a stock limit or an extended cost.
        std::unordered_set<uint32> sVendorItems;

        uint32 Now()
        {
            return uint32(GameTime::GetGameTime().count());
        }

        uint32 Cutoff()
        {
            uint32 now = Now();
            return now > HISTORY_DAYS * DAY ? now - HISTORY_DAYS * DAY : 0;
        }

        void Prune(std::deque<Trade>& trades, uint32 cutoff)
        {
            while (!trades.empty() && trades.front().time < cutoff)
                trades.pop_front();
        }
    }

    void Load()
    {
        sVendorItems.clear();
        if (QueryResult result = WorldDatabase.Query("SELECT DISTINCT item FROM npc_vendor WHERE maxcount = 0 AND ExtendedCost = 0"))
        {
            do
                sVendorItems.insert(result->Fetch()[0].Get<uint32>());
            while (result->NextRow());
        }

        // The ledger has a row for every sale with a player on either side: the seller's "sold"
        // row, or, for an AH bot's auction, the buyer's "bought" row. Bots sell to players only
        // through the latter, and a sale between two players has both, so take one of each.
        sHistory.clear();
        if (!GetConfig().ledger)
            return;
        QueryResult result = CharacterDatabase.Query("SELECT time, kind, item, count, gross, other FROM mod_retail_ah_ledger "
            "WHERE time >= {} AND kind IN (1, 2) ORDER BY time", Cutoff());
        if (!result)
            return;
        uint32 loaded = 0;
        do
        {
            Field* fields = result->Fetch();
            uint8 kind = fields[1].Get<uint8>();
            if (kind == 2 && !AhBot::IsBot(fields[5].Get<uint32>()))
                continue;
            sHistory[fields[2].Get<uint32>()].push_back({ fields[0].Get<uint32>(), fields[3].Get<uint32>(), fields[4].Get<uint32>() });
            ++loaded;
        } while (result->NextRow());
        LOG_INFO("module", "mod-retail-ah: {} auction sales of the last {} days loaded for craft prices.", loaded, HISTORY_DAYS);
    }

    // Every auction that ends in a sale, from the auction won mail hook. Trades between two AH
    // bots aren't a market; leave them out, as the ledger does.
    void OnSold(AuctionEntry const* auction)
    {
        if (!auction || !auction->bid)
            return;
        if (AhBot::IsBot(auction->owner.GetCounter()) && AhBot::IsBot(auction->bidder.GetCounter()))
            return;
        std::deque<Trade>& trades = sHistory[auction->item_template];
        Prune(trades, Cutoff());
        trades.push_back({ Now(), std::max<uint32>(1, auction->itemCount), auction->bid });
    }

    void HandlePrices(Context& ctx, std::vector<std::string_view> const& args)
    {
        Player* player = ctx.player;
        AuctionHouseEntry const* houseEntry = AuctionHouseMgr::GetAuctionHouseEntryFromFactionTemplate(player->GetFaction());
        AuctionHouseObject* house = sAuctionMgr->GetAuctionsMap(player->GetFaction());
        if (args.size() < 3 || !houseEntry || !house)
        {
            SendError(ctx, "bad");
            return;
        }

        struct Price
        {
            ItemTemplate const* proto = nullptr;
            bool locked = false;
            uint64 lowest = 0;
            uint32 units = 0;
        };

        std::vector<uint32> order;
        std::unordered_map<uint32, Price> prices;
        Gate::View view(player);
        for (std::string_view text : Split(args[2], ','))
        {
            uint32 entry = 0;
            if (!ParseUInt(text, entry) || prices.count(entry))
                continue;
            if (order.size() >= MAX_ENTRIES)
                break;
            ItemTemplate const* proto = sObjectMgr->GetItemTemplate(entry);
            if (!proto)
                continue;
            Price& price = prices[entry];
            price.proto = proto;
            price.locked = view.Check(proto).era && !view.Owns(entry);
            order.push_back(entry);
        }

        for (auto const& [id, auction] : house->GetAuctions())
        {
            if (!auction->buyout)
                continue;
            auto itr = prices.find(auction->item_template);
            if (itr == prices.end() || itr->second.locked || IsOwnAuction(player, auction))
                continue;
            uint32 count = std::max<uint32>(1, auction->itemCount);
            uint64 unit = (uint64(auction->buyout) + count - 1) / count;
            Price& price = itr->second;
            if (!price.lowest || unit < price.lowest)
                price.lowest = unit;
            price.units += auction->itemCount;
        }

        uint32 const cutoff = Cutoff();
        std::vector<std::string> rows;
        for (uint32 entry : order)
        {
            Price const& price = prices[entry];
            ItemTemplate const* proto = price.proto;
            uint32 flags = (price.locked ? ROW_LOCKED : 0)
                | (proto->Bonding == BIND_WHEN_PICKED_UP || proto->Bonding == BIND_QUEST_ITEM ? ROW_SOULBOUND : 0);
            uint32 vendor = sVendorItems.count(entry) ? proto->BuyPrice : 0;

            uint64 botAlways = 0, botUpTo = 0;
            uint64 tradedUnits = 0, tradedCopper = 0;
            if (!price.locked)
            {
                AhBot::BuyRange(proto, botAlways, botUpTo);
                auto hist = sHistory.find(entry);
                if (hist != sHistory.end())
                {
                    Prune(hist->second, cutoff);
                    for (Trade const& trade : hist->second)
                    {
                        tradedUnits += trade.count;
                        tradedCopper += trade.price;
                    }
                }
            }

            rows.push_back(std::to_string(entry) + "," + std::to_string(price.lowest) + "," + std::to_string(price.units) + ","
                + std::to_string(botAlways) + "," + std::to_string(vendor) + "," + std::to_string(proto->SellPrice) + ","
                + std::to_string(tradedUnits) + "," + std::to_string(tradedCopper) + "," + std::to_string(flags));
        }

        Send(player, "KR:" + ctx.req + ":" + std::to_string(houseEntry->cutPercent) + ":" + std::to_string(HISTORY_DAYS));
        SendRows(player, "KD:" + ctx.req, rows);
        Send(player, "KE:" + ctx.req);
    }
}
