/*
 * mod-retail-ah: what a player may see in the auction house.
 *
 * Two gates, both on by default:
 *
 *   - Era: mod-individual-progression. Each item needs the progression state worked out in
 *     RetailAHEra.cpp (BWL drops after Molten Core, Outland goods at TBC, ...). A player's state
 *     is the highest IP progression quest (66000 + state) they have been rewarded.
 *   - Level: an item needing a level more than RetailAH.LevelGate.Margin above the character's
 *     is hidden. The need is the item's required level, or, for items without one (trade goods,
 *     recipes, bags), its item level. Gear with a required level is judged by that alone: greens
 *     sit about five item levels above their required level, so item level would hide every
 *     on-level green. At the era's level cap (60 before TBC, 70 before WotLK, then the server's
 *     cap) the level gate steps aside and the era gate decides alone; otherwise a level 60
 *     player would lose Nexus Crystals and raid recipes, whose item levels are past 62.
 *
 * Price lookups (the C and I requests) also show listings of items the player owns (bags, bank,
 * reagent bank), so the Sell tab always shows the market for what they are posting. Owning one
 * never lets them buy one: searches, purchases and bids ignore it. GMs with GM mode on and
 * accounts matching IP's ExcludedAccountsRegex / BotAccountsRegex see everything.
 *
 * The gates apply to every RetailAH request, to the classic window's search
 * (RetailAHClassic.cpp) and, through OnPlayerCanPlaceAuctionBid, to bids and buyouts from
 * either window.
 *
 * Released under the MIT License.
 */

#include "RetailAH.h"
#include "RetailAHEra.h"
#include "AccountMgr.h"
#include "Bag.h"
#include "Chat.h"
#include "Config.h"
#include "DatabaseEnv.h"
#include "Item.h"
#include "Log.h"
#include "ObjectMgr.h"
#include "Player.h"
#include "ScriptMgr.h"
#include "StringFormat.h"
#include "World.h"
#include "WorldSession.h"
#include <atomic>
#include <mutex>
#include <regex>

using namespace Acore::ChatCommands;

namespace RetailAH::Gate
{
    namespace
    {
        // mod-individual-progression's own keys, so there is nothing to keep in sync.
        struct IpOptions
        {
            std::regex excludedAccounts;
            std::regex botAccounts;
            bool hasExcludedAccounts = false;
            bool hasBotAccounts = false;
        };

        // The scalars are read by classic searches on map threads while a reload may write them.
        IpOptions sIp;
        std::atomic<bool> sIpEnabled { true };
        std::atomic<uint8> sIpProgressionLimit { 0 };
        std::atomic<bool> sIpInstalled { false };   // its progression quests exist; read at startup
        std::atomic<uint32> sMaxLevelNeed { 0 };    // the highest level need of any item; read at startup
        std::atomic<bool> sAhProgressionLoaded { false };

        // Account regexes are only used under this lock, so a config reload on the world thread
        // can't swap them out from under a map thread running a classic search.
        std::mutex sAccountLock;
        std::unordered_map<uint32, bool> sUnfilteredAccounts;  // account id -> excluded or bot

        // Per era state, world thread only (HELLO).
        std::unordered_map<uint8, uint32> sStatMasks;

        thread_local uint32 tSkipBidHook = 0;

        void SetRegex(std::string const& pattern, std::regex& target, bool& has, char const* key)
        {
            has = false;
            if (pattern.empty())
                return;

            try
            {
                target = std::regex(pattern);
                has = true;
            }
            catch (std::regex_error const& error)
            {
                LOG_ERROR("module", "mod-retail-ah: {} = \"{}\" is not a valid regex ({}); ignoring it.", key, pattern, error.what());
            }
        }

        bool IsUnfilteredAccount(uint32 accountId)
        {
            std::lock_guard<std::mutex> guard(sAccountLock);
            auto itr = sUnfilteredAccounts.find(accountId);
            if (itr != sUnfilteredAccounts.end())
                return itr->second;

            bool unfiltered = false;
            std::string name;
            if ((sIp.hasExcludedAccounts || sIp.hasBotAccounts) && AccountMgr::GetName(accountId, name))
                unfiltered = (sIp.hasExcludedAccounts && std::regex_match(name, sIp.excludedAccounts))
                    || (sIp.hasBotAccounts && std::regex_match(name, sIp.botAccounts));

            sUnfilteredAccounts[accountId] = unfiltered;
            return unfiltered;
        }

        bool IpActive()
        {
            return sIpEnabled && sIpInstalled;
        }

        bool EraActive()
        {
            return GetConfig().eraGate && IpActive();
        }

        // Same walk as IndividualProgression::GetPlayerProgressionFromQuests.
        uint8 ProgressionState(Player* player)
        {
            uint8 state = Era::STATE_START;
            for (uint8 i = Era::STATE_MOLTEN_CORE; i <= Era::STATE_MAX; ++i)
                if (player->GetQuestStatus(Era::IP_PROGRESSION_QUEST_BASE + i) == QUEST_STATUS_REWARDED)
                    state = i;
            return state;
        }

        // Also enforces IndividualProgression.ProgressionLimit, as IP's hasPassedProgression does.
        bool EraVisible(uint8 era, uint8 required)
        {
            if (era == ERA_ALL || required == Era::STATE_START)
                return true;
            uint8 limit = sIpProgressionLimit;
            if (limit && required > limit)
                return false;
            return era >= required;
        }

        // The highest level a character can reach in this era; there the level gate steps aside.
        uint32 EraLevelCap(uint8 era)
        {
            uint32 cap = sWorld->getIntConfig(CONFIG_MAX_PLAYER_LEVEL);
            if (era == ERA_ALL)
                return cap;
            if (era < Era::STATE_PRE_TBC)
                return std::min<uint32>(cap, 60);
            if (era < Era::STATE_TBC_TIER_5)
                return std::min<uint32>(cap, 70);
            return cap;
        }

        uint32 LevelNeed(ItemTemplate const* proto)
        {
            if (proto->RequiredLevel)
                return proto->RequiredLevel;
            return GetConfig().levelGateItemLevel ? proto->ItemLevel : 0;
        }

        // Stats vanilla gear never has; whether they're offered depends on the era's items.
        constexpr uint32 ERA_STATS = (1u << uint8(GearStats::Stat::Haste)) | (1u << uint8(GearStats::Stat::Expertise))
            | (1u << uint8(GearStats::Stat::ArmorPen)) | (1u << uint8(GearStats::Stat::Resilience))
            | (1u << uint8(GearStats::Stat::Sockets));
        constexpr uint32 ALL_STATS = (1u << (uint8(GearStats::Stat::Sockets) + 1)) - 1;
    }

    View::View(Player* player) : _player(player)
    {
        Config const& cfg = GetConfig();
        if (!player || !player->GetSession() || player->IsGameMaster()
            || IsUnfilteredAccount(player->GetSession()->GetAccountId()))
            return;

        // IP holds characters at 60 and 70 whether or not the era gate is on.
        uint8 state = IpActive() ? ProgressionState(player) : ERA_ALL;
        if (EraActive())
        {
            _era = state;
            _table = Era::Snapshot();
        }

        _levelCapEra = EraLevelCap(state);
        if (cfg.levelGate && player->GetLevel() < _levelCapEra)
            _levelCap = player->GetLevel() + cfg.levelMargin;
    }

    Lock View::Check(ItemTemplate const* proto) const
    {
        Lock lock;
        if (!proto)
            return lock;

        if (_levelCap)
        {
            uint32 need = LevelNeed(proto);
            if (need > _levelCap)
                lock.level = uint8(std::min<uint32>({ need - GetConfig().levelMargin, _levelCapEra, 255 }));
        }

        if (_table)
        {
            uint8 required = _table->RequiredState(proto->ItemId);
            if (!EraVisible(_era, required))
                lock.era = required;
        }

        return lock;
    }

    bool View::VisibleOrOwned(ItemTemplate const* proto) const
    {
        return Visible(proto) || (proto && Owns(proto->ItemId));
    }

    bool View::Owns(uint32 entry) const
    {
        if (!_ownedRead)
            ReadOwned();
        return _owned.count(entry) != 0;
    }

    void View::ReadOwned() const
    {
        _ownedRead = true;
        if (!_player)
            return;

        auto add = [this](Item const* item)
        {
            if (item)
                _owned.insert(item->GetEntry());
        };

        // Equipped, the bag slots, the backpack, the bank and the bank's bag slots.
        for (uint8 slot = EQUIPMENT_SLOT_START; slot < BANK_SLOT_BAG_END; ++slot)
            add(_player->GetItemByPos(INVENTORY_SLOT_BAG_0, slot));

        auto addBag = [&](uint8 bagSlot)
        {
            if (Bag* bag = _player->GetBagByPos(bagSlot))
                for (uint32 i = 0; i < bag->GetBagSize(); ++i)
                    add(bag->GetItemByPos(uint8(i)));
        };
        for (uint8 slot = INVENTORY_SLOT_BAG_START; slot < INVENTORY_SLOT_BAG_END; ++slot)
            addBag(slot);
        for (uint8 slot = BANK_SLOT_BAG_START; slot < BANK_SLOT_BAG_END; ++slot)
            addBag(slot);

        for (auto const& [entry, amount] : ReagentBank::Contents(_player))
            _owned.insert(entry);
    }

    bool View::HidesAnything() const
    {
        if (_levelCap && _levelCap < sMaxLevelNeed)
            return true;
        if (!_table || _table->items.empty())
            return false;
        return !EraVisible(_era, _table->maxState);
    }

    void LoadConfig()
    {
        sIpEnabled = sConfigMgr->GetOption<bool>("IndividualProgression.Enable", true, false);
        sIpProgressionLimit = sConfigMgr->GetOption<uint8>("IndividualProgression.ProgressionLimit", 0, false);

        Era::Options& era = Era::GetOptions();
        era.deriveFromSources = sConfigMgr->GetOption<bool>("RetailAH.EraGate.DeriveFromSources", true);
        era.expansionFloors = sConfigMgr->GetOption<bool>("RetailAH.EraGate.ExpansionFloors", true);
        era.zulGurubState = sConfigMgr->GetOption<uint8>("IndividualProgression.RequiredZulGurubProgression", Era::STATE_BLACKWING_LAIR, false);
        era.zulAmanState = sConfigMgr->GetOption<uint8>("IndividualProgression.RequiredZulAmanProgression", Era::STATE_TBC_TIER_4, false);

        // mod-ah-progression did this job before; both answering the classic search would race.
        sAhProgressionLoaded = !sConfigMgr->GetKeysByString("AHProgression.").empty();

        std::lock_guard<std::mutex> guard(sAccountLock);
        SetRegex(sConfigMgr->GetOption<std::string>("IndividualProgression.ExcludedAccountsRegex", "", false),
            sIp.excludedAccounts, sIp.hasExcludedAccounts, "IndividualProgression.ExcludedAccountsRegex");
        SetRegex(sConfigMgr->GetOption<std::string>("IndividualProgression.BotAccountsRegex", "^RNDBOT.*", false),
            sIp.botAccounts, sIp.hasBotAccounts, "IndividualProgression.BotAccountsRegex");
        sUnfilteredAccounts.clear();
    }

    void Load()
    {
        Config const& cfg = GetConfig();
        sIpInstalled = sObjectMgr->GetQuestTemplate(Era::IP_PROGRESSION_QUEST_BASE + Era::STATE_MOLTEN_CORE) != nullptr;

        if (cfg.eraGate && sIpInstalled)
        {
            WorldDatabase.DirectExecute(
                "CREATE TABLE IF NOT EXISTS `mod_retail_ah_item_era` ("
                "`entry` INT UNSIGNED NOT NULL COMMENT 'item_template.entry',"
                "`state` TINYINT UNSIGNED NOT NULL COMMENT 'IP progression state needed to see it (0 = always)',"
                "`comment` VARCHAR(255) NOT NULL DEFAULT '',"
                "PRIMARY KEY (`entry`)"
                ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='mod-retail-ah era gate overrides'");
            Era::Load();
        }
        else if (cfg.eraGate)
            LOG_INFO("module", "mod-retail-ah: mod-individual-progression's quests aren't in the world DB; no era gate.");

        uint32 maxLevelNeed = 0;
        for (auto const& [entry, proto] : *sObjectMgr->GetItemTemplateStore())
            maxLevelNeed = std::max(maxLevelNeed, LevelNeed(&proto));
        sMaxLevelNeed = maxLevelNeed;

        sStatMasks.clear();

        if (sAhProgressionLoaded)
            LOG_ERROR("module", "mod-retail-ah: mod-ah-progression's config is loaded. RetailAH does its job now; remove that module. "
                "Until then the classic window's search is left to it.");
    }

    uint32 StatsAvailable(uint8 era)
    {
        if (era == ERA_ALL || !EraActive())
            return ALL_STATS;

        auto itr = sStatMasks.find(era);
        if (itr != sStatMasks.end())
            return itr->second;

        std::shared_ptr<Era::Table const> table = Era::Snapshot();
        uint32 found = 0;
        for (auto const& [entry, proto] : *sObjectMgr->GetItemTemplateStore())
        {
            if (proto.Class != ITEM_CLASS_ARMOR && proto.Class != ITEM_CLASS_WEAPON)
                continue;
            if (!EraVisible(era, table->RequiredState(entry)))
                continue;
            found |= GearStats::TemplateMask(&proto) & ERA_STATS;
            if (found == ERA_STATS)
                break;
        }

        uint32 mask = (ALL_STATS & ~ERA_STATS) | found;
        sStatMasks.emplace(era, mask);
        return mask;
    }

    bool FilterClassic()
    {
        return GetConfig().classicWindow && !sAhProgressionLoaded;
    }

    SkipBidHook::SkipBidHook()
    {
        ++tSkipBidHook;
    }

    SkipBidHook::~SkipBidHook()
    {
        --tSkipBidHook;
    }
}

using namespace RetailAH;

class RetailAHGatePlayerScript : public PlayerScript
{
public:
    RetailAHGatePlayerScript() : PlayerScript("RetailAHGatePlayerScript", { PLAYERHOOK_CAN_PLACE_AUCTION_BID }) { }

    // A hidden auction can still be bid on by id (a stale list, an addon); refuse it. The core
    // answers with ERR_AUCTION_RESTRICTED_ACCOUNT.
    bool OnPlayerCanPlaceAuctionBid(Player* player, AuctionEntry* auction) override
    {
        if (Gate::tSkipBidHook || !auction || !player)
            return true;
        // Owning a copy doesn't count here: one mailed Fel Iron Bar mustn't unlock buying them.
        return Gate::View(player).Visible(sObjectMgr->GetItemTemplate(auction->item_template));
    }
};

class RetailAHGateCommandScript : public CommandScript
{
public:
    RetailAHGateCommandScript() : CommandScript("RetailAHGateCommandScript") { }

    ChatCommandTable GetCommands() const override
    {
        static ChatCommandTable subCommands =
        {
            { "item",   HandleItemCommand,   SEC_GAMEMASTER,    Console::Yes },
            { "player", HandlePlayerCommand, SEC_GAMEMASTER,    Console::No  },
            { "reload", HandleReloadCommand, SEC_ADMINISTRATOR, Console::Yes },
        };

        static ChatCommandTable commandTable =
        {
            { "rah", subCommands },
        };

        return commandTable;
    }

    // `.rah item <id or link>`: the item's level need and the era that unlocks it, and why.
    static bool HandleItemCommand(ChatHandler* handler, ItemTemplate const* proto)
    {
        Config const& cfg = GetConfig();
        uint32 need = Gate::LevelNeed(proto);
        if (!cfg.levelGate || !need)
            handler->PSendSysMessage("{} ({}): no level gate.", proto->Name1, proto->ItemId);
        else
            handler->PSendSysMessage("{} ({}): needs level {} ({}), shown from character level {}.", proto->Name1, proto->ItemId,
                need, proto->RequiredLevel ? "required level" : "item level", need > cfg.levelMargin ? need - cfg.levelMargin : 1);

        if (!Gate::EraActive())
        {
            handler->PSendSysMessage("No era gate (RetailAH.EraGate off, or mod-individual-progression off or missing).");
            return true;
        }

        std::shared_ptr<Era::Table const> table = Era::Snapshot();
        auto itr = table->items.find(proto->ItemId);
        if (itr == table->items.end())
        {
            handler->PSendSysMessage("Era: not gated, every progression state sees it.");
            return true;
        }

        Era::ItemEra const& era = itr->second;
        handler->PSendSysMessage("Era: needs progression {} ({}). Easiest source: {} {}.",
            era.state, Era::StateName(era.state), Era::ReasonName(era.reason), era.source);
        return true;
    }

    // `.rah player`: what the selected player (or you) can see.
    static bool HandlePlayerCommand(ChatHandler* handler)
    {
        Player* target = handler->getSelectedPlayerOrSelf();
        if (!target)
            return false;

        Gate::View view(target);
        if (!view.HidesAnything())
        {
            handler->PSendSysMessage("{}: nothing is hidden (GM mode, excluded or bot account, past every gate, or both gates off).",
                target->GetName());
            return true;
        }

        uint32 byLevel = 0, byEra = 0;
        for (auto const& [entry, proto] : *sObjectMgr->GetItemTemplateStore())
        {
            Gate::Lock lock = view.Check(&proto);
            byLevel += lock.level ? 1 : 0;
            byEra += lock.era ? 1 : 0;
        }

        std::string era = view.Era() == Gate::ERA_ALL ? "no era gate"
            : Acore::StringFormat("progression {} ({})", view.Era(), Era::StateName(view.Era()));
        std::string level = view.LevelCap() ? Acore::StringFormat("level needs up to {}", view.LevelCap()) : "no level gate";
        handler->PSendSysMessage("{}: {}, {}. Hidden item templates: {} by level, {} by era.",
            target->GetName(), level, era, byLevel, byEra);
        return true;
    }

    // `.rah reload`: re-read the gate options and rebuild the era table.
    static bool HandleReloadCommand(ChatHandler* handler)
    {
        RetailAH::LoadConfig();
        Gate::Load();
        handler->PSendSysMessage("mod-retail-ah: gates reloaded, {} era-gated items.", Era::Snapshot()->items.size());
        return true;
    }
};

void AddRetailAHGateScripts()
{
    new RetailAHGatePlayerScript();
    new RetailAHGateCommandScript();
}
