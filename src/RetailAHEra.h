/*
 * mod-retail-ah: which mod-individual-progression state unlocks each item.
 *
 * Moved here from mod-ah-progression, which this module replaces. RetailAHEra.cpp works the
 * table out from the world DB at startup; RetailAHGate.cpp combines it with the level gate.
 *
 * Released under the MIT License.
 */

#ifndef MOD_RETAIL_AH_ERA_H
#define MOD_RETAIL_AH_ERA_H

#include "Define.h"
#include <memory>
#include <mutex>
#include <unordered_map>

namespace RetailAH::Era
{
    // Mirrors mod-individual-progression's ProgressionState. Copied rather than included so the
    // two modules don't need each other's headers; the numbers are the contract (IP stores a
    // player's state as rewarded quests 66000 + state).
    enum State : uint8
    {
        STATE_START          = 0,
        STATE_MOLTEN_CORE    = 1,  // BWL unlocked
        STATE_ONYXIA         = 2,
        STATE_BLACKWING_LAIR = 3,  // ZG (by default), AQ war effort
        STATE_PRE_AQ         = 4,  // AQ20 / AQ40
        STATE_AQ_WAR         = 5,
        STATE_AQ             = 6,  // Naxx40
        STATE_NAXX40         = 7,
        STATE_PRE_TBC        = 8,  // Outland, Karazhan, Gruul, Magtheridon
        STATE_TBC_TIER_1     = 9,  // SSC, TK
        STATE_TBC_TIER_2     = 10, // Hyjal, BT
        STATE_TBC_TIER_4     = 12, // Sunwell, Magisters' Terrace, Isle of Quel'Danas
        STATE_TBC_TIER_5     = 13, // Northrend
        STATE_WOTLK_TIER_1   = 14, // Ulduar
        STATE_WOTLK_TIER_2   = 15, // ToC
        STATE_WOTLK_TIER_3   = 16, // ICC
        STATE_WOTLK_TIER_4   = 17, // Ruby Sanctum
        STATE_WOTLK_TIER_5   = 18,
        STATE_MAX            = STATE_WOTLK_TIER_5
    };

    constexpr uint32 IP_PROGRESSION_QUEST_BASE = 66000;

    // Why an item got the state it has; shown by `.rah item`.
    enum class Reason : uint8
    {
        Override,     // mod_retail_ah_item_era (or mod_ah_progression_item) row
        Creature,     // creature loot / pickpocket / skinning; source = creature entry
        GameObject,   // chest or gathering node; source = gameobject entry
        Fishing,      // fishing loot; source = zone/area id
        Vendor,       // npc_vendor; source = creature entry
        Quest,        // quest reward; source = quest id
        Container,    // item_loot / prospecting / milling / disenchant; source = parent item
        Crafted,      // created by a profession spell (gated by skill tier too); source = spell id
        LevelFloor,   // RequiredLevel above the previous expansion's cap; source = level
        CategoryFloor // gear whose item level is past the era; source = item level
    };

    struct ItemEra
    {
        uint8 state;
        Reason reason;
        uint32 source;
    };

    struct Table
    {
        // Only gated items (state > 0) are stored; anything missing is visible to everyone.
        std::unordered_map<uint32, ItemEra> items;
        uint8 maxState = 0;

        uint8 RequiredState(uint32 itemEntry) const
        {
            auto itr = items.find(itemEntry);
            return itr != items.end() ? itr->second.state : 0;
        }
    };

    // Options the table is built with, plus the mod-individual-progression keys it follows.
    struct Options
    {
        bool deriveFromSources = true;
        bool expansionFloors = true;
        uint8 zulGurubState = STATE_BLACKWING_LAIR;
        uint8 zulAmanState = STATE_TBC_TIER_4;
    };

    Options& GetOptions();

    // Rebuilds the table from the world DB. Safe while classic searches run on other threads:
    // readers keep the old table alive through their shared_ptr until they are done with it.
    void Load();

    std::shared_ptr<Table const> Snapshot();

    char const* StateName(uint8 state);
    char const* ReasonName(Reason reason);
}

#endif
