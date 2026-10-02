/*
 * mod-retail-ah: working out which mod-individual-progression state unlocks each item.
 * (Moved from mod-ah-progression, which this module replaces.)
 *
 * The world DB has no "patch added" column, so the state is inferred from where an item can be
 * obtained, taking the EASIEST source (an item that drops both in BWL and in an open-world zone is
 * not gated at all):
 *
 *   1. World sources, fixed: creature loot / pickpocket / skinning, chest and gathering-node loot,
 *      fishing loot and vendors. Each spawn gets the state of the map (and, for Outland, zone) it
 *      stands in, using the same gates mod-individual-progression puts on those maps. A creature
 *      of level 64+ (74+) standing in the old world is TBC (WotLK) content all the same: level 70
 *      Scourge Invasion mobs, the level 80 Onyxia's Lair, and so on.
 *      Vendors only count for items nothing drops (see the vendor block below).
 *   2. Derived sources, iterated until stable: container contents, prospecting / milling /
 *      disenchanting results, quest rewards (gated by the quest giver and the items it asks for)
 *      and crafted items (gated by where the recipe is learned and by the reagents).
 *   3. Floors that apply whatever the sources say: RequiredLevel above 60 / 70, or a gear item
 *      level no vanilla (TBC) item of that quality has, means TBC (WotLK).
 *   4. Override rows replace all of the above (state 0 = always visible): mod_retail_ah_item_era,
 *      and mod-ah-progression's mod_ah_progression_item when it is still there.
 *
 * Professions are gated by skill tier, not by profession: jewelcrafting, inscription,
 * prospecting and milling all work from the start, but a craft needing more than 300 skill
 * (vanilla's cap) is TBC and more than 375 is WotLK.
 *
 * Items with no known source and no floor stay visible: when unsure, show it.
 *
 * AzerothCore's own loot tables are not era-clean (level 60 world loot includes some Hellfire
 * greens, for instance); the floors catch most of that, and the override table the rest.
 *
 * Released under the MIT License.
 */

#include "RetailAHEra.h"

#include "DBCStores.h"
#include "DatabaseEnv.h"
#include "Field.h"
#include "ItemTemplate.h"
#include "Log.h"
#include "ObjectMgr.h"
#include "QueryResult.h"
#include "SharedDefines.h"
#include "SpellInfo.h"
#include "SpellMgr.h"
#include "StringFormat.h"
#include "Timer.h"
#include <algorithm>
#include <array>
#include <unordered_set>
#include <vector>

namespace RetailAH::Era
{
    namespace
    {
        constexpr uint8 UNKNOWN = 0xFF;

        constexpr uint32 MAP_OUTLAND           = 530;
        constexpr uint32 MAP_NORTHREND         = 571;
        constexpr uint32 ZONE_ISLE_OF_QUEL_DANAS = 4080;
        constexpr uint32 SPELL_LEARNING        = 483;   // TBC recipes: Spells[1] is what they teach
        constexpr uint32 SPELL_LEARNING_WOTLK  = 55884;
        constexpr uint32 SKILL_CAP_VANILLA     = 300;
        constexpr uint32 SKILL_CAP_TBC         = 375;

        struct Candidate
        {
            uint8 state = UNKNOWN;
            Reason reason = Reason::Creature;
            uint32 source = 0;

            bool Known() const { return state != UNKNOWN; }
        };

        // Keeps the lower (easier to reach) of the two.
        bool Offer(Candidate& target, uint8 state, Reason reason, uint32 source)
        {
            if (state >= target.state)
                return false;

            target.state = state;
            target.reason = reason;
            target.source = source;
            return true;
        }

        uint8 MapState(uint32 mapId, uint32 zoneId, uint8 spawnMask)
        {
            Options const& cfg = GetOptions();

            switch (mapId)
            {
                case 469: return STATE_MOLTEN_CORE;                   // Blackwing Lair
                case 309: return cfg.zulGurubState;                   // Zul'Gurub
                case 509:                                             // Ruins of Ahn'Qiraj
                case 531: return STATE_PRE_AQ;                        // Temple of Ahn'Qiraj
                case 533:                                             // Naxxramas: IP spawns the 40-man version
                    return (spawnMask & 4) ? STATE_AQ : STATE_TBC_TIER_5; // with spawnMask 4, WotLK's is 1|2
                case MAP_OUTLAND:
                    return zoneId == ZONE_ISLE_OF_QUEL_DANAS ? STATE_TBC_TIER_4 : STATE_PRE_TBC;
                case 532:                                             // Karazhan
                case 565:                                             // Gruul's Lair
                case 544:                                             // Magtheridon's Lair
                case 560:                                             // Old Hillsbrad Foothills
                case 269: return STATE_PRE_TBC;                       // The Black Morass
                case 548:                                             // Serpentshrine Cavern
                case 550: return STATE_TBC_TIER_1;                    // Tempest Keep
                case 534:                                             // Mount Hyjal
                case 564: return STATE_TBC_TIER_2;                    // Black Temple
                case 568: return cfg.zulAmanState;                    // Zul'Aman
                case 580:                                             // Sunwell Plateau
                case 585: return STATE_TBC_TIER_4;                    // Magisters' Terrace
                case MAP_NORTHREND: return STATE_TBC_TIER_5;
                case 603: return STATE_WOTLK_TIER_1;                  // Ulduar
                case 649:                                             // Trial of the Crusader
                case 650: return STATE_WOTLK_TIER_2;                  // Trial of the Champion
                case 631:                                             // Icecrown Citadel
                case 632:                                             // Forge of Souls
                case 658:                                             // Pit of Saron
                case 668: return STATE_WOTLK_TIER_3;                  // Halls of Reflection
                case 724: return STATE_WOTLK_TIER_4;                  // Ruby Sanctum
                default:
                    break;
            }

            if (InstanceTemplate const* instance = sObjectMgr->GetInstanceTemplate(mapId))
            {
                if (instance->Parent == MAP_OUTLAND)
                    return STATE_PRE_TBC;
                if (instance->Parent == MAP_NORTHREND)
                    return STATE_TBC_TIER_5;
            }

            // Anything else the client tags as expansion content (arenas, the odd scenario map).
            if (MapEntry const* map = sMapStore.LookupEntry(mapId))
            {
                if (map->Expansion() == 1)
                    return STATE_PRE_TBC;
                if (map->Expansion() >= 2)
                    return STATE_TBC_TIER_5;
            }

            return STATE_START;
        }

        bool TableExists(char const* table)
        {
            return WorldDatabase.Query("SHOW TABLES LIKE '{}'", table) != nullptr;
        }

        bool ColumnExists(char const* table, char const* column)
        {
            return WorldDatabase.Query("SHOW COLUMNS FROM `{}` LIKE '{}'", table, column) != nullptr;
        }

        // A loot table flattened to item ids, references included (they nest).
        class LootTable
        {
        public:
            explicit LootTable(char const* table, std::unordered_map<uint32, std::vector<std::pair<uint32, uint32>>> const* references)
                : _references(references)
            {
                if (QueryResult result = WorldDatabase.Query("SELECT Entry, Item, Reference FROM {}", table))
                {
                    do
                    {
                        Field* fields = result->Fetch();
                        int32 reference = fields[2].Get<int32>();
                        _rows[fields[0].Get<uint32>()].emplace_back(fields[1].Get<uint32>(), uint32(std::abs(reference)));
                    } while (result->NextRow());
                }
            }

            // Only used for reference_loot_template itself.
            std::unordered_map<uint32, std::vector<std::pair<uint32, uint32>>> const& Rows() const { return _rows; }

            template<typename Fn>
            void ForEachItem(uint32 lootId, Fn&& fn) const
            {
                auto itr = _rows.find(lootId);
                if (itr == _rows.end())
                    return;

                std::unordered_set<uint32> seenRefs;
                for (auto const& [item, reference] : itr->second)
                {
                    if (reference)
                        VisitReference(reference, fn, seenRefs, 0);
                    else
                        fn(item);
                }
            }

            std::vector<uint32> Entries() const
            {
                std::vector<uint32> entries;
                entries.reserve(_rows.size());
                for (auto const& pair : _rows)
                    entries.push_back(pair.first);
                return entries;
            }

        private:
            template<typename Fn>
            void VisitReference(uint32 reference, Fn& fn, std::unordered_set<uint32>& seen, uint32 depth) const
            {
                if (!_references || depth > 8 || !seen.insert(reference).second)
                    return;

                auto itr = _references->find(reference);
                if (itr == _references->end())
                    return;

                for (auto const& [item, nested] : itr->second)
                {
                    if (nested)
                        VisitReference(nested, fn, seen, depth + 1);
                    else
                        fn(item);
                }
            }

            std::unordered_map<uint32, std::vector<std::pair<uint32, uint32>>> _rows;
            std::unordered_map<uint32, std::vector<std::pair<uint32, uint32>>> const* _references;
        };

        struct ContainerEdge
        {
            uint32 parent;
            uint32 child;
        };

        struct QuestInfo
        {
            uint32 id;
            uint8 spawnStarterState;          // UNKNOWN when no spawned quest giver was found
            std::vector<uint32> starterItems; // items that start the quest
            std::vector<uint32> required;
            std::vector<uint32> rewards;
        };

        struct CraftInfo
        {
            uint32 spell;
            uint32 item;
            uint8 skillFloor; // from the skill rank the craft needs
            std::vector<uint32> reagents;
        };

        uint8 SkillTierFloor(uint32 skillRank)
        {
            if (skillRank > SKILL_CAP_TBC)
                return STATE_TBC_TIER_5;
            if (skillRank > SKILL_CAP_VANILLA)
                return STATE_PRE_TBC;
            return STATE_START;
        }

        // The expansion floor of an item, independent of where it comes from.
        Candidate Floor(ItemTemplate const& proto)
        {
            Candidate floor{ STATE_START, Reason::LevelFloor, 0 };
            if (!GetOptions().expansionFloors)
                return floor;

            if (proto.RequiredLevel > 70)
                floor = { STATE_TBC_TIER_5, Reason::LevelFloor, proto.RequiredLevel };
            else if (proto.RequiredLevel > 60)
                floor = { STATE_PRE_TBC, Reason::LevelFloor, proto.RequiredLevel };

            // Gear: vanilla greens stop around item level 65, blues around 71, epics at 92 (Naxx);
            // TBC greens / blues / epics top out around 115 / 115 / 164.
            uint8 category = STATE_START;
            if (proto.Class == ITEM_CLASS_ARMOR || proto.Class == ITEM_CLASS_WEAPON)
            {
                uint32 tbcFrom = 0, wotlkFrom = 0;
                switch (proto.Quality)
                {
                    case ITEM_QUALITY_UNCOMMON: tbcFrom = 75; wotlkFrom = 125; break;
                    case ITEM_QUALITY_RARE:     tbcFrom = 78; wotlkFrom = 130; break;
                    case ITEM_QUALITY_EPIC:     tbcFrom = 93; wotlkFrom = 180; break;
                    default: break;
                }

                if (wotlkFrom && proto.ItemLevel >= wotlkFrom)
                    category = STATE_TBC_TIER_5;
                else if (tbcFrom && proto.ItemLevel >= tbcFrom)
                    category = STATE_PRE_TBC;
            }

            if (category > floor.state)
                floor = { category, Reason::CategoryFloor, proto.ItemLevel };

            return floor;
        }
    }

    namespace
    {
        std::mutex sTableLock;
        std::shared_ptr<Table const> sTable = std::make_shared<Table>();
    }

    Options& GetOptions()
    {
        static Options options;
        return options;
    }

    std::shared_ptr<Table const> Snapshot()
    {
        std::lock_guard<std::mutex> guard(sTableLock);
        return sTable;
    }

    void Load()
    {
        uint32 const startTime = getMSTime();
        Options const& cfg = GetOptions();

        ItemTemplateContainer const* items = sObjectMgr->GetItemTemplateStore();
        std::unordered_map<uint32, Candidate> direct;

        if (cfg.deriveFromSources)
        {
            // ---- 1. Where every creature and gameobject is spawned ------------------------------
            std::unordered_map<uint32, uint8> creatureState;
            auto offerSpawn = [](std::unordered_map<uint32, uint8>& map, uint32 entry, uint8 state)
            {
                auto [itr, inserted] = map.emplace(entry, state);
                if (!inserted && state < itr->second)
                    itr->second = state;
            };

            std::unordered_map<uint32, uint8> creatureLevelState;
            if (QueryResult result = WorldDatabase.Query("SELECT entry, maxlevel FROM creature_template WHERE maxlevel >= 64"))
            {
                do
                {
                    Field* fields = result->Fetch();
                    creatureLevelState[fields[0].Get<uint32>()] = fields[1].Get<uint8>() >= 74 ? STATE_TBC_TIER_5 : STATE_PRE_TBC;
                } while (result->NextRow());
            }

            auto spawnState = [&](uint32 entry, uint8 mapState) -> uint8
            {
                auto itr = creatureLevelState.find(entry);
                return itr != creatureLevelState.end() ? std::max(mapState, itr->second) : mapState;
            };

            // AzerothCore split `creature.id` into id1/id2/id3 in 2022; older forks still have `id`.
            bool const multiEntry = ColumnExists("creature", "id1");
            if (QueryResult result = WorldDatabase.Query(multiEntry
                    ? "SELECT map, zoneId, spawnMask, id1, id2, id3 FROM creature"
                    : "SELECT map, zoneId, spawnMask, id FROM creature"))
            {
                uint32 const idColumns = multiEntry ? 3 : 1;
                do
                {
                    Field* fields = result->Fetch();
                    uint8 state = MapState(fields[0].Get<uint16>(), fields[1].Get<uint16>(), fields[2].Get<uint8>());
                    for (uint32 i = 0; i < idColumns; ++i)
                        if (uint32 entry = fields[3 + i].Get<uint32>())
                            offerSpawn(creatureState, entry, spawnState(entry, state));
                } while (result->NextRow());
            }

            // Heroic / 25-man versions of a creature are separate templates sharing the spawn.
            struct CreatureLoot { uint32 loot, pickpocket, skin; };
            std::unordered_map<uint32, CreatureLoot> creatureLoot;
            if (QueryResult result = WorldDatabase.Query("SELECT entry, difficulty_entry_1, difficulty_entry_2, difficulty_entry_3, lootid, pickpocketloot, skinloot FROM creature_template"))
            {
                std::vector<std::pair<uint32, uint32>> difficulties;
                do
                {
                    Field* fields = result->Fetch();
                    uint32 entry = fields[0].Get<uint32>();
                    for (uint8 i = 1; i <= 3; ++i)
                        if (uint32 difficultyEntry = fields[i].Get<uint32>())
                            difficulties.emplace_back(entry, difficultyEntry);
                    creatureLoot[entry] = { fields[4].Get<uint32>(), fields[5].Get<uint32>(), fields[6].Get<uint32>() };
                } while (result->NextRow());

                for (auto const& [base, difficultyEntry] : difficulties)
                {
                    auto itr = creatureState.find(base);
                    if (itr != creatureState.end())
                        offerSpawn(creatureState, difficultyEntry, itr->second);
                }
            }

            std::unordered_map<uint32, uint8> gameObjectState;
            if (QueryResult result = WorldDatabase.Query("SELECT id, map, zoneId, spawnMask FROM gameobject"))
            {
                do
                {
                    Field* fields = result->Fetch();
                    offerSpawn(gameObjectState, fields[0].Get<uint32>(), MapState(fields[1].Get<uint16>(), fields[2].Get<uint16>(), fields[3].Get<uint8>()));
                } while (result->NextRow());
            }

            // ---- 2. Direct world sources --------------------------------------------------------
            LootTable references("reference_loot_template", nullptr);
            auto const* refs = &references.Rows();
            LootTable creatureLootTable("creature_loot_template", refs);
            LootTable pickpocketLootTable("pickpocketing_loot_template", refs);
            LootTable skinningLootTable("skinning_loot_template", refs);
            LootTable gameObjectLootTable("gameobject_loot_template", refs);
            LootTable fishingLootTable("fishing_loot_template", refs);

            for (auto const& [entry, state] : creatureState)
            {
                auto lootItr = creatureLoot.find(entry);
                if (lootItr == creatureLoot.end())
                    continue;

                auto offer = [&, entry = entry, state = state](uint32 item) { Offer(direct[item], state, Reason::Creature, entry); };
                if (lootItr->second.loot)
                    creatureLootTable.ForEachItem(lootItr->second.loot, offer);
                if (lootItr->second.pickpocket)
                    pickpocketLootTable.ForEachItem(lootItr->second.pickpocket, offer);
                if (lootItr->second.skin)
                    skinningLootTable.ForEachItem(lootItr->second.skin, offer);
            }

            // Chests (type 3) and fishing holes (type 25) keep their loot id in Data1.
            if (QueryResult result = WorldDatabase.Query("SELECT entry, Data1 FROM gameobject_template WHERE type IN (3, 25) AND Data1 <> 0"))
            {
                do
                {
                    Field* fields = result->Fetch();
                    uint32 entry = fields[0].Get<uint32>();
                    auto stateItr = gameObjectState.find(entry);
                    if (stateItr == gameObjectState.end())
                        continue;

                    uint8 state = stateItr->second;
                    gameObjectLootTable.ForEachItem(uint32(fields[1].Get<int32>()), [&](uint32 item) { Offer(direct[item], state, Reason::GameObject, entry); });
                } while (result->NextRow());
            }

            // Fishing loot is keyed by zone or area id.
            for (uint32 areaId : fishingLootTable.Entries())
            {
                AreaTableEntry const* area = sAreaTableStore.LookupEntry(areaId);
                if (!area)
                    continue;

                uint32 zoneId = area->zone ? area->zone : area->ID;
                uint8 state = MapState(area->mapid, zoneId, 1);
                fishingLootTable.ForEachItem(areaId, [&](uint32 item) { Offer(direct[item], state, Reason::Fishing, areaId); });
            }

            // Vendors; a negative item is a reference to another vendor's list. They are only used
            // for items nothing drops: the Darkmoon Faire and old-world trade vendors also sell
            // Outland and Northrend goods, and Shattrath / Dalaran vendors sell vanilla ones, so a
            // vendor says little about when an item arrived.
            {
                std::unordered_map<uint32, Candidate> vendorDirect;
                std::unordered_map<uint32, std::vector<int32>> vendorRows;
                if (QueryResult result = WorldDatabase.Query("SELECT entry, item FROM npc_vendor"))
                {
                    do
                    {
                        Field* fields = result->Fetch();
                        vendorRows[fields[0].Get<uint32>()].push_back(fields[1].Get<int32>());
                    } while (result->NextRow());
                }

                for (auto const& [entry, rows] : vendorRows)
                {
                    auto stateItr = creatureState.find(entry);
                    if (stateItr == creatureState.end())
                        continue;

                    uint8 state = stateItr->second;
                    for (int32 item : rows)
                    {
                        if (item > 0)
                        {
                            Offer(vendorDirect[item], state, Reason::Vendor, entry);
                            continue;
                        }

                        auto refItr = vendorRows.find(uint32(-item));
                        if (refItr == vendorRows.end())
                            continue;

                        for (int32 refItem : refItr->second)
                            if (refItem > 0)
                                Offer(vendorDirect[refItem], state, Reason::Vendor, entry);
                    }
                }

                for (auto const& [item, candidate] : vendorDirect)
                {
                    Candidate& existing = direct[item];
                    if (!existing.Known())
                        existing = candidate;
                }
            }

            // ---- 3. Derived sources -------------------------------------------------------------
            std::vector<ContainerEdge> containerEdges;
            {
                LootTable itemLootTable("item_loot_template", refs);
                LootTable prospectingLootTable("prospecting_loot_template", refs);
                LootTable millingLootTable("milling_loot_template", refs);
                LootTable disenchantLootTable("disenchant_loot_template", refs);

                for (auto const& [entry, proto] : *items)
                {
                    auto addEdge = [&, parent = entry](uint32 child) { containerEdges.push_back({ parent, child }); };
                    itemLootTable.ForEachItem(entry, addEdge);
                    prospectingLootTable.ForEachItem(entry, addEdge);
                    millingLootTable.ForEachItem(entry, addEdge);
                    if (proto.DisenchantID)
                        disenchantLootTable.ForEachItem(proto.DisenchantID, addEdge);
                }
            }

            // Profession spells learned without a recipe item (trainers, quest rewards), keyed by
            // spell, holding the easiest state they can be learned at.
            std::unordered_map<uint32, uint8> spellLearnState;

            std::vector<QuestInfo> quests;
            {
                std::unordered_map<uint32, uint8> questStarterState;
                auto addStarters = [&](char const* table, std::unordered_map<uint32, uint8> const& spawnState)
                {
                    if (QueryResult result = WorldDatabase.Query("SELECT id, quest FROM {}", table))
                    {
                        do
                        {
                            Field* fields = result->Fetch();
                            auto itr = spawnState.find(fields[0].Get<uint32>());
                            if (itr != spawnState.end())
                                offerSpawn(questStarterState, fields[1].Get<uint32>(), itr->second);
                        } while (result->NextRow());
                    }
                };
                addStarters("creature_queststarter", creatureState);
                addStarters("gameobject_queststarter", gameObjectState);

                std::unordered_map<uint32, std::vector<uint32>> questStarterItems;
                for (auto const& [entry, proto] : *items)
                    if (proto.StartQuest)
                        questStarterItems[proto.StartQuest].push_back(entry);

                if (QueryResult result = WorldDatabase.Query("SELECT ID, RewardSpell, RewardDisplaySpell, "
                        "RequiredItemId1, RequiredItemId2, RequiredItemId3, RequiredItemId4, RequiredItemId5, RequiredItemId6, "
                        "RewardItem1, RewardItem2, RewardItem3, RewardItem4, "
                        "RewardChoiceItemID1, RewardChoiceItemID2, RewardChoiceItemID3, RewardChoiceItemID4, RewardChoiceItemID5, RewardChoiceItemID6 "
                        "FROM quest_template"))
                {
                    do
                    {
                        Field* fields = result->Fetch();
                        QuestInfo quest;
                        quest.id = fields[0].Get<uint32>();

                        auto starterItr = questStarterState.find(quest.id);
                        quest.spawnStarterState = starterItr != questStarterState.end() ? starterItr->second : UNKNOWN;
                        auto itemItr = questStarterItems.find(quest.id);
                        if (itemItr != questStarterItems.end())
                            quest.starterItems = itemItr->second;

                        // Recipes taught as a quest reward. RewardSpell is usually a "teach" spell whose
                        // LEARN_SPELL effect names the recipe.
                        if (quest.spawnStarterState != UNKNOWN)
                        {
                            for (uint32 spell : { uint32(std::max(0, fields[1].Get<int32>())), fields[2].Get<uint32>() })
                            {
                                SpellInfo const* spellInfo = sSpellMgr->GetSpellInfo(spell);
                                if (!spellInfo)
                                    continue;

                                offerSpawn(spellLearnState, spell, quest.spawnStarterState);
                                for (SpellEffectInfo const& effect : spellInfo->GetEffects())
                                    if (effect.Effect == SPELL_EFFECT_LEARN_SPELL && effect.TriggerSpell)
                                        offerSpawn(spellLearnState, effect.TriggerSpell, quest.spawnStarterState);
                            }
                        }

                        for (uint8 i = 3; i <= 8; ++i)
                            if (uint32 item = fields[i].Get<uint32>())
                                quest.required.push_back(item);
                        for (uint8 i = 9; i <= 18; ++i)
                            if (uint32 item = fields[i].Get<uint32>())
                                quest.rewards.push_back(item);

                        // A quest nobody can be seen handing out tells us nothing (the DB is full of
                        // unused ones), so it is only kept if an item can start it.
                        if (quest.rewards.empty() || (quest.spawnStarterState == UNKNOWN && quest.starterItems.empty()))
                            continue;

                        quests.push_back(std::move(quest));
                    } while (result->NextRow());
                }
            }

            // The lowest skill rank any trainer or recipe teaches a spell at.
            std::unordered_map<uint32, uint32> spellLearnRank;
            auto offerRank = [&](uint32 spell, uint32 rank)
            {
                auto [itr, inserted] = spellLearnRank.emplace(spell, rank);
                if (!inserted && rank < itr->second)
                    itr->second = rank;
            };

            // Trainers, by where the trainer stands.
            {
                auto addTrainerSpell = [&](uint32 creature, uint32 spell, uint32 rank)
                {
                    offerRank(spell, rank);
                    auto itr = creatureState.find(creature);
                    if (itr != creatureState.end())
                        offerSpawn(spellLearnState, spell, itr->second);
                };

                if (TableExists("creature_default_trainer") && TableExists("trainer_spell"))
                {
                    if (QueryResult result = WorldDatabase.Query("SELECT cdt.CreatureId, ts.SpellId, ts.ReqSkillRank FROM creature_default_trainer cdt JOIN trainer_spell ts ON ts.TrainerId = cdt.TrainerId"))
                    {
                        do
                        {
                            Field* fields = result->Fetch();
                            addTrainerSpell(fields[0].Get<uint32>(), fields[1].Get<uint32>(), fields[2].Get<uint32>());
                        } while (result->NextRow());
                    }
                }

                if (TableExists("npc_trainer"))
                {
                    // Older schema: ID is a creature entry, or a template that creatures point at with a
                    // negative SpellID.
                    std::unordered_map<uint32, std::vector<std::pair<int32, uint32>>> trainerRows;
                    if (QueryResult result = WorldDatabase.Query("SELECT ID, SpellID, ReqSkillRank FROM npc_trainer"))
                    {
                        do
                        {
                            Field* fields = result->Fetch();
                            trainerRows[fields[0].Get<uint32>()].emplace_back(fields[1].Get<int32>(), fields[2].Get<uint32>());
                        } while (result->NextRow());
                    }

                    for (auto const& [creature, rows] : trainerRows)
                    {
                        for (auto const& [spell, rank] : rows)
                        {
                            if (spell > 0)
                            {
                                addTrainerSpell(creature, spell, rank);
                                continue;
                            }

                            auto refItr = trainerRows.find(uint32(-spell));
                            if (refItr != trainerRows.end())
                                for (auto const& [refSpell, refRank] : refItr->second)
                                    if (refSpell > 0)
                                        addTrainerSpell(creature, refSpell, refRank);
                        }
                    }
                }
            }

            std::unordered_map<uint32, std::vector<uint32>> recipesBySpell;
            for (auto const& [entry, proto] : *items)
            {
                if (proto.Class != ITEM_CLASS_RECIPE)
                    continue;

                uint32 taught = 0;
                uint32 learnSpell = uint32(proto.Spells[0].SpellId);
                if (learnSpell == SPELL_LEARNING || learnSpell == SPELL_LEARNING_WOTLK)
                    taught = uint32(proto.Spells[1].SpellId);
                else if (SpellInfo const* spellInfo = sSpellMgr->GetSpellInfo(learnSpell))
                {
                    for (SpellEffectInfo const& effect : spellInfo->GetEffects())
                        if (effect.Effect == SPELL_EFFECT_LEARN_SPELL && effect.TriggerSpell)
                            taught = effect.TriggerSpell;
                }

                if (taught)
                {
                    recipesBySpell[taught].push_back(entry);
                    offerRank(taught, proto.RequiredSkillRank);
                }
            }

            std::vector<CraftInfo> crafts;
            for (uint32 spellId = 1; spellId < sSpellMgr->GetSpellInfoStoreSize(); ++spellId)
            {
                SpellInfo const* spellInfo = sSpellMgr->GetSpellInfo(spellId);
                if (!spellInfo)
                    continue;

                // Only profession spells; plenty of other spells "create" items (quest objects,
                // conjured food) that never reach an auction house.
                uint32 skill = 0;
                uint32 abilityRank = 0;
                bool autoLearned = false;
                SkillLineAbilityMapBounds bounds = sSpellMgr->GetSkillLineAbilityMapBounds(spellId);
                for (auto itr = bounds.first; itr != bounds.second; ++itr)
                {
                    SkillLineEntry const* skillLine = sSkillLineStore.LookupEntry(itr->second->SkillLine);
                    if (skillLine && (skillLine->categoryId == SKILL_CATEGORY_PROFESSION || skillLine->categoryId == SKILL_CATEGORY_SECONDARY))
                    {
                        skill = skillLine->id;
                        abilityRank = std::max(abilityRank, itr->second->MinSkillLineRank);
                        // Granted on learning / levelling the skill (Smelt Copper, the first ranks).
                        autoLearned = autoLearned || itr->second->AcquireMethod != 0;
                    }
                }

                if (!skill)
                    continue;

                if (autoLearned)
                    offerSpawn(spellLearnState, spellId, STATE_START);

                for (SpellEffectInfo const& effect : spellInfo->GetEffects())
                {
                    if ((effect.Effect != SPELL_EFFECT_CREATE_ITEM && effect.Effect != SPELL_EFFECT_CREATE_ITEM_2) || !effect.ItemType)
                        continue;

                    CraftInfo craft;
                    craft.spell = spellId;
                    craft.item = effect.ItemType;
                    auto rankItr = spellLearnRank.find(spellId);
                    uint32 rank = rankItr != spellLearnRank.end() ? rankItr->second : abilityRank;
                    craft.skillFloor = cfg.expansionFloors ? SkillTierFloor(rank) : STATE_START;
                    for (uint8 i = 0; i < MAX_SPELL_REAGENTS; ++i)
                        if (spellInfo->Reagent[i] > 0)
                            craft.reagents.push_back(uint32(spellInfo->Reagent[i]));
                    crafts.push_back(std::move(craft));
                }
            }

            // ---- 4. Iterate derived sources until nothing changes -------------------------------
            // Each round is computed from the previous round's values only, so an item's value can
            // go up as well as down between rounds (a reagent turning out to be gated); chains are
            // short, so this settles in a handful of rounds.
            std::unordered_map<uint32, Candidate> floors;
            for (auto const& [entry, proto] : *items)
            {
                Candidate floor = Floor(proto);
                if (floor.state > STATE_START)
                    floors[entry] = floor;
            }

            auto effective = [&](std::unordered_map<uint32, Candidate> const& values, uint32 item) -> uint8
            {
                uint8 floor = STATE_START;
                auto floorItr = floors.find(item);
                if (floorItr != floors.end())
                    floor = floorItr->second.state;

                auto itr = values.find(item);
                if (itr == values.end() || !itr->second.Known())
                    return floor > STATE_START ? floor : UNKNOWN;
                return std::max(floor, itr->second.state);
            };

            // A requirement nobody knows the source of doesn't gate anything.
            auto requirement = [&](std::unordered_map<uint32, Candidate> const& values, uint32 item) -> uint8
            {
                uint8 state = effective(values, item);
                return state == UNKNOWN ? STATE_START : state;
            };

            std::unordered_map<uint32, Candidate> values = direct;
            uint32 rounds = 0;
            for (; rounds < 12; ++rounds)
            {
                std::unordered_map<uint32, Candidate> next = direct;

                for (ContainerEdge const& edge : containerEdges)
                {
                    uint8 state = effective(values, edge.parent);
                    if (state != UNKNOWN)
                        Offer(next[edge.child], state, Reason::Container, edge.parent);
                }

                for (QuestInfo const& quest : quests)
                {
                    uint8 state = quest.spawnStarterState;
                    for (uint32 item : quest.starterItems)
                        state = std::min(state, effective(values, item));

                    if (state == UNKNOWN)
                        continue;

                    for (uint32 item : quest.required)
                        state = std::max(state, requirement(values, item));

                    for (uint32 reward : quest.rewards)
                        Offer(next[reward], state, Reason::Quest, quest.id);
                }

                for (CraftInfo const& craft : crafts)
                {
                    uint8 learn = UNKNOWN;
                    auto learnItr = spellLearnState.find(craft.spell);
                    if (learnItr != spellLearnState.end())
                        learn = learnItr->second;

                    auto recipeItr = recipesBySpell.find(craft.spell);
                    if (recipeItr != recipesBySpell.end())
                        for (uint32 recipe : recipeItr->second)
                            learn = std::min(learn, effective(values, recipe));

                    // No trainer, recipe or quest teaches it: an unused spell, ignore it.
                    if (learn == UNKNOWN)
                        continue;

                    uint8 state = std::max(learn, craft.skillFloor);
                    for (uint32 reagent : craft.reagents)
                        state = std::max(state, requirement(values, reagent));

                    Offer(next[craft.item], state, Reason::Crafted, craft.spell);
                }

                bool changed = next.size() != values.size();
                if (!changed)
                {
                    for (auto const& [item, candidate] : next)
                    {
                        auto itr = values.find(item);
                        if (itr == values.end() || itr->second.state != candidate.state)
                        {
                            changed = true;
                            break;
                        }
                    }
                }

                values = std::move(next);
                if (!changed)
                    break;
            }

            // ---- 5. Combine with floors ---------------------------------------------------------
            direct = std::move(values);
            for (auto const& [item, floor] : floors)
            {
                Candidate& candidate = direct[item];
                if (!candidate.Known() || floor.state > candidate.state)
                    candidate = floor;
            }

            LOG_INFO("module", "mod-retail-ah: {} creatures, {} gameobjects, {} quests, {} crafts; derived sources settled after {} round(s)",
                creatureState.size(), gameObjectState.size(), quests.size(), crafts.size(), rounds + 1);
        }
        else
        {
            for (auto const& [entry, proto] : *items)
            {
                Candidate floor = Floor(proto);
                if (floor.state > STATE_START)
                    direct[entry] = floor;
            }
        }

        auto table = std::make_shared<Table>();
        for (auto const& [item, candidate] : direct)
            if (candidate.Known() && candidate.state > STATE_START && items->count(item))
                table->items[item] = { std::min<uint8>(candidate.state, STATE_MAX), candidate.reason, candidate.source };

        // ---- 6. Manual overrides ----------------------------------------------------------------
        // mod-ah-progression's table first, so a server moving over keeps its rows; ours wins.
        uint32 overrides = 0;
        for (char const* overrideTable : { "mod_ah_progression_item", "mod_retail_ah_item_era" })
        {
            if (!TableExists(overrideTable))
                continue;
            QueryResult result = WorldDatabase.Query("SELECT entry, state FROM {}", overrideTable);
            if (!result)
                continue;
            do
            {
                Field* fields = result->Fetch();
                uint32 entry = fields[0].Get<uint32>();
                uint8 state = std::min<uint8>(fields[1].Get<uint8>(), STATE_MAX);
                if (state == STATE_START)
                    table->items.erase(entry);
                else
                    table->items[entry] = { state, Reason::Override, entry };
                ++overrides;
            } while (result->NextRow());
        }

        std::array<uint32, STATE_MAX + 1> perState{};
        for (auto const& pair : table->items)
        {
            ++perState[pair.second.state];
            table->maxState = std::max(table->maxState, pair.second.state);
        }

        std::string summary;
        for (uint8 state = 1; state <= STATE_MAX; ++state)
            if (perState[state])
                summary += Acore::StringFormat(" {}={}", state, perState[state]);

        {
            std::lock_guard<std::mutex> guard(sTableLock);
            sTable = table;
        }

        LOG_INFO("module", "mod-retail-ah: {} era-gated items ({} overrides) in {} ms. Per state:{}",
            table->items.size(), overrides, GetMSTimeDiffToNow(startTime), summary);
    }

    char const* StateName(uint8 state)
    {
        switch (state)
        {
            case STATE_START:          return "fresh character";
            case STATE_MOLTEN_CORE:    return "Molten Core cleared, BWL unlocked";
            case STATE_ONYXIA:         return "Onyxia cleared";
            case STATE_BLACKWING_LAIR: return "Blackwing Lair cleared, ZG unlocked";
            case STATE_PRE_AQ:         return "AQ gates open";
            case STATE_AQ_WAR:         return "AQ war";
            case STATE_AQ:             return "AQ40 cleared, Naxxramas unlocked";
            case STATE_NAXX40:         return "Naxxramas cleared";
            case STATE_PRE_TBC:        return "TBC: Outland, Karazhan, Gruul, Magtheridon";
            case STATE_TBC_TIER_1:     return "SSC and Tempest Keep unlocked";
            case STATE_TBC_TIER_2:     return "Hyjal and Black Temple unlocked";
            case 11:                   return "Zul'Aman unlocked";
            case STATE_TBC_TIER_4:     return "Sunwell unlocked";
            case STATE_TBC_TIER_5:     return "WotLK: Northrend";
            case STATE_WOTLK_TIER_1:   return "Ulduar unlocked";
            case STATE_WOTLK_TIER_2:   return "Trial of the Crusader unlocked";
            case STATE_WOTLK_TIER_3:   return "Icecrown Citadel unlocked";
            case STATE_WOTLK_TIER_4:   return "Ruby Sanctum unlocked";
            case STATE_WOTLK_TIER_5:   return "everything";
            default:                   return "?";
        }
    }

    char const* ReasonName(Reason reason)
    {
        switch (reason)
        {
            case Reason::Override:      return "override row, item";
            case Reason::Creature:      return "dropped by creature";
            case Reason::GameObject:    return "looted from gameobject";
            case Reason::Fishing:       return "fished in area";
            case Reason::Vendor:        return "sold by creature";
            case Reason::Quest:         return "reward of quest";
            case Reason::Container:     return "comes out of item";
            case Reason::Crafted:       return "crafted with spell";
            case Reason::LevelFloor:    return "expansion-era required level";
            case Reason::CategoryFloor: return "expansion-era gear, item level";
            default:                    return "?";
        }
    }
}
