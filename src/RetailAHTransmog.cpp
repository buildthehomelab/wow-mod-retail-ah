/*
 * mod-retail-ah: which auctions are appearances the player hasn't collected, for
 * mod-transmog-plus.
 *
 * transmog-plus stores an account's collection as item entries in
 * `mod_transmog_plus_appearances` and counts a look (the item's DisplayInfoID) as collected
 * when any item with that look is. This file reads that table (no link to the other module, so
 * either builds without the other) and mirrors its rules for what counts as an appearance:
 * armor or a weapon with a model, not a ring, neck, trinket, bag, relic, quiver or ammo, not a
 * placeholder item, of a quality its Transmog.Allow* options permit.
 *
 * An account's looks are read when the player opens the auction house and at most once a
 * minute after that, so something collected mid-visit shows up shortly.
 */

#include "RetailAH.h"
#include "Config.h"
#include "DatabaseEnv.h"
#include "ItemTemplate.h"
#include "Log.h"
#include "ObjectMgr.h"
#include "Player.h"
#include "Timer.h"
#include "WorldSession.h"
#include <unordered_map>
#include <unordered_set>

namespace RetailAH::Appearances
{
    namespace
    {
        bool sTablePresent = false;

        constexpr uint32 REFRESH_MS = 60 * IN_MILLISECONDS;

        struct AccountLooks
        {
            std::unordered_set<uint32> displays;
            uint32 loadedAt = 0;
        };

        std::unordered_map<uint32, AccountLooks> sLooks;

        // transmog-plus's options, read with the config rather than per item.
        struct Options
        {
            bool enabled = true;
            bool fishingPoles = false;
            bool qualities[8] = { true, true, true, true, true, true, true, true };
        } sOptions;

        AccountLooks const& LooksFor(uint32 accountId)
        {
            AccountLooks& looks = sLooks[accountId];
            uint32 now = getMSTime();
            if (looks.loadedAt && getMSTimeDiff(looks.loadedAt, now) < REFRESH_MS)
                return looks;

            looks.displays.clear();
            looks.loadedAt = now ? now : 1;
            if (QueryResult result = CharacterDatabase.Query(
                "SELECT item_template_id FROM mod_transmog_plus_appearances WHERE account_id = {}", accountId))
            {
                do
                {
                    if (ItemTemplate const* proto = sObjectMgr->GetItemTemplate((*result)[0].Get<uint32>()))
                        if (proto->DisplayInfoID)
                            looks.displays.insert(proto->DisplayInfoID);
                } while (result->NextRow());
            }
            return looks;
        }

        bool QualityAllowed(uint32 quality)
        {
            return quality < std::size(sOptions.qualities) && sOptions.qualities[quality];
        }
    }

    void LoadOptions()
    {
        static char const* const QUALITIES[] = {
            "Transmog.AllowPoor", "Transmog.AllowCommon", "Transmog.AllowUncommon", "Transmog.AllowRare",
            "Transmog.AllowEpic", "Transmog.AllowLegendary", "Transmog.AllowArtifact", "Transmog.AllowHeirloom",
        };
        sOptions.enabled = sConfigMgr->GetOption<bool>("Transmog.Enable", true, false);
        sOptions.fishingPoles = sConfigMgr->GetOption<bool>("Transmog.AllowFishingPoles", false, false);
        for (std::size_t i = 0; i < std::size(QUALITIES); ++i)
            sOptions.qualities[i] = sConfigMgr->GetOption<bool>(QUALITIES[i], true, false);
        // Options changed: what counts as an appearance may have too.
        sLooks.clear();
    }

    void CheckTable()
    {
        sTablePresent = false;
        if (QueryResult result = CharacterDatabase.Query("SHOW TABLES LIKE 'mod_transmog_plus_appearances'"))
            sTablePresent = true;
        if (sTablePresent && GetConfig().transmog)
            LOG_INFO("module", "mod-retail-ah: marking uncollected mod-transmog-plus appearances is on.");
    }

    bool Enabled()
    {
        return sTablePresent && GetConfig().transmog && sOptions.enabled;
    }

    // transmog-plus's IsListableSource plus its quality and fishing pole options.
    bool IsAppearance(ItemTemplate const* proto)
    {
        if (!proto || (proto->Class != ITEM_CLASS_ARMOR && proto->Class != ITEM_CLASS_WEAPON) || !proto->DisplayInfoID)
            return false;

        switch (proto->InventoryType)
        {
            case INVTYPE_NON_EQUIP:
            case INVTYPE_BAG:
            case INVTYPE_RELIC:
            case INVTYPE_FINGER:
            case INVTYPE_TRINKET:
            case INVTYPE_AMMO:
            case INVTYPE_QUIVER:
            case INVTYPE_NECK:
                return false;
            default:
                break;
        }

        for (char const* marker : { "Monster -", "Deprecated", "DEPRECATED", "OLD", "[PH]", "Test ", "TEST", "QA " })
            if (proto->Name1.find(marker) != std::string::npos)
                return false;

        if (proto->Class == ITEM_CLASS_WEAPON && proto->SubClass == ITEM_SUBCLASS_WEAPON_FISHING_POLE
            && !sOptions.fishingPoles)
            return false;

        return QualityAllowed(proto->Quality);
    }

    Look State(Player const* player, ItemTemplate const* proto)
    {
        if (!Enabled() || !IsAppearance(proto))
            return Look::NotAnAppearance;
        AccountLooks const& looks = LooksFor(player->GetSession()->GetAccountId());
        return looks.displays.count(proto->DisplayInfoID) ? Look::Collected : Look::Uncollected;
    }

    void Forget(uint32 accountId)
    {
        sLooks.erase(accountId);
    }
}
