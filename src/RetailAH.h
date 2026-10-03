/*
 * mod-retail-ah
 *
 * Server half of a retail-style auction house. The RetailAH addon replaces the Blizzard auction
 * window and talks to this module through addon whispers; the module answers with results the
 * 3.3.5a protocol can't express (auctions grouped by item, commodity price tiers, quotes for any
 * quantity) and carries out purchases, posts and cancellations.
 *
 * Every trade that maps onto a stock auction action is handed to the core's own opcode handler,
 * so deposits, the house cut, mails, achievements, logging and other modules' hooks behave
 * exactly as they do for the old window. The only new trade is buying part of a stack, which
 * splits the auction in two and buys out the piece.
 *
 * Released under the MIT License.
 */

#ifndef MOD_RETAIL_AH_H
#define MOD_RETAIL_AH_H

#include "Define.h"
#include "DatabaseEnvFwd.h"
#include "ObjectGuid.h"
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

class AuctionHouseObject;
class Creature;
class Item;
class Player;
struct AuctionEntry;
struct AuctionHouseEntry;
struct ItemTemplate;

namespace RetailAH
{
    // Addon message prefix; the client sends "RAH\t<command>" as a whisper to itself.
    constexpr char const* PREFIX = "RAH";

    // Bumped when a message changes shape. The addon refuses to run against another version.
    constexpr uint32 PROTOCOL_VERSION = 1;

    // Leaves room for the prefix and tab inside the client's 255-byte chat message limit.
    constexpr std::size_t MAX_PAYLOAD = 240;

    struct Config
    {
        bool enabled = true;
        uint32 maxResults = 500;
        uint32 maxDetailRows = 300;
        uint32 searchCooldownMs = 0;
        bool reagentBank = true;
        bool transmog = true;
        bool botPrice = true;
        bool ledger = true;
        uint32 ledgerKeepDays = 180;
        uint32 ledgerMaxRows = 300;
        // What a player may see (RetailAHGate.cpp).
        bool eraGate = true;
        bool levelGate = true;
        uint32 levelMargin = 2;
        bool levelGateItemLevel = true;
        bool classicWindow = true;
        // K: prices for the profession window, asked away from the auctioneer.
        bool craftPrices = true;
    };

    // Capability bits in the HELLO answer, so a newer addon can tell what this server offers.
    enum HelloFlags : uint32
    {
        HELLO_REAGENT_BANK = 0x1,
        HELLO_APPEARANCES  = 0x2,  // mod-transmog-plus collections: marker and filter
        HELLO_STAT_FILTERS = 0x4,  // the search takes a stat mask
        HELLO_BOT_PRICE    = 0x8,  // V answers what mod-ah-bot-plus's buyer pays
        HELLO_LEDGER       = 0x10, // G answers the gold ledger
        HELLO_ITEM_INFO    = 0x20, // N answers item names and levels; HELLO's 5th field stamps them
        HELLO_GATES        = 0x40, // HELLO's 6th-8th fields describe what the player may see
        HELLO_CRAFT_PRICES = 0x80, // K answers prices anywhere (RetailProfessions' profit view)
    };

    // In place of a bag number: the "slot" field is an item entry, and the units may come from
    // the reagent bank as well as the bags. Commodities only.
    constexpr uint32 BAG_BY_ENTRY = 255;

    Config& GetConfig();
    void LoadConfig();

    // A validated request: the player is standing at an auctioneer, and this is its house.
    struct Context
    {
        Player* player = nullptr;
        Creature* auctioneer = nullptr;
        AuctionHouseObject* house = nullptr;
        AuctionHouseEntry const* houseEntry = nullptr;
        std::string req;  // echoed back so the addon can match answers to requests
    };

    // ---- RetailAH.cpp: transport -------------------------------------------------------------

    void Send(Player* player, std::string const& payload);

    // Sends "<header>:<row>;<row>;..." in as many messages as it takes, never splitting a row.
    void SendRows(Player* player, std::string const& header, std::vector<std::string> const& rows);

    void SendError(Context const& ctx, std::string_view what);

    bool ParseUInt(std::string_view text, uint32& out);
    bool ParseInt(std::string_view text, int32& out);
    std::vector<std::string_view> Split(std::string_view text, char sep, std::size_t maxParts = 0);

    // ---- RetailAHGate.cpp: what a player may see -----------------------------------------------

    namespace Era
    {
        struct Table;
    }

    namespace Gate
    {
        // No era gate for this player: GM, excluded or bot account, IP off or not installed.
        constexpr uint8 ERA_ALL = 0xFF;

        // Why an item is hidden from a player. Zero fields don't hold it back.
        struct Lock
        {
            uint8 level = 0;  // the character level that shows it
            uint8 era = 0;    // the mod-individual-progression state that shows it

            bool Locked() const { return level || era; }
        };

        // One player's gates, worked out when a request comes in. Cheap: no database access
        // until Owns() is asked, so it may be built on any thread that owns the player and,
        // without Owns(), used on another (the classic search).
        class View
        {
        public:
            explicit View(Player* player);

            // The item's own lock, ignoring what the player owns.
            Lock Check(ItemTemplate const* proto) const;
            // Can the player see, bid on and buy it.
            bool Visible(ItemTemplate const* proto) const { return !Check(proto).Locked(); }
            // Can the player look up its listings: also when they own one (bags, bank, reagent
            // bank), so the Sell tab can price what they post. Never enough to buy it.
            bool VisibleOrOwned(ItemTemplate const* proto) const;
            // Reads the bags and the reagent bank on first use; the player's own thread only.
            bool Owns(uint32 entry) const;

            // False when nothing could be hidden from this player.
            bool HidesAnything() const;
            uint8 Era() const { return _era; }
            // Highest level need shown; 0 = no level gate.
            uint32 LevelCap() const { return _levelCap; }

        private:
            void ReadOwned() const;

            Player* _player;
            uint8 _era = ERA_ALL;
            std::shared_ptr<Era::Table const> _table;
            uint32 _levelCap = 0;
            uint32 _levelCapEra = 0;  // the level where the level gate steps aside
            mutable bool _ownedRead = false;
            mutable std::unordered_set<uint32> _owned;
        };

        // Called from LoadConfig and at startup.
        void LoadConfig();
        void Load();
        // The Buy tab's stat filters that mean something at this era (bits as GearStats::Stat).
        uint32 StatsAvailable(uint8 era);
        // The classic window's search runs through the gates too (RetailAHClassic.cpp).
        bool FilterClassic();

        // While one is alive on this thread, this module's own OnPlayerCanPlaceAuctionBid lets
        // everything through: VisibilityCache has already applied the gates and only asks the
        // hook for other modules' answers.
        class SkipBidHook
        {
        public:
            SkipBidHook();
            ~SkipBidHook();
            SkipBidHook(SkipBidHook const&) = delete;
            SkipBidHook& operator=(SkipBidHook const&) = delete;
        };
    }

    // ---- RetailAHBrowse.cpp: read-only requests ----------------------------------------------

    // Can this player see and bid on the auction? This module's gates first, then any other
    // module's OnPlayerCanPlaceAuctionBid. Asked once per item entry per request. `showOwned`
    // also shows listings of items the player owns (price lookups for the Sell tab); never use
    // it where the answer lets them buy.
    class VisibilityCache
    {
    public:
        explicit VisibilityCache(Player* player, bool showOwned = false) : _player(player), _view(player), _showOwned(showOwned) { }
        bool Visible(AuctionEntry* auction);
        Gate::View const& View() const { return _view; }

    private:
        Player* _player;
        Gate::View _view;
        bool _showOwned;
        std::unordered_map<uint32, bool> _seen;
    };

    bool IsCommodity(ItemTemplate const* proto);

    // Seconds left on an auction, never negative.
    uint32 TimeLeft(AuctionEntry const* auction);

    // True if the auction belongs to the player or to another character on the same account;
    // the core refuses bids on both.
    bool IsOwnAuction(Player* player, AuctionEntry const* auction);

    void HandleSearch(Context& ctx, std::vector<std::string_view> const& args);
    void HandleFavorites(Context& ctx, std::vector<std::string_view> const& args);
    void HandleCommodityDetails(Context& ctx, std::vector<std::string_view> const& args);
    void HandleItemDetails(Context& ctx, std::vector<std::string_view> const& args);
    void HandleOwned(Context& ctx);
    void HandleBids(Context& ctx);

    // ---- RetailAHTrade.cpp: requests that change something -----------------------------------

    void HandleQuote(Context& ctx, std::vector<std::string_view> const& args);
    void HandleCommodityBuy(Context& ctx, std::vector<std::string_view> const& args);
    void HandlePlaceBid(Context& ctx, std::vector<std::string_view> const& args);
    void HandleCancel(Context& ctx, std::vector<std::string_view> const& args);
    void HandleDeposit(Context& ctx, std::vector<std::string_view> const& args);
    void HandlePostCommodity(Context& ctx, std::vector<std::string_view> const& args);
    void HandlePostItem(Context& ctx, std::vector<std::string_view> const& args);

    // Called from the AuctionHouseScript: records auctions the core creates while a post runs.
    void OnAuctionAdded(AuctionEntry const* auction);

    // ---- RetailAHReagentBank.cpp: mod-reagent-bank-account as a source of commodities ---------

    namespace ReagentBank
    {
        void CheckTable();
        bool Enabled();
        uint32 Stored(Player const* player, uint32 entry);
        std::vector<std::pair<uint32, uint32>> Contents(Player const* player);
        void Take(Player const* player, uint32 entry, uint32 count, CharacterDatabaseTransaction trans);
        void NotifyChanged(Player* player);
        void HandleContents(Context& ctx);
    }

    // ---- RetailAHTransmog.cpp: mod-transmog-plus appearance collections -----------------------

    namespace Appearances
    {
        enum class Look : uint8
        {
            NotAnAppearance = 0,
            Collected       = 1,
            Uncollected     = 2,
        };

        void CheckTable();
        void LoadOptions();
        bool Enabled();
        bool IsAppearance(ItemTemplate const* proto);
        Look State(Player const* player, ItemTemplate const* proto);
        // Drops the cached looks so the next question reads them fresh.
        void Forget(uint32 accountId);
    }

    // ---- RetailAHStats.cpp: the stats an item carries, for the Buy tab's stat filters ---------

    namespace GearStats
    {
        // Bit positions in the search's stat mask; the addon's STATS list uses the same order.
        enum class Stat : uint8
        {
            Strength, Agility, Stamina, Intellect, Spirit,
            AttackPower, SpellPower, Hit, Crit, Haste, Expertise, ArmorPen,
            Defense, Dodge, Parry, Block, Resilience,
            ManaRegen, SpellPen, Sockets,
            None = 0xFF,
        };

        // From the template alone: stat slots, heirloom scaling, on-equip spells, sockets.
        uint32 TemplateMask(ItemTemplate const* proto);
        // The template plus the random enchantments ("of the Monkey") rolled on this copy.
        uint32 ItemMask(ItemTemplate const* proto, Item const* item);
    }

    // ---- RetailAHItemInfo.cpp: item names and levels for the addon's own cache ---------------

    namespace ItemInfo
    {
        // A hash of every item template, worked out on first use after startup or a reload.
        uint32 Stamp();
        void ResetStamp();
        void HandleInfo(Context& ctx, std::vector<std::string_view> const& args);
    }

    // ---- RetailAHBot.cpp: mod-ah-bot-plus's buyer, read from its config ------------------------

    namespace AhBot
    {
        // Reads AuctionHouseBot.* from the bot's config, at every config load.
        void LoadConfig();
        // The vendor-sold items the buyer won't overpay for; world database, at startup.
        void LoadVendorItems();
        // The buyer bot is on (and has characters), and RetailAH.BotPrice allows showing it.
        bool BuyerEnabled();
        // One of AuctionHouseBot.GUIDs.
        bool IsBot(ObjectGuid::LowType guid);
        // The per-unit buyouts the buyer takes: at or below `always` on every look, at or below
        // `upTo` on its luckiest roll. False when it never buys this item.
        bool BuyRange(ItemTemplate const* proto, uint64& always, uint64& upTo);
        void HandleValue(Context& ctx, std::vector<std::string_view> const& args);
    }

    // ---- RetailAHLedger.cpp: every character's auction house gold, in and out ------------------

    namespace Ledger
    {
        void CheckTable();
        // From the AuctionHouseScript; all on the world thread.
        void OnSold(AuctionEntry const* auction);
        void OnBought(AuctionEntry const* auction);
        void OnExpired(AuctionEntry const* auction);
        void OnRemoved(AuctionEntry const* auction);
        // The auction leaves the house without being cancelled (BuyPart replaces it with the
        // rest of the stack), or was never in the house; nothing more to record for it.
        void Settle(uint32 auctionId);
        void Forget(uint32 auctionId);
        void HandleLedger(Context& ctx, std::vector<std::string_view> const& args);
    }

    // ---- RetailAHCraftPrices.cpp: prices for the profession window's profit view -------------

    namespace CraftPrices
    {
        // Vendor items and the recent sales out of the ledger; at startup, after the ledger.
        void Load();
        // From the auction won mail hook: every sale, whoever is on either side.
        void OnSold(AuctionEntry const* auction);
        // Needs no auctioneer: ctx has only the player and the request id.
        void HandlePrices(Context& ctx, std::vector<std::string_view> const& args);
    }
}

#endif
