/*
 * mod-retail-ah: what mod-ah-bot-plus's buyer bot pays, so the Sell tab can suggest a price the
 * bot is sure to take. On a realm with few players the bot is often the only buyer around.
 *
 * Every few minutes the buyer looks at a few player auctions. For each it works out what it is
 * willing to pay per unit: the same value its seller lists at (CalculateItemValue), times
 * Buyer.AcceptablePriceModifier, and buys the auction out when the buyout is below that times
 * the stack size. The value has a random part: before the multipliers, the base price is
 * rolled between (1 - BuyoutVariationReducePercent) and (1 + BuyoutVariationAddPercent) of
 * itself. Everything after that roll only ever moves the price the same way, so working the
 * formula with the lowest roll gives the most the bot pays on every look, and the highest roll
 * the most it ever pays.
 *
 * This file mirrors CalculateItemValue and the buyer's checks from mod-ah-bot-plus (f685832,
 * July 2026), reading the bot's own AuctionHouseBot.* options with the same defaults, so
 * either module builds without the other. The float steps are kept as the bot writes them,
 * so the truncation lands on the same copper.
 */

#include "RetailAH.h"
#include "Config.h"
#include "DatabaseEnv.h"
#include "ItemTemplate.h"
#include "Log.h"
#include "ObjectMgr.h"
#include "Player.h"
#include <algorithm>
#include <cmath>
#include <sstream>
#include <unordered_map>
#include <unordered_set>

namespace RetailAH::AhBot
{
    namespace
    {
        // Indexed by item class: the bot's name for it in option keys, and whether it has its
        // own PriceMultiplier.Category / ItemLevel / PriceMinimumCenterBase options.
        struct ClassInfo
        {
            char const* name;
            bool ownOptions;
            uint32 defaultMinimum;
        };

        ClassInfo const CLASSES[MAX_ITEM_CLASS] =
        {
            { "Consumable", true, 1000 },
            { "Container",  true, 1000 },
            { "Weapon",     true, 1000 },
            { "Gem",        true, 1000 },
            { "Armor",      true, 1000 },
            { "Reagent",    true, 1000 },
            { "Projectile", true, 5 },
            { "TradeGood",  true, 850 },
            { "Generic",    true, 1000 },
            { "Recipe",     true, 1000 },
            { "Money",      false, 1000 },
            { "Quiver",     true, 1000 },
            { "Quest",      true, 1000 },
            { "Key",        true, 1000 },
            { "Permanent",  false, 1000 },
            { "Misc",       true, 1000 },
            { "Glyph",      true, 1000 },
        };

        char const* const QUALITIES[MAX_ITEM_QUALITY] =
        {
            "Poor", "Normal", "Uncommon", "Rare", "Epic", "Legendary", "Artifact", "Heirloom"
        };

        float const QUALITY_DEFAULTS[MAX_ITEM_QUALITY] = { 1.0f, 1.0f, 1.8f, 1.9f, 2.1f, 3.0f, 3.0f, 3.0f };
        float const MOUNT_DEFAULTS[MAX_ITEM_QUALITY] = { 1.0f, 1.0f, 1.0f, 3000.0f, 5750.0f, 1.0f, 1.0f, 1.0f };

        enum Advanced
        {
            ADV_POTION, ADV_ELIXIR, ADV_FLASK, ADV_GEM, ADV_CLOTH, ADV_HERB, ADV_METAL_STONE,
            ADV_LEATHER, ADV_ENCHANTING, ADV_ELEMENTAL, ADV_MEAT, ADV_JUNK, ADV_MOUNT, ADV_PET,
            ADV_COUNT
        };

        char const* const ADVANCED_KEYS[ADV_COUNT] =
        {
            "Consumable.Potion", "Consumable.Elixir", "Consumable.Flask", "Gem", "TradeGood.Cloth",
            "TradeGood.Herb", "TradeGood.MetalStone", "TradeGood.Leather", "TradeGood.Enchanting",
            "TradeGood.Elemental", "TradeGood.Meat", "Misc.Junk", "Misc.Mount", "Misc.Pet"
        };

        struct Settings
        {
            bool buyer = false;
            bool buys = true;  // Buyer.BuyCandidatesPerBuyCycle isn't 0
            std::unordered_set<ObjectGuid::LowType> bots;

            bool overrideEnabled = false;
            bool overrideVariations = false;
            std::unordered_map<uint32, uint64> overrides;

            float reduce = 0.15f;
            float add = 0.25f;
            bool belowVendor = true;
            float belowVendorAdd = 0.25f;
            uint32 maxBuyout = 1000000000;
            float acceptable = 1.0f;
            bool preventOverpaying = true;
            bool skipNoVendorPrice = false;
            bool useSellPrice = true;

            float classMultiplier[MAX_ITEM_CLASS] = { };
            float levelMultiplier[MAX_ITEM_CLASS] = { };
            uint32 minimum[MAX_ITEM_CLASS] = { };
            std::unordered_map<uint32, uint64> minimumOverrides;
            float qualityMultiplier[MAX_ITEM_QUALITY] = { };
            float classQuality[MAX_ITEM_CLASS][MAX_ITEM_QUALITY] = { };
            float mount[MAX_ITEM_QUALITY] = { };
            float pet[MAX_ITEM_QUALITY] = { };
            bool advanced[ADV_COUNT] = { };
        };

        Settings sSettings;

        // Vendor-sold items other than trade goods, which the bot won't pay more than a vendor
        // gives for (PreventOverpayingForVendorItems).
        std::unordered_set<uint32> sVendorItems;

        // "id:value,id:value", as the bot's AddItemValuePairsToItemIDMap reads it.
        void ParsePairs(std::unordered_map<uint32, uint64>& out, std::string const& text)
        {
            out.clear();
            std::stringstream stream(text);
            std::string block;
            while (std::getline(stream, block, ','))
            {
                std::string trimmed;
                std::stringstream(block) >> trimmed;
                std::size_t colon = trimmed.find(':');
                if (colon == std::string::npos)
                    continue;
                int id = atoi(trimmed.substr(0, colon).c_str());
                int value = atoi(trimmed.substr(colon + 1).c_str());
                if (id > 0 && value > 0)
                    out.insert({ uint32(id), uint64(value) });
            }
        }

        // GetAdvancedPricingMultiplier, formula for formula.
        float AdvancedMultiplier(ItemTemplate const* proto)
        {
            Settings const& s = sSettings;
            double m = 1.0f;
            if (proto->Class == ITEM_CLASS_CONSUMABLE)
            {
                switch (proto->SubClass)
                {
                    case ITEM_SUBCLASS_POTION:
                    {
                        if (!s.advanced[ADV_POTION])
                            break;
                        double h = std::log(1.0 + (0.08 * proto->ItemLevel));
                        m = ((std::pow(h, 3.0)) / (1 + (4.0 * h))) + (std::pow(h, 2.5));
                        break;
                    }
                    case ITEM_SUBCLASS_ELIXIR:
                    {
                        if (!s.advanced[ADV_ELIXIR])
                            break;
                        double h = std::log(1.0 + (1.6 * proto->ItemLevel));
                        m = ((std::pow(h, 3.1)) / (1 + (5.0 * h))) + (0.05 * std::pow(h, 3.2)) - 1.0;
                        break;
                    }
                    case ITEM_SUBCLASS_FLASK:
                    {
                        if (!s.advanced[ADV_FLASK])
                            break;
                        m = (220000 + (250000 - 220000) * (std::log(proto->SellPrice) - std::log(1250)) / (std::log(10000) - std::log(1250))) / proto->SellPrice;
                        break;
                    }
                    default:
                        break;
                }
            }
            else if (proto->Class == ITEM_CLASS_GEM && s.advanced[ADV_GEM])
            {
                double h = std::log(1.0 + (0.05 * proto->ItemLevel));
                m = ((std::pow(h, 1.0)) / (1 + (10.0 * h))) + (std::pow(h, 3.0));
            }
            else if (proto->Class == ITEM_CLASS_TRADE_GOODS)
            {
                switch (proto->SubClass)
                {
                    case ITEM_SUBCLASS_CLOTH:
                    {
                        if (!s.advanced[ADV_CLOTH])
                            break;
                        double h = std::log(1.0 + (proto->ItemLevel));
                        m = ((std::pow(h, 2.0)) / (1 + (0.8 * h))) + (0.001 * std::pow(h, 3.5)) - 0.3;
                        break;
                    }
                    case ITEM_SUBCLASS_HERB:
                    {
                        if (!s.advanced[ADV_HERB])
                            break;
                        double h = std::log(1.0 + (5.0 * proto->ItemLevel));
                        m = (std::pow(h, 3.0) / (1 + (1.8 * h))) - 4.2;
                        break;
                    }
                    case ITEM_SUBCLASS_METAL_STONE:
                    {
                        if (!s.advanced[ADV_METAL_STONE])
                            break;
                        double h = std::log(1.0 + (75.0 * proto->ItemLevel));
                        m = ((std::pow(h, 3.0)) / (1 + (7.0 * h))) + (0.001 * std::pow(h, 3.5)) - 5.2;
                        break;
                    }
                    case ITEM_SUBCLASS_LEATHER:
                    {
                        if (!s.advanced[ADV_LEATHER])
                            break;
                        double h = std::log(1.0 + (0.25 * proto->ItemLevel));
                        m = ((std::pow(h, 0.15)) / (1 + (2.0 * h))) + (0.4 * std::pow(h, 3.0)) - 0.2;
                        break;
                    }
                    case ITEM_SUBCLASS_ENCHANTING:
                    {
                        if (!s.advanced[ADV_ENCHANTING])
                            break;
                        double h = std::log(1.0 + (0.25 * proto->ItemLevel));
                        m = ((std::pow(h, 0.15)) / (1 + (2.0 * h))) + (0.4 * std::pow(h, 3.0)) - 0.2;
                        break;
                    }
                    case ITEM_SUBCLASS_ELEMENTAL:
                    {
                        if (!s.advanced[ADV_ELEMENTAL])
                            break;
                        m = 85 - (proto->ItemLevel / 0.97);
                        break;
                    }
                    case ITEM_SUBCLASS_MEAT:
                    {
                        if (!s.advanced[ADV_MEAT])
                            break;
                        double h = std::log(1.0 + (0.5 * proto->ItemLevel));
                        m = ((std::pow(h, 3.2)) / (1 + (2.0 * h))) + (0.05 * std::pow(h, 3.2)) - 0.1;
                        break;
                    }
                    default:
                        break;
                }
            }
            else if (proto->Class == ITEM_CLASS_MISC)
            {
                switch (proto->SubClass)
                {
                    case ITEM_SUBCLASS_JUNK:
                    {
                        if (!s.advanced[ADV_JUNK])
                            break;
                        double h = std::log(1.0 + (0.12 * proto->ItemLevel));
                        m = (std::pow(h, 3.2) / (1 + h));
                        break;
                    }
                    case ITEM_SUBCLASS_JUNK_MOUNT:
                        if (s.advanced[ADV_MOUNT] && proto->Quality < MAX_ITEM_QUALITY)
                            m = s.mount[proto->Quality];
                        break;
                    case ITEM_SUBCLASS_JUNK_PET:
                        if (s.advanced[ADV_PET] && proto->Quality < MAX_ITEM_QUALITY)
                            m = s.pet[proto->Quality];
                        break;
                    default:
                        break;
                }
            }
            return static_cast<float>(m);
        }

        // CalculateItemValue's buyout with the variation roll fixed at its low or high end, up to
        // (not including) the below-vendor bump. urand(a, b) becomes a or b; its arguments go
        // through uint32 as they do in the bot. `final` is set when the price skips the rest.
        uint64 RolledValue(ItemTemplate const* proto, bool high, bool& final)
        {
            final = false;
            Settings const& s = sSettings;
            auto roll = [high](uint32 low, uint32 top) { return high ? std::max(low, top) : std::min(low, top); };

            if (s.overrideEnabled)
            {
                auto itr = s.overrides.find(proto->ItemId);
                if (itr != s.overrides.end())
                {
                    uint64 price = itr->second;
                    if (s.overrideVariations)
                        price = roll(static_cast<uint32>(price * (1.0f - s.reduce)), static_cast<uint32>(price * (1.0f + s.add)));
                    final = true;
                    return price;
                }
            }

            uint64 price = s.useSellPrice ? proto->SellPrice : 1;

            bool known = proto->Class < MAX_ITEM_CLASS;
            float classMultiplier = known ? s.classMultiplier[proto->Class] : 1.0f;
            float qualityMultiplier = proto->Quality < MAX_ITEM_QUALITY ? s.qualityMultiplier[proto->Quality] : 1.0f;
            float classQualityMultiplier = known && proto->Quality < MAX_ITEM_QUALITY ? s.classQuality[proto->Class][proto->Quality] : 1.0f;
            float advancedMultiplier = AdvancedMultiplier(proto);

            uint64 minimum = 1000;
            auto overrideItr = s.minimumOverrides.find(proto->ItemId);
            if (overrideItr != s.minimumOverrides.end())
                minimum = overrideItr->second;
            else if (known)
                minimum = s.minimum[proto->Class];

            if (price < minimum)
                price = roll(static_cast<uint32>(minimum * (1.0f - s.reduce)), static_cast<uint32>(minimum * (1.0f + s.add)));
            else
                price = roll(static_cast<uint32>(price * (1.0f - s.reduce)), static_cast<uint32>(price * (1.0f + s.add)));

            if (classMultiplier <= 0.0f)
                classMultiplier = 1.0f;
            if (qualityMultiplier <= 0.0f)
                qualityMultiplier = 1.0f;
            if (classQualityMultiplier <= 0.0f)
                classQualityMultiplier = 1.0f;
            if (advancedMultiplier <= 0.0f)
                advancedMultiplier = 1.0f;

            float levelMultiplier = known ? s.levelMultiplier[proto->Class] : 0.0f;

            price *= qualityMultiplier;
            price *= classMultiplier;
            price *= classQualityMultiplier;
            price *= static_cast<float>(advancedMultiplier);

            if (levelMultiplier > 0.0f && proto->ItemLevel > 0 && advancedMultiplier == 1.0f)
                price *= proto->ItemLevel * levelMultiplier;

            if (price > s.maxBuyout)
                price = s.maxBuyout;
            return price;
        }

        // The finished buyout on the low or the high roll. A price that lands below what a
        // vendor pays is rolled again between SellPrice and (1 + BelowVendorAdd) x SellPrice.
        // That bump isn't monotonic: a low first roll can end above a high one, so the best
        // case is whichever is higher.
        uint64 ItemValue(ItemTemplate const* proto, bool high)
        {
            Settings const& s = sSettings;
            bool final = false;
            uint64 price = RolledValue(proto, high, final);
            if (!final && s.belowVendor)
            {
                uint32 bumpTop = static_cast<uint32>((1.0f + s.belowVendorAdd) * proto->SellPrice);
                if (price < proto->SellPrice)
                    price = high ? std::max<uint32>(proto->SellPrice, bumpTop) : std::min<uint32>(proto->SellPrice, bumpTop);
                else if (high && RolledValue(proto, false, final) < proto->SellPrice)
                    price = std::max<uint64>(price, std::max<uint32>(proto->SellPrice, bumpTop));
            }
            if (price == 0)
                price = 1;
            return price;
        }

        // What the buyer is willing to pay per unit on that roll.
        uint64 Willing(ItemTemplate const* proto, bool high)
        {
            return (uint64)((float)ItemValue(proto, high) * sSettings.acceptable);
        }
    }

    void LoadConfig()
    {
        Settings& s = sSettings;

        s.buyer = sConfigMgr->GetOption<bool>("AuctionHouseBot.Buyer.Enabled", false, false);
        // "min:max" always means at least one; a plain 0 switches the buyer off.
        std::string candidates = sConfigMgr->GetOption<std::string>("AuctionHouseBot.Buyer.BuyCandidatesPerBuyCycle", "1", false);
        s.buys = candidates.find(':') != std::string::npos || atoi(candidates.c_str()) > 0;

        s.bots.clear();
        std::stringstream guids(sConfigMgr->GetOption<std::string>("AuctionHouseBot.GUIDs", "0", false));
        std::string guid;
        while (std::getline(guids, guid, ','))
        {
            std::string trimmed;
            std::stringstream(guid) >> trimmed;
            if (int value = atoi(trimmed.c_str()); value > 0)
                s.bots.insert(ObjectGuid::LowType(value));
        }

        s.overrideEnabled = sConfigMgr->GetOption<bool>("AuctionHouseBot.CompleteItemValueOverride.Enabled", false, false);
        ParsePairs(s.overrides, sConfigMgr->GetOption<std::string>("AuctionHouseBot.CompleteItemValueOverride.Items", "", false));
        s.overrideVariations = sConfigMgr->GetOption<bool>("AuctionHouseBot.CompleteItemValueOverride.DoApplyBuyoutVariations", false, false);

        s.maxBuyout = sConfigMgr->GetOption<uint32>("AuctionHouseBot.MaxBuyoutPriceInCopper", 1000000000, false);
        s.reduce = sConfigMgr->GetOption<float>("AuctionHouseBot.BuyoutVariationReducePercent", 0.15f, false);
        s.add = sConfigMgr->GetOption<float>("AuctionHouseBot.BuyoutVariationAddPercent", 0.25f, false);
        s.belowVendor = sConfigMgr->GetOption<bool>("AuctionHouseBot.BuyoutBelowVendorVariationAddPercentEnabled", true, false);
        s.belowVendorAdd = sConfigMgr->GetOption<float>("AuctionHouseBot.BuyoutBelowVendorVariationAddPercent", 0.25f, false);
        s.acceptable = sConfigMgr->GetOption<float>("AuctionHouseBot.Buyer.AcceptablePriceModifier", 1, false);
        s.preventOverpaying = sConfigMgr->GetOption<bool>("AuctionHouseBot.Buyer.PreventOverpayingForVendorItems", true, false);
        s.skipNoVendorPrice = sConfigMgr->GetOption<bool>("AuctionHouseBot.Buyer.SkipItemsWithoutVendorPrice", false, false);
        s.useSellPrice = sConfigMgr->GetOption<bool>("AuctionHouseBot.PriceMinimumCenterBase.UseItemSellPriceIfHigher", true, false);
        ParsePairs(s.minimumOverrides, sConfigMgr->GetOption<std::string>("AuctionHouseBot.PriceMinimumCenterBase.OverrideItems", "", false));

        for (uint32 c = 0; c < MAX_ITEM_CLASS; ++c)
        {
            ClassInfo const& info = CLASSES[c];
            std::string name = info.name;
            s.classMultiplier[c] = info.ownOptions ? sConfigMgr->GetOption<float>("AuctionHouseBot.PriceMultiplier.Category." + name, 1, false) : 1.0f;
            s.levelMultiplier[c] = info.ownOptions ? sConfigMgr->GetOption<float>("AuctionHouseBot.PriceMultiplier.ItemLevel.Category." + name, 0, false) : 0.0f;
            s.minimum[c] = info.ownOptions ? sConfigMgr->GetOption<uint32>("AuctionHouseBot.PriceMinimumCenterBase." + name, info.defaultMinimum, false) : 1000;
            for (uint32 q = 0; q < MAX_ITEM_QUALITY; ++q)
                s.classQuality[c][q] = sConfigMgr->GetOption<float>("AuctionHouseBot.PriceMultiplier.Category" + name + ".Quality" + QUALITIES[q], 1.0f, false);
        }

        for (uint32 q = 0; q < MAX_ITEM_QUALITY; ++q)
        {
            std::string quality = QUALITIES[q];
            s.qualityMultiplier[q] = sConfigMgr->GetOption<float>("AuctionHouseBot.PriceMultiplier.Quality." + quality, QUALITY_DEFAULTS[q], false);
            s.mount[q] = sConfigMgr->GetOption<float>("AuctionHouseBot.PriceMultiplier.CategoryMount.Quality" + quality, MOUNT_DEFAULTS[q], false);
            s.pet[q] = sConfigMgr->GetOption<float>("AuctionHouseBot.PriceMultiplier.CategoryPet.Quality" + quality, 1.0f, false);
        }

        for (uint32 a = 0; a < ADV_COUNT; ++a)
            s.advanced[a] = sConfigMgr->GetOption<bool>(std::string("AuctionHouseBot.AdvancedPricing.") + ADVANCED_KEYS[a] + ".Enabled", true, false);
    }

    void LoadVendorItems()
    {
        sVendorItems.clear();
        QueryResult result = WorldDatabase.Query("SELECT DISTINCT v.entry FROM item_template v JOIN npc_vendor p ON v.entry = p.item WHERE v.class != {}",
            uint32(ITEM_CLASS_TRADE_GOODS));
        if (!result)
            return;
        do
            sVendorItems.insert(result->Fetch()[0].Get<uint32>());
        while (result->NextRow());
    }

    bool BuyerEnabled()
    {
        return GetConfig().botPrice && sSettings.buyer && sSettings.buys && !sSettings.bots.empty();
    }

    bool IsBot(ObjectGuid::LowType guid)
    {
        return sSettings.bots.count(guid) != 0;
    }

    bool BuyRange(ItemTemplate const* proto, uint64& always, uint64& upTo)
    {
        always = upTo = 0;
        if (!proto || !BuyerEnabled())
            return false;

        // The bot compares a vendor item's whole buyout with what one copy sells to a vendor
        // for: it only ever buys those at vendor price, which isn't worth an auction.
        if (sSettings.preventOverpaying && proto->SellPrice > 0 && sVendorItems.count(proto->ItemId))
            return false;

        // Buyer.SkipItemsWithoutVendorPrice (buildthehomelab fork): no buy or sell price, apart from
        // enchanting trade goods and item enhancements, means the bot never buys it.
        if (sSettings.skipNoVendorPrice && proto->SellPrice == 0 && proto->BuyPrice == 0
            && !(proto->Class == ITEM_CLASS_TRADE_GOODS && proto->SubClass == ITEM_SUBCLASS_ENCHANTING)
            && !(proto->Class == ITEM_CLASS_CONSUMABLE && proto->SubClass == ITEM_SUBCLASS_ITEM_ENHANCEMENT))
            return false;

        // It buys out when buyout < willing x count, so one copper under the per-unit figure.
        uint64 low = Willing(proto, false);
        uint64 high = Willing(proto, true);
        always = low > 1 ? low - 1 : 0;
        upTo = high > 1 ? high - 1 : 0;
        return upTo > 0;
    }

    // V:<req>:<entry>   Answer: V:<req>:<always>:<up to>, per unit; 0:0 when the bot won't buy.
    void HandleValue(Context& ctx, std::vector<std::string_view> const& args)
    {
        uint32 entry = 0;
        if (args.size() < 3 || !ParseUInt(args[2], entry))
        {
            SendError(ctx, "bad");
            return;
        }

        uint64 always = 0, upTo = 0;
        BuyRange(sObjectMgr->GetItemTemplate(entry), always, upTo);
        Send(ctx.player, "V:" + ctx.req + ":" + std::to_string(always) + ":" + std::to_string(upTo));
    }
}
