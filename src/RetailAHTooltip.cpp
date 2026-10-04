/*
 * mod-retail-ah: what an item is worth to mod-ah-bot-plus's buyer, for the addon's item
 * tooltips. With it a player can see, anywhere and before they act, whether an item sells to the
 * bot for more as it is or as the materials disenchanting it gives.
 *
 *   T:<req>:<entry>,<entry>,...   at most MAX_ENTRIES
 *     -> TD rows <entry>,<AH bot pays>,<disenchanted, AH bot pays>,<enchanting needed>,<flags>
 *        TE:<req>
 *
 * - AH bot pays: per unit, what the buyer takes on every look (AhBot::BuyRange's `always`), 0
 *   when it doesn't buy the item or isn't running.
 * - Disenchanted: the materials one disenchant gives on average, each priced the same way. The
 *   chances come from disenchant_loot_template, read at startup, rolled the way the core rolls
 *   loot: ungrouped rows on their own chance, one row per group. 0 when the item can't be
 *   disenchanted or the bot buys none of the materials.
 * - Enchanting needed: the item's RequiredDisenchantSkill, 0 when it can't be disenchanted.
 * - flags 1: it can be disenchanted. 2: this player's Enchanting is high enough.
 *   4: it binds when picked up (or is a quest item), so it can't go to the auction house.
 */

#include "RetailAH.h"
#include "DatabaseEnv.h"
#include "ItemTemplate.h"
#include "Log.h"
#include "ObjectMgr.h"
#include "Player.h"
#include "SharedDefines.h"
#include <algorithm>
#include <unordered_map>
#include <unordered_set>

namespace RetailAH::Tooltip
{
    namespace
    {
        constexpr std::size_t MAX_ENTRIES = 40;

        enum RowFlags : uint32
        {
            ROW_DISENCHANTABLE = 0x1,
            ROW_CAN_DISENCHANT = 0x2,
            ROW_SOULBOUND      = 0x4,
        };

        // One material out of a disenchant table: how many a disenchant gives on average.
        struct Yield
        {
            uint32 item;
            double count;
        };

        // DisenchantID -> its materials.
        std::unordered_map<uint32, std::vector<Yield>> sYields;

        // The core's own check (Spell::CheckItems, SPELL_EFFECT_DISENCHANT), less the skill.
        bool Disenchantable(ItemTemplate const* proto)
        {
            return proto->RequiredDisenchantSkill != uint32(-1) && proto->DisenchantID
                && proto->Quality >= ITEM_QUALITY_UNCOMMON && proto->Quality <= ITEM_QUALITY_EPIC
                && (proto->Class == ITEM_CLASS_WEAPON || proto->Class == ITEM_CLASS_ARMOR);
        }

        uint64 BotPays(uint32 entry)
        {
            uint64 always = 0, upTo = 0;
            AhBot::BuyRange(sObjectMgr->GetItemTemplate(entry), always, upTo);
            return always;
        }
    }

    void Load()
    {
        sYields.clear();
        if (!GetConfig().tooltip)
            return;

        struct Row
        {
            uint32 item;
            double chance;
            double count;
        };
        // Table -> group -> rows; group 0 holds the ungrouped ones.
        std::unordered_map<uint32, std::unordered_map<uint8, std::vector<Row>>> tables;

        // Quest-only rows and references never show up in disenchant tables; leave them out.
        QueryResult result = WorldDatabase.Query("SELECT Entry, Item, Chance, GroupId, MinCount, MaxCount FROM disenchant_loot_template "
            "WHERE Reference = 0 AND QuestRequired = 0");
        if (!result)
            return;
        do
        {
            Field* fields = result->Fetch();
            uint8 minCount = fields[4].Get<uint8>(), maxCount = fields[5].Get<uint8>();
            tables[fields[0].Get<uint32>()][fields[3].Get<uint8>()].push_back({ fields[1].Get<uint32>(),
                std::max(0.0, double(fields[2].Get<float>())), (minCount + std::max(minCount, maxCount)) / 2.0 });
        } while (result->NextRow());

        for (auto const& [entry, groups] : tables)
        {
            std::vector<Yield>& yields = sYields[entry];
            for (auto const& [group, rows] : groups)
            {
                if (!group)
                {
                    // Each rolls on its own; 100 or more always drops.
                    for (Row const& row : rows)
                        yields.push_back({ row.item, std::min(row.chance, 100.0) / 100.0 * row.count });
                    continue;
                }

                // One row out of the group: those with a chance take it, the rest split what's
                // left evenly (LootGroup::Roll).
                double explicitTotal = 0;
                uint32 equal = 0;
                for (Row const& row : rows)
                {
                    if (row.chance > 0)
                        explicitTotal += row.chance;
                    else
                        ++equal;
                }
                double scale = explicitTotal > 100.0 ? 100.0 / explicitTotal : 1.0;
                double rest = equal ? std::max(0.0, 100.0 - explicitTotal) / equal : 0.0;
                for (Row const& row : rows)
                    yields.push_back({ row.item, (row.chance > 0 ? row.chance * scale : rest) / 100.0 * row.count });
            }
        }
        LOG_INFO("module", "mod-retail-ah: {} disenchant tables loaded for item tooltips.", sYields.size());
    }

    void HandleValues(Context& ctx, std::vector<std::string_view> const& args)
    {
        if (args.size() < 3)
        {
            SendError(ctx, "bad");
            return;
        }

        Player* player = ctx.player;
        uint32 const enchanting = player->GetSkillValue(SKILL_ENCHANTING);

        std::vector<std::string> rows;
        std::unordered_set<uint32> seen;
        for (std::string_view text : Split(args[2], ','))
        {
            uint32 entry = 0;
            if (!ParseUInt(text, entry) || !seen.insert(entry).second)
                continue;
            if (seen.size() > MAX_ENTRIES)
                break;
            ItemTemplate const* proto = sObjectMgr->GetItemTemplate(entry);
            if (!proto)
                continue;

            uint32 flags = proto->Bonding == BIND_WHEN_PICKED_UP || proto->Bonding == BIND_QUEST_ITEM ? ROW_SOULBOUND : 0;
            uint64 pays = flags & ROW_SOULBOUND ? 0 : BotPays(entry);

            uint64 disenchanted = 0;
            uint32 skill = 0;
            if (Disenchantable(proto))
            {
                flags |= ROW_DISENCHANTABLE;
                skill = proto->RequiredDisenchantSkill;
                if (enchanting >= skill)
                    flags |= ROW_CAN_DISENCHANT;
                auto itr = sYields.find(proto->DisenchantID);
                if (itr != sYields.end())
                {
                    double value = 0;
                    for (Yield const& yield : itr->second)
                        value += yield.count * double(BotPays(yield.item));
                    disenchanted = uint64(value);
                }
            }

            rows.push_back(std::to_string(entry) + "," + std::to_string(pays) + "," + std::to_string(disenchanted) + ","
                + std::to_string(skill) + "," + std::to_string(flags));
        }

        SendRows(player, "TD:" + ctx.req, rows);
        Send(player, "TE:" + ctx.req);
    }
}
