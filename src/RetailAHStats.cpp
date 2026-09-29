/*
 * mod-retail-ah: which stats an item carries, for the Buy tab's stat filters.
 *
 * An item's stats come from three places:
 *   - the template's stat slots (and the scaling slots of heirlooms),
 *   - its on-equip spells, which is how older items (and individual-progression's vanilla stat
 *     reverts) give "Equip: Improves your chance to hit by 1%", attack power, spell damage...,
 *   - for "of the Monkey" items, the random enchantments rolled on that one copy.
 * Sockets count as a "stat" too. Only the presence of a stat counts, not how much. Templates, spells and DBC rows don't change
 * while the server runs, so every answer is cached.
 */

#include "RetailAH.h"
#include "DBCStores.h"
#include "Item.h"
#include "ItemTemplate.h"
#include "SpellInfo.h"
#include "SpellMgr.h"
#include <unordered_map>

namespace RetailAH::GearStats
{
    namespace
    {
        Stat FromItemMod(uint32 mod)
        {
            switch (mod)
            {
                case ITEM_MOD_STRENGTH:                 return Stat::Strength;
                case ITEM_MOD_AGILITY:                  return Stat::Agility;
                case ITEM_MOD_STAMINA:                  return Stat::Stamina;
                case ITEM_MOD_INTELLECT:                return Stat::Intellect;
                case ITEM_MOD_SPIRIT:                   return Stat::Spirit;
                case ITEM_MOD_ATTACK_POWER:
                case ITEM_MOD_RANGED_ATTACK_POWER:      return Stat::AttackPower;
                case ITEM_MOD_SPELL_POWER:
                case ITEM_MOD_SPELL_DAMAGE_DONE:
                case ITEM_MOD_SPELL_HEALING_DONE:       return Stat::SpellPower;
                case ITEM_MOD_HIT_MELEE_RATING:
                case ITEM_MOD_HIT_RANGED_RATING:
                case ITEM_MOD_HIT_SPELL_RATING:
                case ITEM_MOD_HIT_RATING:               return Stat::Hit;
                case ITEM_MOD_CRIT_MELEE_RATING:
                case ITEM_MOD_CRIT_RANGED_RATING:
                case ITEM_MOD_CRIT_SPELL_RATING:
                case ITEM_MOD_CRIT_RATING:              return Stat::Crit;
                case ITEM_MOD_HASTE_MELEE_RATING:
                case ITEM_MOD_HASTE_RANGED_RATING:
                case ITEM_MOD_HASTE_SPELL_RATING:
                case ITEM_MOD_HASTE_RATING:             return Stat::Haste;
                case ITEM_MOD_EXPERTISE_RATING:         return Stat::Expertise;
                case ITEM_MOD_ARMOR_PENETRATION_RATING: return Stat::ArmorPen;
                case ITEM_MOD_DEFENSE_SKILL_RATING:     return Stat::Defense;
                case ITEM_MOD_DODGE_RATING:             return Stat::Dodge;
                case ITEM_MOD_PARRY_RATING:             return Stat::Parry;
                case ITEM_MOD_BLOCK_RATING:
                case ITEM_MOD_BLOCK_VALUE:              return Stat::Block;
                case ITEM_MOD_RESILIENCE_RATING:
                case ITEM_MOD_CRIT_TAKEN_MELEE_RATING:
                case ITEM_MOD_CRIT_TAKEN_RANGED_RATING:
                case ITEM_MOD_CRIT_TAKEN_SPELL_RATING:
                case ITEM_MOD_CRIT_TAKEN_RATING:        return Stat::Resilience;
                case ITEM_MOD_MANA_REGENERATION:        return Stat::ManaRegen;
                case ITEM_MOD_SPELL_PENETRATION:        return Stat::SpellPen;
                default:                                return Stat::None;
            }
        }

        Stat FromCombatRating(uint32 rating)
        {
            switch (rating)
            {
                case CR_DEFENSE_SKILL:      return Stat::Defense;
                case CR_DODGE:              return Stat::Dodge;
                case CR_PARRY:              return Stat::Parry;
                case CR_BLOCK:              return Stat::Block;
                case CR_HIT_MELEE:
                case CR_HIT_RANGED:
                case CR_HIT_SPELL:          return Stat::Hit;
                case CR_CRIT_MELEE:
                case CR_CRIT_RANGED:
                case CR_CRIT_SPELL:         return Stat::Crit;
                case CR_CRIT_TAKEN_MELEE:
                case CR_CRIT_TAKEN_RANGED:
                case CR_CRIT_TAKEN_SPELL:   return Stat::Resilience;
                case CR_HASTE_MELEE:
                case CR_HASTE_RANGED:
                case CR_HASTE_SPELL:        return Stat::Haste;
                case CR_EXPERTISE:          return Stat::Expertise;
                case CR_ARMOR_PENETRATION:  return Stat::ArmorPen;
                default:                    return Stat::None;
            }
        }

        uint32 Bit(Stat stat)
        {
            return stat == Stat::None ? 0 : 1u << uint32(stat);
        }

        // One aura of an on-equip spell. Penalties ("-10 defense") don't count as having the stat.
        uint32 FromAura(SpellEffectInfo const& effect)
        {
            int32 amount = effect.CalcValue();
            switch (effect.ApplyAuraName)
            {
                case SPELL_AURA_MOD_RATING:
                {
                    if (amount <= 0)
                        return 0;
                    uint32 mask = 0;
                    for (uint32 rating = 0; rating < MAX_COMBAT_RATING; ++rating)
                        if (effect.MiscValue & (1 << rating))
                            mask |= Bit(FromCombatRating(rating));
                    return mask;
                }
                case SPELL_AURA_MOD_STAT:
                {
                    if (amount <= 0)
                        return 0;
                    static constexpr Stat primary[] = { Stat::Strength, Stat::Agility, Stat::Stamina, Stat::Intellect, Stat::Spirit };
                    if (effect.MiscValue < 0)  // all stats
                        return Bit(Stat::Strength) | Bit(Stat::Agility) | Bit(Stat::Stamina) | Bit(Stat::Intellect) | Bit(Stat::Spirit);
                    return effect.MiscValue < 5 ? Bit(primary[effect.MiscValue]) : 0;
                }
                case SPELL_AURA_MOD_ATTACK_POWER:
                case SPELL_AURA_MOD_RANGED_ATTACK_POWER:
                    return amount > 0 ? Bit(Stat::AttackPower) : 0;
                case SPELL_AURA_MOD_DAMAGE_DONE:
                case SPELL_AURA_MOD_HEALING_DONE:
                    return amount > 0 ? Bit(Stat::SpellPower) : 0;
                case SPELL_AURA_MOD_HIT_CHANCE:
                case SPELL_AURA_MOD_SPELL_HIT_CHANCE:
                    return amount > 0 ? Bit(Stat::Hit) : 0;
                case SPELL_AURA_MOD_WEAPON_CRIT_PERCENT:
                case SPELL_AURA_MOD_SPELL_CRIT_CHANCE:
                case SPELL_AURA_MOD_SPELL_CRIT_CHANCE_SCHOOL:
                case SPELL_AURA_MOD_CRIT_PCT:
                    return amount > 0 ? Bit(Stat::Crit) : 0;
                case SPELL_AURA_MOD_MELEE_HASTE:
                case SPELL_AURA_MOD_RANGED_HASTE:
                case SPELL_AURA_MOD_CASTING_SPEED_NOT_STACK:
                    return amount > 0 ? Bit(Stat::Haste) : 0;
                case SPELL_AURA_MOD_EXPERTISE:
                    return amount > 0 ? Bit(Stat::Expertise) : 0;
                case SPELL_AURA_MOD_SKILL:
                    return amount > 0 && effect.MiscValue == SKILL_DEFENSE ? Bit(Stat::Defense) : 0;
                case SPELL_AURA_MOD_DODGE_PERCENT:
                    return amount > 0 ? Bit(Stat::Dodge) : 0;
                case SPELL_AURA_MOD_PARRY_PERCENT:
                    return amount > 0 ? Bit(Stat::Parry) : 0;
                case SPELL_AURA_MOD_BLOCK_PERCENT:
                case SPELL_AURA_MOD_SHIELD_BLOCKVALUE:
                    return amount > 0 ? Bit(Stat::Block) : 0;
                case SPELL_AURA_MOD_POWER_REGEN:
                    return amount > 0 && effect.MiscValue == POWER_MANA ? Bit(Stat::ManaRegen) : 0;
                case SPELL_AURA_MOD_TARGET_RESISTANCE:
                    // Spell penetration lowers the target's resistance: a negative amount.
                    return amount < 0 ? Bit(Stat::SpellPen) : 0;
                default:
                    return 0;
            }
        }

        std::unordered_map<uint32, uint32> sSpellMasks;

        uint32 SpellMask(uint32 spellId)
        {
            auto itr = sSpellMasks.find(spellId);
            if (itr != sSpellMasks.end())
                return itr->second;

            uint32 mask = 0;
            if (SpellInfo const* spell = sSpellMgr->GetSpellInfo(spellId))
                for (SpellEffectInfo const& effect : spell->GetEffects())
                    if (effect.Effect == SPELL_EFFECT_APPLY_AURA)
                        mask |= FromAura(effect);
            return sSpellMasks.emplace(spellId, mask).first->second;
        }

        std::unordered_map<uint32, uint32> sEnchantMasks;

        uint32 EnchantMask(uint32 enchantId)
        {
            auto itr = sEnchantMasks.find(enchantId);
            if (itr != sEnchantMasks.end())
                return itr->second;

            uint32 mask = 0;
            if (SpellItemEnchantmentEntry const* enchant = sSpellItemEnchantmentStore.LookupEntry(enchantId))
            {
                for (uint32 i = 0; i < MAX_SPELL_ITEM_ENCHANTMENT_EFFECTS; ++i)
                {
                    if (enchant->type[i] == ITEM_ENCHANTMENT_TYPE_STAT)
                        mask |= Bit(FromItemMod(enchant->spellid[i]));
                    else if (enchant->type[i] == ITEM_ENCHANTMENT_TYPE_EQUIP_SPELL && enchant->spellid[i])
                        mask |= SpellMask(enchant->spellid[i]);
                }
            }
            return sEnchantMasks.emplace(enchantId, mask).first->second;
        }

        std::unordered_map<uint32, uint32> sTemplateMasks;
        std::unordered_map<int32, uint32> sRandomMasks;
    }

    uint32 TemplateMask(ItemTemplate const* proto)
    {
        auto itr = sTemplateMasks.find(proto->ItemId);
        if (itr != sTemplateMasks.end())
            return itr->second;

        uint32 mask = 0;
        for (uint32 i = 0; i < MAX_ITEM_PROTO_STATS; ++i)
            if (proto->ItemStat[i].ItemStatValue > 0)
                mask |= Bit(FromItemMod(proto->ItemStat[i].ItemStatType));

        // Heirlooms keep their stats in ScalingStatDistribution.dbc instead.
        if (proto->ScalingStatDistribution)
            if (ScalingStatDistributionEntry const* ssd = sScalingStatDistributionStore.LookupEntry(proto->ScalingStatDistribution))
                for (uint32 i = 0; i < 10; ++i)
                    if (ssd->StatMod[i] >= 0 && ssd->Modifier[i])
                        mask |= Bit(FromItemMod(uint32(ssd->StatMod[i])));

        for (uint32 i = 0; i < MAX_ITEM_PROTO_SPELLS; ++i)
            if (proto->Spells[i].SpellId > 0 && proto->Spells[i].SpellTrigger == ITEM_SPELLTRIGGER_ON_EQUIP)
                mask |= SpellMask(uint32(proto->Spells[i].SpellId));

        for (uint32 i = 0; i < MAX_ITEM_PROTO_SOCKETS; ++i)
            if (proto->Socket[i].Color)
                mask |= Bit(Stat::Sockets);

        return sTemplateMasks.emplace(proto->ItemId, mask).first->second;
    }

    uint32 ItemMask(ItemTemplate const* proto, Item const* item)
    {
        uint32 mask = TemplateMask(proto);
        int32 id = item ? item->GetItemRandomPropertyId() : 0;
        if (!id)
            return mask;

        auto itr = sRandomMasks.find(id);
        if (itr == sRandomMasks.end())
        {
            // ItemRandomProperties for positive ids, ItemRandomSuffix (scaled by the item) for
            // negative ones; a suffix slot with no allocation adds nothing.
            uint32 random = 0;
            if (id > 0)
            {
                if (ItemRandomPropertiesEntry const* entry = sItemRandomPropertiesStore.LookupEntry(uint32(id)))
                    for (uint32 enchant : entry->Enchantment)
                        if (enchant)
                            random |= EnchantMask(enchant);
            }
            else if (ItemRandomSuffixEntry const* entry = sItemRandomSuffixStore.LookupEntry(uint32(-id)))
            {
                for (uint32 i = 0; i < MAX_ITEM_ENCHANTMENT_EFFECTS; ++i)
                    if (entry->Enchantment[i] && entry->AllocationPct[i])
                        random |= EnchantMask(entry->Enchantment[i]);
            }
            itr = sRandomMasks.emplace(id, random).first;
        }
        return mask | itr->second;
    }
}
