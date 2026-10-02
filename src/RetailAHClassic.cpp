/*
 * mod-retail-ah: the classic auction window's search, through the same gates as RetailAH's.
 * (Moved from mod-ah-progression, which this module replaces.)
 *
 * The core has no hook inside its auction search, and that search runs on worker threads over
 * its own copy of the auctions. So for a player who has something to hide, CMSG_AUCTION_LIST_ITEMS
 * is taken over in CanPacketReceive: the request is parsed and queued exactly as
 * WorldSession::HandleAuctionListItems would, and the world thread answers it in
 * WorldScript::OnUpdate using the core's own SearchableAuctionEntry / AuctionSorter, so the
 * results look the same as the core's except for the hidden items. Paging and the "N items"
 * total are computed after filtering, so there are no empty pages.
 *
 * Everyone else (GMs, excluded accounts, players past every gate) keeps the core search. Bids on
 * hidden auctions are refused in RetailAHGate.cpp.
 *
 * Released under the MIT License.
 */

#include "RetailAH.h"
#include "AuctionHouseMgr.h"
#include "AuctionHouseSearcher.h"
#include "CharacterCache.h"
#include "Creature.h"
#include "Item.h"
#include "ObjectAccessor.h"
#include "Opcodes.h"
#include "Player.h"
#include "ScriptMgr.h"
#include "SpellAuraDefines.h"
#include "Util.h"
#include "WorldPacket.h"
#include "WorldSession.h"
#include <algorithm>
#include <mutex>
#include <vector>

using namespace RetailAH;

namespace
{
    struct PendingSearch
    {
        ObjectGuid playerGuid;
        AuctionHouseId houseId;
        Gate::View view;
        AuctionHouseSearchInfo searchInfo;
        AuctionHousePlayerInfo playerInfo;
    };

    std::mutex sPendingLock;
    std::vector<PendingSearch> sPending;

    // Mirror of the core searcher's per-auction snapshot, built lazily the first time a filtered
    // search sees an auction and dropped by OnAuctionRemove. Only touched on the world thread
    // (OnUpdate and the auction hooks both run there); the lock is belt and braces.
    std::mutex sCacheLock;
    std::unordered_map<uint32, std::unique_ptr<SearchableAuctionEntry>> sEntryCache;

    SearchableAuctionEntry* GetSearchableEntry(AuctionEntry const* auction)
    {
        auto itr = sEntryCache.find(auction->Id);
        if (itr != sEntryCache.end())
        {
            // The only thing that changes on a live auction.
            itr->second->bid = auction->bid;
            itr->second->bidderGuid = auction->bidder;
            return itr->second.get();
        }

        Item* item = sAuctionMgr->GetAItem(auction->item_guid);
        if (!item)
            return nullptr;

        // Same fields AuctionHouseSearcher::AddAuction fills in.
        auto entry = std::make_unique<SearchableAuctionEntry>();
        entry->Id = auction->Id;
        entry->ownerGuid = auction->owner;
        sCharacterCache->GetCharacterNameByGuid(auction->owner, entry->ownerName);
        entry->startbid = auction->startbid;
        entry->buyout = auction->buyout;
        entry->expire_time = auction->expire_time;
        entry->listFaction = auction->GetFactionId();
        entry->bid = auction->bid;
        entry->bidderGuid = auction->bidder;

        entry->item.entry = item->GetEntry();
        for (uint8 i = 0; i < MAX_INSPECTED_ENCHANTMENT_SLOT; ++i)
        {
            entry->item.enchants[i].id = item->GetEnchantmentId(EnchantmentSlot(i));
            entry->item.enchants[i].duration = item->GetEnchantmentDuration(EnchantmentSlot(i));
            entry->item.enchants[i].charges = item->GetEnchantmentCharges(EnchantmentSlot(i));
        }

        entry->item.randomPropertyId = item->GetItemRandomPropertyId();
        entry->item.suffixFactor = item->GetItemSuffixFactor();
        entry->item.count = item->GetCount();
        entry->item.spellCharges = item->GetSpellCharges();
        entry->item.itemTemplate = item->GetTemplate();
        entry->SetItemNames();

        SearchableAuctionEntry* raw = entry.get();
        sEntryCache[auction->Id] = std::move(entry);
        return raw;
    }

    // The core's BuildListAuctionItems filters, applied to one entry.
    bool MatchesFilters(PendingSearch const& search, SearchableAuctionEntry const& entry)
    {
        AuctionHouseSearchInfo const& info = search.searchInfo;
        ItemTemplate const* proto = entry.item.itemTemplate;

        if (info.itemClass != 0xffffffff && proto->Class != info.itemClass)
            return false;

        if (info.itemSubClass != 0xffffffff && proto->SubClass != info.itemSubClass)
            return false;

        if (info.inventoryType != 0xffffffff && proto->InventoryType != info.inventoryType)
        {
            // robes are listed as chests
            if (info.inventoryType != INVTYPE_CHEST || proto->InventoryType != INVTYPE_ROBE)
                return false;
        }

        if (info.quality != 0xffffffff && proto->Quality < info.quality)
            return false;

        if (info.levelmin != 0x00 && (proto->RequiredLevel < info.levelmin
            || (info.levelmax != 0x00 && proto->RequiredLevel > info.levelmax)))
            return false;

        if (info.usable != 0x00 && search.playerInfo.usablePlayerInfo && !search.playerInfo.usablePlayerInfo->PlayerCanUseItem(proto))
            return false;

        if (!info.wsearchedname.empty() && entry.item.itemName[search.playerInfo.loc_idx].find(info.wsearchedname) == std::wstring::npos)
            return false;

        return true;
    }

    // Mirrors AuctionHouseWorkerThread::SearchListRequest, plus the gates.
    void RunSearch(PendingSearch const& search, WorldPacket& packet)
    {
        packet.Initialize(SMSG_AUCTION_LIST_RESULT, (4 + 4 + 4));
        packet << uint32(0);

        uint32 count = 0;
        uint32 totalCount = 0;

        AuctionHouseObject* house = sAuctionMgr->GetAuctionsMapByHouseId(search.houseId);
        std::lock_guard<std::mutex> guard(sCacheLock);

        std::vector<SearchableAuctionEntry*> matches;
        matches.reserve(house->Getcount());
        for (auto const& [id, auction] : house->GetAuctions())
        {
            SearchableAuctionEntry* entry = GetSearchableEntry(auction);
            if (!entry || !search.view.Visible(entry->item.itemTemplate))
                continue;

            if (!search.searchInfo.getAll && !MatchesFilters(search, *entry))
                continue;

            matches.push_back(entry);
        }

        if (search.searchInfo.getAll)
        {
            for (SearchableAuctionEntry const* entry : matches)
            {
                entry->BuildAuctionInfo(packet);
                if (++count >= MAX_GETALL_RETURN)
                    break;
            }
        }
        else
        {
            if (!search.searchInfo.sorting.empty() && matches.size() > MAX_AUCTIONS_PER_PAGE)
            {
                AuctionSorter sorter(&search.searchInfo.sorting, search.playerInfo.loc_idx);
                std::sort(matches.begin(), matches.end(), sorter);
            }

            for (std::size_t i = search.searchInfo.listfrom; i < matches.size(); ++i)
            {
                matches[i]->BuildAuctionInfo(packet);
                if (++count >= MAX_AUCTIONS_PER_PAGE)
                    break;
            }
        }

        totalCount = matches.size();
        packet.put<uint32>(0, count);
        packet << totalCount;
        packet << uint32(AUCTION_SEARCH_DELAY);
    }

    // Parses CMSG_AUCTION_LIST_ITEMS the same way WorldSession::HandleAuctionListItems does.
    // Returns false if the request should just be dropped (bad packet, not at an auctioneer),
    // which is also what the core handler does in those cases.
    bool BuildPendingSearch(Player* player, WorldPacket const& original, PendingSearch& out)
    {
        WorldPacket recvData(original);
        recvData.rpos(0);

        std::string searchedname;
        uint8 levelmin, levelmax, usable, getAll, sortOrderCount;
        uint32 listfrom, auctionSlotID, auctionMainCategory, auctionSubCategory, quality;
        ObjectGuid guid;

        recvData >> guid;
        recvData >> listfrom;
        recvData >> searchedname;
        recvData >> levelmin >> levelmax;
        recvData >> auctionSlotID >> auctionMainCategory >> auctionSubCategory;
        recvData >> quality >> usable;
        recvData >> getAll;
        recvData >> sortOrderCount;

        if (sortOrderCount > AUCTION_SORT_MAX)
            return false;

        AuctionSortOrderVector sortOrder;
        for (uint8 i = 0; i < sortOrderCount; ++i)
        {
            uint8 sortMode, isDesc;
            recvData >> sortMode >> isDesc;
            AuctionSortInfo sortInfo;
            sortInfo.isDesc = (isDesc == 1);
            sortInfo.sortOrder = static_cast<AuctionSortOrder>(sortMode);
            sortOrder.push_back(sortInfo);
        }

        std::wstring wsearchedname;
        if (!Utf8toWStr(searchedname, wsearchedname))
            return false;
        wstrToLower(wsearchedname);

        Creature* creature = player->GetNPCIfCanInteractWith(guid, UNIT_NPC_FLAG_AUCTIONEER);
        if (!creature)
            return false;

        if (player->HasUnitState(UNIT_STATE_DIED))
            player->RemoveAurasByType(SPELL_AURA_FEIGN_DEATH);

        AuctionHouseEntry const* ahEntry = AuctionHouseMgr::GetAuctionHouseEntryFromFactionTemplate(creature->GetFaction());
        if (!ahEntry)
            return false;

        out.playerGuid = player->GetGUID();
        out.houseId = AuctionHouseId(ahEntry->houseId);

        out.searchInfo.wsearchedname = wsearchedname;
        out.searchInfo.listfrom = listfrom;
        out.searchInfo.levelmin = levelmin;
        out.searchInfo.levelmax = levelmax;
        out.searchInfo.usable = usable;
        out.searchInfo.inventoryType = auctionSlotID;
        out.searchInfo.itemClass = auctionMainCategory;
        out.searchInfo.itemSubClass = auctionSubCategory;
        out.searchInfo.quality = quality;
        out.searchInfo.getAll = getAll;
        out.searchInfo.sorting = std::move(sortOrder);

        out.playerInfo.playerGuid = player->GetGUID();
        out.playerInfo.faction = player->GetFaction();
        out.playerInfo.loc_idx = player->GetSession()->GetSessionDbLocaleIndex();
        out.playerInfo.locdbc_idx = player->GetSession()->GetSessionDbcLocale();
        if (usable)
        {
            AuctionHouseUsablePlayerInfo usablePlayerInfo;
            usablePlayerInfo.classMask = player->getClassMask();
            usablePlayerInfo.raceMask = player->getRaceMask();
            usablePlayerInfo.level = player->GetLevel();

            for (auto const& pair : player->GetSkillStatusMap())
                usablePlayerInfo.skills.insert(std::make_pair(pair.first, player->GetSkillValue(pair.first)));

            for (auto const& pair : player->GetSpellMap())
                if (pair.second->State != PLAYERSPELL_REMOVED && pair.second->IsInSpec(player->GetActiveSpec()))
                    usablePlayerInfo.spells.insert(pair.first);

            out.playerInfo.usablePlayerInfo = std::move(usablePlayerInfo);
        }

        return true;
    }
}

class RetailAHClassicServerScript : public ServerScript
{
public:
    RetailAHClassicServerScript() : ServerScript("RetailAHClassicServerScript", { SERVERHOOK_CAN_PACKET_RECEIVE }) { }

    // Runs on the map thread that owns the session (the opcode is PROCESS_THREADSAFE).
    bool CanPacketReceive(WorldSession* session, WorldPacket const& packet) override
    {
        if (packet.GetOpcode() != CMSG_AUCTION_LIST_ITEMS || !session)
            return true;

        Player* player = session->GetPlayer();
        if (!player || !Gate::FilterClassic())
            return true;

        // Built here, on the player's own thread; the search runs on the world's. It never asks
        // what the player owns (that reads the database), so the classic window doesn't show
        // listings the player can't buy.
        PendingSearch search { player->GetGUID(), AuctionHouseId::Neutral, Gate::View(player), {}, {} };
        if (!search.view.HidesAnything())
            return true;

        try
        {
            if (!BuildPendingSearch(player, packet, search))
                return false;
        }
        catch (ByteBufferException const&)
        {
            // Malformed: let the core handler read it and deal with the client as it normally would.
            return true;
        }

        std::lock_guard<std::mutex> guard(sPendingLock);
        sPending.push_back(std::move(search));
        return false;
    }
};

class RetailAHClassicAuctionScript : public AuctionHouseScript
{
public:
    RetailAHClassicAuctionScript() : AuctionHouseScript("RetailAHClassicAuctionScript", { AUCTIONHOUSEHOOK_ON_AUCTION_REMOVE }) { }

    void OnAuctionRemove(AuctionHouseObject* /*ah*/, AuctionEntry* entry) override
    {
        if (!entry)
            return;

        std::lock_guard<std::mutex> guard(sCacheLock);
        sEntryCache.erase(entry->Id);
    }
};

class RetailAHClassicWorldScript : public WorldScript
{
public:
    RetailAHClassicWorldScript() : WorldScript("RetailAHClassicWorldScript", { WORLDHOOK_ON_UPDATE }) { }

    void OnUpdate(uint32 /*diff*/) override
    {
        std::vector<PendingSearch> pending;
        {
            std::lock_guard<std::mutex> guard(sPendingLock);
            if (sPending.empty())
                return;
            pending.swap(sPending);
        }

        for (PendingSearch const& search : pending)
        {
            Player* player = ObjectAccessor::FindConnectedPlayer(search.playerGuid);
            if (!player)
                continue;

            WorldPacket packet;
            RunSearch(search, packet);
            player->SendDirectMessage(&packet);
        }
    }
};

void AddRetailAHClassicScripts()
{
    new RetailAHClassicServerScript();
    new RetailAHClassicAuctionScript();
    new RetailAHClassicWorldScript();
}
