/*
 * mod-retail-ah: read-only requests.
 *
 *   S   search              -> SR:<req>:<groups>:<truncated>, SD rows, SE
 *   F   favorites lookup    -> the same answer as a search, one group per asked entry
 *   C   commodity tiers     -> CR:<req>:<entry>, CD rows, CE
 *   I   one item's auctions -> IR:<req>:<entry>:<look state>, ID rows, IE
 *   O   own auctions        -> OR, OD rows, OE
 *   BL  auctions bid on     -> LR, LD rows, LE
 *
 * Search groups every visible auction by item entry, like retail's browse list. A commodity
 * (anything that stacks) is priced per unit; other items by their cheapest buyout.
 */

#include "RetailAH.h"
#include "AuctionHouseMgr.h"
#include "CharacterCache.h"
#include "DBCStores.h"
#include "GameTime.h"
#include "Item.h"
#include "ObjectMgr.h"
#include "Player.h"
#include "ScriptMgr.h"
#include "Util.h"
#include "WorldSession.h"
#include <algorithm>
#include <map>
#include <unordered_set>

namespace RetailAH
{
    bool VisibilityCache::Visible(AuctionEntry* auction)
    {
        auto itr = _seen.find(auction->item_template);
        if (itr != _seen.end())
            return itr->second;

        bool visible = sScriptMgr->OnPlayerCanPlaceAuctionBid(_player, auction);
        _seen.emplace(auction->item_template, visible);
        return visible;
    }

    bool IsCommodity(ItemTemplate const* proto)
    {
        return proto && proto->GetMaxStackSize() > 1;
    }

    uint32 TimeLeft(AuctionEntry const* auction)
    {
        time_t now = GameTime::GetGameTime().count();
        return auction->expire_time > now ? uint32(auction->expire_time - now) : 0;
    }

    bool IsOwnAuction(Player* player, AuctionEntry const* auction)
    {
        if (auction->owner == player->GetGUID())
            return true;
        // Always by account: the core assumes an online owner can't be on this account, but a
        // playerbots alt logged in as a bot can be.
        return sCharacterCache->GetCharacterAccountIdByGuid(auction->owner) == player->GetSession()->GetAccountId();
    }

    namespace
    {
        enum GroupFlags : uint32
        {
            GROUP_COMMODITY = 0x1,
            GROUP_BID_ONLY  = 0x2,  // nothing has a buyout; the price is the cheapest bid
            GROUP_OWN       = 0x4,
            GROUP_UNCOLLECTED = 0x8,  // a mod-transmog-plus look the account doesn't have
        };

        enum SearchFlags : uint32
        {
            SEARCH_USABLE = 0x1,
            SEARCH_EXACT  = 0x2,
            SEARCH_UNCOLLECTED = 0x4,  // only appearances the account hasn't collected
        };

        enum AuctionFlags : uint32
        {
            AUCTION_OWN        = 0x1,
            AUCTION_HIGH_BIDDER = 0x2,  // the player holds the current bid
            AUCTION_HAS_BID    = 0x4,
        };

        // Lower-cased item names per locale; item templates don't change while the server runs.
        std::unordered_map<uint32, std::wstring> sNames[TOTAL_LOCALES];

        std::wstring const& ItemName(ItemTemplate const* proto, LocaleConstant locale)
        {
            std::unordered_map<uint32, std::wstring>& names = sNames[locale < TOTAL_LOCALES ? locale : LOCALE_enUS];
            auto itr = names.find(proto->ItemId);
            if (itr != names.end())
                return itr->second;

            std::string name = proto->Name1;
            if (ItemLocale const* il = sObjectMgr->GetItemLocale(proto->ItemId))
                ObjectMgr::GetLocaleString(il->Name, locale, name);

            std::wstring wname;
            if (Utf8toWStr(name, wname))
                wstrToLower(wname);
            return names.emplace(proto->ItemId, std::move(wname)).first->second;
        }

        // " of the monkey": ItemRandomProperties for positive ids, ItemRandomSuffix for negative.
        // Cached per id and locale; there are only a few hundred of them.
        std::unordered_map<int32, std::wstring> sSuffixes[TOTAL_LOCALES];

        std::wstring const& SuffixName(Item const* item, LocaleConstant dbcLocale)
        {
            int32 id = item->GetItemRandomPropertyId();
            std::unordered_map<int32, std::wstring>& cache = sSuffixes[dbcLocale < TOTAL_LOCALES ? dbcLocale : LOCALE_enUS];
            auto itr = cache.find(id);
            if (itr != cache.end())
                return itr->second;

            char const* suffix = nullptr;
            if (id < 0)
            {
                if (ItemRandomSuffixEntry const* entry = sItemRandomSuffixStore.LookupEntry(uint32(-id)))
                    suffix = entry->Name[dbcLocale];
            }
            else if (id > 0)
            {
                if (ItemRandomPropertiesEntry const* entry = sItemRandomPropertiesStore.LookupEntry(uint32(id)))
                    suffix = entry->Name[dbcLocale];
            }

            std::wstring wsuffix;
            if (suffix && *suffix && Utf8toWStr(std::string(" ") + suffix, wsuffix))
                wstrToLower(wsuffix);
            return cache.emplace(id, std::move(wsuffix)).first->second;
        }

        struct Filter
        {
            uint32 flags = 0;
            uint32 minLevel = 0;
            uint32 maxLevel = 0;
            uint32 qualityMask = 0;  // bit per quality; 0 = any
            int32 itemClass = -1;
            int32 itemSubClass = -1;
            int32 inventoryType = -1;
            std::wstring name;
        };

        bool MatchesTemplate(Filter const& filter, ItemTemplate const* proto, Player* player)
        {
            if (filter.itemClass >= 0 && proto->Class != uint32(filter.itemClass))
                return false;
            if (filter.itemSubClass >= 0 && proto->SubClass != uint32(filter.itemSubClass))
                return false;
            if (filter.inventoryType >= 0 && proto->InventoryType != uint32(filter.inventoryType))
            {
                // Robes are listed with chests, as in the stock search.
                if (filter.inventoryType != INVTYPE_CHEST || proto->InventoryType != INVTYPE_ROBE)
                    return false;
            }
            if (filter.qualityMask && !(filter.qualityMask & (1u << proto->Quality)))
                return false;
            if (filter.minLevel && proto->RequiredLevel < filter.minLevel)
                return false;
            if (filter.maxLevel && proto->RequiredLevel > filter.maxLevel)
                return false;
            if ((filter.flags & SEARCH_USABLE) && player->CanUseItem(proto) != EQUIP_ERR_OK)
                return false;
            if ((filter.flags & SEARCH_UNCOLLECTED) && Appearances::State(player, proto) != Appearances::Look::Uncollected)
                return false;
            return true;
        }

        bool NameMatches(Filter const& filter, std::wstring const& name)
        {
            if (filter.flags & SEARCH_EXACT)
                return name == filter.name;
            return name.find(filter.name) != std::wstring::npos;
        }

        bool HasRandomName(ItemTemplate const* proto)
        {
            return proto->RandomProperty || proto->RandomSuffix;
        }

        struct Group
        {
            ItemTemplate const* proto = nullptr;
            uint64 minPrice = 0;  // per unit for commodities; 0 = no buyout seen yet
            uint64 minBid = 0;
            uint32 units = 0;
            uint32 auctions = 0;
            bool own = false;
        };

        uint64 UnitPrice(AuctionEntry const* auction)
        {
            uint32 count = std::max<uint32>(1, auction->itemCount);
            return (uint64(auction->buyout) + count - 1) / count;
        }

        uint32 CurrentBid(AuctionEntry const* auction)
        {
            return auction->bid ? auction->bid : auction->startbid;
        }

        uint32 MinimumBid(AuctionEntry const* auction)
        {
            return auction->bid ? auction->bid + auction->GetAuctionOutBid() : auction->startbid;
        }

        void AddToGroup(Group& group, AuctionEntry const* auction, Player* player)
        {
            bool commodity = IsCommodity(group.proto);
            group.units += auction->itemCount;
            ++group.auctions;
            if (auction->owner == player->GetGUID())
                group.own = true;

            if (auction->buyout)
            {
                uint64 price = commodity ? UnitPrice(auction) : auction->buyout;
                if (!group.minPrice || price < group.minPrice)
                    group.minPrice = price;
            }
            else
            {
                uint64 bid = CurrentBid(auction);
                if (commodity)
                    bid = (bid + auction->itemCount - 1) / std::max<uint32>(1, auction->itemCount);
                if (!group.minBid || bid < group.minBid)
                    group.minBid = bid;
            }
        }

        std::string GroupRow(Group const& group, Player const* player)
        {
            uint32 flags = 0;
            if (IsCommodity(group.proto))
                flags |= GROUP_COMMODITY;
            if (group.own)
                flags |= GROUP_OWN;
            if (Appearances::State(player, group.proto) == Appearances::Look::Uncollected)
                flags |= GROUP_UNCOLLECTED;

            uint64 price = group.minPrice;
            if (!price && group.auctions)
            {
                price = group.minBid;
                flags |= GROUP_BID_ONLY;
            }

            return std::to_string(group.proto->ItemId) + "," + std::to_string(price) + "," + std::to_string(group.units)
                + "," + std::to_string(group.auctions) + "," + std::to_string(flags);
        }

        void SendGroups(Context const& ctx, std::vector<Group const*> const& groups, bool truncated)
        {
            std::vector<std::string> rows;
            rows.reserve(groups.size());
            for (Group const* group : groups)
                rows.push_back(GroupRow(*group, ctx.player));

            Send(ctx.player, "SR:" + ctx.req + ":" + std::to_string(rows.size()) + ":" + (truncated ? "1" : "0"));
            SendRows(ctx.player, "SD:" + ctx.req, rows);
            Send(ctx.player, "SE:" + ctx.req);
        }

        std::string ItemIdentity(Item const* item)
        {
            if (!item)
                return "0,0";
            return std::to_string(item->GetItemRandomPropertyId()) + "," + std::to_string(item->GetItemSuffixFactor());
        }

        void SendList(Context const& ctx, std::string const& code, std::string const& meta, std::vector<std::string> const& rows)
        {
            Send(ctx.player, code + "R:" + ctx.req + (meta.empty() ? "" : ":" + meta));
            SendRows(ctx.player, code + "D:" + ctx.req, rows);
            Send(ctx.player, code + "E:" + ctx.req);
        }
    }

    // S:<req>:<flags>:<minLevel>:<maxLevel>:<qualityMask>:<class>:<subclass>:<invType>:<name>
    void HandleSearch(Context& ctx, std::vector<std::string_view> const& args)
    {
        Filter filter;
        if (args.size() < 10 || !ParseUInt(args[2], filter.flags) || !ParseUInt(args[3], filter.minLevel)
            || !ParseUInt(args[4], filter.maxLevel) || !ParseUInt(args[5], filter.qualityMask)
            || !ParseInt(args[6], filter.itemClass) || !ParseInt(args[7], filter.itemSubClass)
            || !ParseInt(args[8], filter.inventoryType))
        {
            SendError(ctx, "bad");
            return;
        }

        std::string name(args[9].substr(0, 100));
        if (!name.empty() && !Utf8toWStr(name, filter.name))
        {
            SendError(ctx, "bad");
            return;
        }
        wstrToLower(filter.name);

        Player* player = ctx.player;
        LocaleConstant locale = player->GetSession()->GetSessionDbLocaleIndex();
        LocaleConstant dbcLocale = player->GetSession()->GetSessionDbcLocale();
        VisibilityCache visibility(player);

        // Per entry: does the template pass the filters, and does its plain name match?
        struct Verdict { bool passes; bool nameMatches; };
        std::unordered_map<uint32, Verdict> verdicts;
        std::unordered_map<uint32, Group> groups;

        for (auto const& [id, auction] : ctx.house->GetAuctions())
        {
            auto vItr = verdicts.find(auction->item_template);
            if (vItr == verdicts.end())
            {
                ItemTemplate const* proto = sObjectMgr->GetItemTemplate(auction->item_template);
                Verdict verdict { false, false };
                if (proto && MatchesTemplate(filter, proto, player) && visibility.Visible(auction))
                {
                    verdict.passes = true;
                    verdict.nameMatches = filter.name.empty() || NameMatches(filter, ItemName(proto, locale));
                    // A random-suffix item can still match on its suffix, auction by auction.
                    if (!verdict.nameMatches && !HasRandomName(proto))
                        verdict.passes = false;
                }
                vItr = verdicts.emplace(auction->item_template, verdict).first;
            }

            if (!vItr->second.passes)
                continue;

            if (!vItr->second.nameMatches)
            {
                Item* item = sAuctionMgr->GetAItem(auction->item_guid);
                if (!item)
                    continue;
                std::wstring const& suffix = SuffixName(item, dbcLocale);
                ItemTemplate const* proto = sObjectMgr->GetItemTemplate(auction->item_template);
                if (suffix.empty() || !NameMatches(filter, ItemName(proto, locale) + suffix))
                    continue;
            }

            Group& group = groups[auction->item_template];
            if (!group.proto)
                group.proto = sObjectMgr->GetItemTemplate(auction->item_template);
            AddToGroup(group, auction, player);
        }

        // Alphabetical, so a capped result is a predictable slice; the addon re-sorts anyway.
        // Names are looked up once, and only the part that is sent gets fully sorted.
        std::vector<std::pair<std::wstring const*, Group const*>> named;
        named.reserve(groups.size());
        for (auto const& [entry, group] : groups)
            named.emplace_back(&ItemName(group.proto, locale), &group);

        auto byName = [](auto const& a, auto const& b)
        {
            return *a.first != *b.first ? *a.first < *b.first : a.second->proto->ItemId < b.second->proto->ItemId;
        };
        std::size_t const limit = GetConfig().maxResults;
        bool truncated = named.size() > limit;
        if (truncated)
        {
            std::partial_sort(named.begin(), named.begin() + limit, named.end(), byName);
            named.resize(limit);
        }
        else
            std::sort(named.begin(), named.end(), byName);

        std::vector<Group const*> sorted;
        sorted.reserve(named.size());
        for (auto const& [name, group] : named)
            sorted.push_back(group);

        SendGroups(ctx, sorted, truncated);
    }

    // F:<req>:<entry>,<entry>,...   Entries with nothing listed come back with zero available.
    void HandleFavorites(Context& ctx, std::vector<std::string_view> const& args)
    {
        std::unordered_map<uint32, Group> groups;
        std::vector<uint32> order;
        if (args.size() >= 3)
        {
            for (std::string_view token : Split(args[2], ','))
            {
                uint32 entry = 0;
                if (!ParseUInt(token, entry) || groups.count(entry) || order.size() >= 100)
                    continue;
                ItemTemplate const* proto = sObjectMgr->GetItemTemplate(entry);
                if (!proto)
                    continue;
                groups[entry].proto = proto;
                order.push_back(entry);
            }
        }

        VisibilityCache visibility(ctx.player);
        for (auto const& [id, auction] : ctx.house->GetAuctions())
        {
            auto itr = groups.find(auction->item_template);
            if (itr == groups.end() || !visibility.Visible(auction))
                continue;
            AddToGroup(itr->second, auction, ctx.player);
        }

        std::vector<Group const*> list;
        for (uint32 entry : order)
            list.push_back(&groups[entry]);
        SendGroups(ctx, list, false);
    }

    // C:<req>:<entry>   Rows: <unit price>,<units>,<own units>, cheapest first. Only auctions
    // with a buyout, since commodities are bought, never bid on.
    void HandleCommodityDetails(Context& ctx, std::vector<std::string_view> const& args)
    {
        uint32 entry = 0;
        if (args.size() < 3 || !ParseUInt(args[2], entry))
        {
            SendError(ctx, "bad");
            return;
        }

        struct Tier { uint32 units = 0; uint32 own = 0; };
        std::map<uint64, Tier> tiers;
        VisibilityCache visibility(ctx.player);

        for (auto const& [id, auction] : ctx.house->GetAuctions())
        {
            if (auction->item_template != entry || !auction->buyout || !visibility.Visible(auction))
                continue;
            Tier& tier = tiers[UnitPrice(auction)];
            tier.units += auction->itemCount;
            if (auction->owner == ctx.player->GetGUID())
                tier.own += auction->itemCount;
        }

        std::vector<std::string> rows;
        for (auto const& [price, tier] : tiers)
        {
            if (rows.size() >= GetConfig().maxDetailRows)
                break;
            rows.push_back(std::to_string(price) + "," + std::to_string(tier.units) + "," + std::to_string(tier.own));
        }

        SendList(ctx, "C", std::to_string(entry), rows);
    }

    // I:<req>:<entry>   Rows: <id>,<count>,<current bid>,<minimum bid>,<buyout>,<seconds left>,
    // <flags>,<random property id>,<suffix factor>; cheapest buyout first, bid-only last.
    void HandleItemDetails(Context& ctx, std::vector<std::string_view> const& args)
    {
        uint32 entry = 0;
        if (args.size() < 3 || !ParseUInt(args[2], entry))
        {
            SendError(ctx, "bad");
            return;
        }

        VisibilityCache visibility(ctx.player);
        std::vector<AuctionEntry*> auctions;
        for (auto const& [id, auction] : ctx.house->GetAuctions())
            if (auction->item_template == entry && visibility.Visible(auction))
                auctions.push_back(auction);

        std::sort(auctions.begin(), auctions.end(), [](AuctionEntry const* a, AuctionEntry const* b)
        {
            if (!a->buyout != !b->buyout)
                return a->buyout != 0;
            // Per unit, so a stack of five isn't shown after a single that costs more each.
            uint64 pa = a->buyout ? UnitPrice(a) : MinimumBid(a);
            uint64 pb = b->buyout ? UnitPrice(b) : MinimumBid(b);
            return pa != pb ? pa < pb : a->Id < b->Id;
        });

        std::vector<std::string> rows;
        for (AuctionEntry const* auction : auctions)
        {
            if (rows.size() >= GetConfig().maxDetailRows)
                break;

            uint32 flags = 0;
            if (IsOwnAuction(ctx.player, auction))
                flags |= AUCTION_OWN;
            if (auction->bidder)
                flags |= AUCTION_HAS_BID;
            if (auction->bidder == ctx.player->GetGUID())
                flags |= AUCTION_HIGH_BIDDER;

            rows.push_back(std::to_string(auction->Id) + "," + std::to_string(auction->itemCount) + ","
                + std::to_string(CurrentBid(auction)) + "," + std::to_string(MinimumBid(auction)) + ","
                + std::to_string(auction->buyout) + "," + std::to_string(TimeLeft(auction)) + ","
                + std::to_string(flags) + "," + ItemIdentity(sAuctionMgr->GetAItem(auction->item_guid)));
        }

        // Meta: entry and the look's state (0 not an appearance, 1 collected, 2 not collected).
        ItemTemplate const* proto = sObjectMgr->GetItemTemplate(entry);
        SendList(ctx, "I", std::to_string(entry) + ":" + std::to_string(uint32(Appearances::State(ctx.player, proto))), rows);
    }

    // O:<req>   Rows: <id>,<entry>,<count>,<current bid>,<buyout>,<seconds left>,<flags>,<rp>,<sf>
    void HandleOwned(Context& ctx)
    {
        std::vector<AuctionEntry*> auctions;
        for (auto const& [id, auction] : ctx.house->GetAuctions())
            if (auction->owner == ctx.player->GetGUID())
                auctions.push_back(auction);

        std::sort(auctions.begin(), auctions.end(), [](AuctionEntry const* a, AuctionEntry const* b)
        {
            return a->expire_time != b->expire_time ? a->expire_time < b->expire_time : a->Id < b->Id;
        });

        std::vector<std::string> rows;
        for (AuctionEntry const* auction : auctions)
        {
            uint32 flags = AUCTION_OWN | (auction->bidder ? AUCTION_HAS_BID : 0);
            rows.push_back(std::to_string(auction->Id) + "," + std::to_string(auction->item_template) + ","
                + std::to_string(auction->itemCount) + "," + std::to_string(CurrentBid(auction)) + ","
                + std::to_string(auction->buyout) + "," + std::to_string(TimeLeft(auction)) + ","
                + std::to_string(flags) + "," + ItemIdentity(sAuctionMgr->GetAItem(auction->item_guid)));
        }

        SendList(ctx, "O", "", rows);
    }

    // BL:<req>   Rows: <id>,<entry>,<count>,<bid>,<minimum bid>,<buyout>,<seconds left>,<rp>,<sf>
    void HandleBids(Context& ctx)
    {
        std::vector<std::string> rows;
        for (auto const& [id, auction] : ctx.house->GetAuctions())
        {
            if (auction->bidder != ctx.player->GetGUID())
                continue;
            rows.push_back(std::to_string(auction->Id) + "," + std::to_string(auction->item_template) + ","
                + std::to_string(auction->itemCount) + "," + std::to_string(auction->bid) + ","
                + std::to_string(MinimumBid(auction)) + "," + std::to_string(auction->buyout) + ","
                + std::to_string(TimeLeft(auction)) + "," + ItemIdentity(sAuctionMgr->GetAItem(auction->item_guid)));
        }

        SendList(ctx, "L", "", rows);
    }
}
