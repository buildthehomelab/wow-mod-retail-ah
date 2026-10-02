/*
 * mod-retail-ah: configuration, the addon transport, request dispatch and script registration.
 *
 * Wire format, both directions: "<COMMAND>:<request id>:<field>:<field>..." after the addon
 * prefix and a tab. Rows inside a field are separated by ';' and their values by ','.
 *
 * Addon messages arrive as CMSG_MESSAGECHAT, which the core handles on the world thread, the
 * same thread that owns the auction houses, so requests are answered straight from the hook.
 */

#include "RetailAH.h"
#include "AuctionHouseMgr.h"
#include "Chat.h"
#include "Config.h"
#include "Creature.h"
#include "Player.h"
#include "ScriptMgr.h"
#include "Timer.h"
#include "World.h"
#include "WorldPacket.h"
#include "WorldSession.h"
#include <algorithm>
#include <charconv>
#include <unordered_map>

namespace RetailAH
{
    namespace
    {
        Config sConfig;

        // Every request but HELLO walks the auction house on the world thread, and addon
        // whispers are never muted by the chat flood check, so each character gets a small
        // budget: REQUEST_BURST requests at once, refilled at REQUEST_RATE per second.
        constexpr float REQUEST_BURST = 12.0f;
        constexpr float REQUEST_RATE = 6.0f;

        struct SessionState
        {
            ObjectGuid auctioneer;
            uint32 lastSearch = 0;
            float tokens = REQUEST_BURST;
            uint32 lastRefill = 0;
        };

        // Keyed by character; filled on HELLO, dropped on logout.
        std::unordered_map<ObjectGuid::LowType, SessionState> sSessions;
    }

    Config& GetConfig()
    {
        return sConfig;
    }

    void LoadConfig()
    {
        sConfig.enabled = sConfigMgr->GetOption<bool>("RetailAH.Enable", true);
        sConfig.maxResults = std::max<uint32>(50, sConfigMgr->GetOption<uint32>("RetailAH.MaxResults", 500));
        sConfig.maxDetailRows = std::max<uint32>(50, sConfigMgr->GetOption<uint32>("RetailAH.MaxDetailRows", 300));
        sConfig.searchCooldownMs = sConfigMgr->GetOption<uint32>("RetailAH.SearchCooldownMs", 0);
        sConfig.reagentBank = sConfigMgr->GetOption<bool>("RetailAH.ReagentBank", true);
        sConfig.transmog = sConfigMgr->GetOption<bool>("RetailAH.Transmog", true);
        sConfig.botPrice = sConfigMgr->GetOption<bool>("RetailAH.BotPrice", true);
        sConfig.ledger = sConfigMgr->GetOption<bool>("RetailAH.Ledger", true);
        sConfig.ledgerKeepDays = sConfigMgr->GetOption<uint32>("RetailAH.Ledger.KeepDays", 180);
        sConfig.ledgerMaxRows = std::clamp<uint32>(sConfigMgr->GetOption<uint32>("RetailAH.Ledger.MaxRows", 300), 50, 2000);
        Appearances::LoadOptions();
        AhBot::LoadConfig();
    }

    void Send(Player* player, std::string const& payload)
    {
        if (!player || !player->GetSession())
            return;

        std::string full = std::string(PREFIX) + "\t" + payload;

        WorldPacket data;
        ChatHandler::BuildChatPacket(data, CHAT_MSG_WHISPER, LANG_ADDON, player, player, full);
        player->GetSession()->SendPacket(&data);
    }

    void SendRows(Player* player, std::string const& header, std::vector<std::string> const& rows)
    {
        std::string line;
        std::size_t const budget = MAX_PAYLOAD - header.size() - 1;
        for (std::string const& row : rows)
        {
            if (!line.empty() && line.size() + 1 + row.size() > budget)
            {
                Send(player, header + ":" + line);
                line.clear();
            }
            if (!line.empty())
                line += ';';
            line += row;
        }
        if (!line.empty())
            Send(player, header + ":" + line);
    }

    void SendError(Context const& ctx, std::string_view what)
    {
        Send(ctx.player, "ERR:" + ctx.req + ":" + std::string(what));
    }

    bool ParseUInt(std::string_view text, uint32& out)
    {
        if (text.empty())
            return false;
        auto result = std::from_chars(text.data(), text.data() + text.size(), out, 10);
        return result.ec == std::errc{} && result.ptr == text.data() + text.size();
    }

    bool ParseInt(std::string_view text, int32& out)
    {
        if (text.empty())
            return false;
        auto result = std::from_chars(text.data(), text.data() + text.size(), out, 10);
        return result.ec == std::errc{} && result.ptr == text.data() + text.size();
    }

    std::vector<std::string_view> Split(std::string_view text, char sep, std::size_t maxParts)
    {
        std::vector<std::string_view> parts;
        std::size_t start = 0;
        while (true)
        {
            if (maxParts && parts.size() + 1 == maxParts)
            {
                parts.push_back(text.substr(start));
                break;
            }
            std::size_t pos = text.find(sep, start);
            if (pos == std::string_view::npos)
            {
                parts.push_back(text.substr(start));
                break;
            }
            parts.push_back(text.substr(start, pos - start));
            start = pos + 1;
        }
        return parts;
    }

    namespace
    {
        // UnitGUID("npc") on the client: "0xF130001234005678".
        bool ParseGuid(std::string_view text, ObjectGuid& out)
        {
            if (text.size() > 2 && text[0] == '0' && (text[1] == 'x' || text[1] == 'X'))
                text.remove_prefix(2);
            uint64 raw = 0;
            auto result = std::from_chars(text.data(), text.data() + text.size(), raw, 16);
            if (result.ec != std::errc{} || result.ptr != text.data() + text.size() || !raw)
                return false;
            out = ObjectGuid(raw);
            return true;
        }

        // The same gate the stock window passes through before it can open.
        Creature* GetAuctioneer(Player* player, ObjectGuid guid)
        {
            if (!guid || player->GetLevel() < sWorld->getIntConfig(CONFIG_AUCTION_LEVEL_REQ))
                return nullptr;
            return player->GetNPCIfCanInteractWith(guid, UNIT_NPC_FLAG_AUCTIONEER);
        }

        bool FillContext(Player* player, Creature* auctioneer, Context& ctx)
        {
            ctx.player = player;
            ctx.auctioneer = auctioneer;
            ctx.houseEntry = AuctionHouseMgr::GetAuctionHouseEntryFromFactionTemplate(auctioneer->GetFaction());
            ctx.house = sAuctionMgr->GetAuctionsMap(auctioneer->GetFaction());
            return ctx.houseEntry && ctx.house;
        }

        void HandleHello(Player* player, std::string const& req, std::vector<std::string_view> const& args)
        {
            ObjectGuid guid;
            Creature* auctioneer = nullptr;
            if (args.size() >= 3 && ParseGuid(args[2], guid))
                auctioneer = GetAuctioneer(player, guid);

            Context ctx;
            ctx.req = req;
            if (!auctioneer || !FillContext(player, auctioneer, ctx))
            {
                ctx.player = player;
                SendError(ctx, "far");
                return;
            }

            // The same gate the stock window's hello passes through.
            if (!sScriptMgr->CanSendAuctionHello(player->GetSession(), guid, auctioneer))
            {
                SendError(ctx, "far");
                return;
            }

            if (player->HasUnitState(UNIT_STATE_DIED))
                player->RemoveAurasByType(SPELL_AURA_FEIGN_DEATH);

            sSessions[player->GetGUID().GetCounter()].auctioneer = guid;

            // A new visit reads the transmog collection fresh.
            Appearances::Forget(player->GetSession()->GetAccountId());

            uint32 flags = (ReagentBank::Enabled() ? HELLO_REAGENT_BANK : 0) | (Appearances::Enabled() ? HELLO_APPEARANCES : 0)
                | HELLO_STAT_FILTERS | (AhBot::BuyerEnabled() ? HELLO_BOT_PRICE : 0) | (sConfig.ledger ? HELLO_LEDGER : 0);
            Send(player, "HELLO:" + req + ":" + std::to_string(PROTOCOL_VERSION) + ":"
                + std::to_string(ctx.houseEntry->cutPercent) + ":" + std::to_string(ctx.houseEntry->depositPercent)
                + ":" + std::to_string(flags));
        }

        bool TakeToken(SessionState& state)
        {
            uint32 now = getMSTime();
            if (state.lastRefill)
                state.tokens = std::min(REQUEST_BURST, state.tokens + getMSTimeDiff(state.lastRefill, now) * REQUEST_RATE / 1000.0f);
            state.lastRefill = now;
            if (state.tokens < 1.0f)
                return false;
            state.tokens -= 1.0f;
            return true;
        }

        // Optional extra gap between searches, on top of the request budget. Requests are
        // handled once per world tick, so two searches sent 300 ms apart can be handled closer
        // together than that; off by default.
        bool SearchAllowed(SessionState& state)
        {
            if (!sConfig.searchCooldownMs)
                return true;
            uint32 now = getMSTime();
            if (state.lastSearch && getMSTimeDiff(state.lastSearch, now) < sConfig.searchCooldownMs)
                return false;
            state.lastSearch = now;
            return true;
        }

        void Dispatch(Player* player, std::string_view message)
        {
            std::vector<std::string_view> head = Split(message, ':', 3);
            if (head.size() < 2)
                return;

            std::string_view command = head[0];
            std::string req(head[1].substr(0, 12));

            // Search is the only request whose last field (the name) may itself hold ':'.
            std::vector<std::string_view> args = Split(message, ':', command == "S" ? 10 : 0);

            if (command == "HELLO")
            {
                HandleHello(player, req, args);
                return;
            }

            Context ctx;
            ctx.player = player;
            ctx.req = req;

            auto itr = sSessions.find(player->GetGUID().GetCounter());
            Creature* auctioneer = itr != sSessions.end() ? GetAuctioneer(player, itr->second.auctioneer) : nullptr;
            if (!auctioneer || !FillContext(player, auctioneer, ctx))
            {
                SendError(ctx, "far");
                return;
            }

            // Favorites come in chunks of one lookup, so only real searches count for the gap.
            if (!TakeToken(itr->second) || (command == "S" && !SearchAllowed(itr->second)))
            {
                SendError(ctx, "busy");
                return;
            }

            if (command == "S" || command == "F")
            {
                if (command == "S")
                    HandleSearch(ctx, args);
                else
                    HandleFavorites(ctx, args);
            }
            else if (command == "C")
                HandleCommodityDetails(ctx, args);
            else if (command == "I")
                HandleItemDetails(ctx, args);
            else if (command == "O")
                HandleOwned(ctx);
            else if (command == "BL")
                HandleBids(ctx);
            else if (command == "Q")
                HandleQuote(ctx, args);
            else if (command == "B")
                HandleCommodityBuy(ctx, args);
            else if (command == "P")
                HandlePlaceBid(ctx, args);
            else if (command == "X")
                HandleCancel(ctx, args);
            else if (command == "D")
                HandleDeposit(ctx, args);
            else if (command == "PC")
                HandlePostCommodity(ctx, args);
            else if (command == "PI")
                HandlePostItem(ctx, args);
            else if (command == "RB")
                ReagentBank::HandleContents(ctx);
            else if (command == "V")
                AhBot::HandleValue(ctx, args);
            else if (command == "G")
                Ledger::HandleLedger(ctx, args);
            else
                SendError(ctx, "unknown");
        }
    }
}

using namespace RetailAH;

class RetailAHPlayerScript : public PlayerScript
{
public:
    RetailAHPlayerScript() : PlayerScript("RetailAHPlayerScript",
        {
            PLAYERHOOK_CAN_PLAYER_USE_PRIVATE_CHAT,
            PLAYERHOOK_ON_LOGOUT
        }) { }

    // The addon whispers itself; swallow those messages so they never show up as chat.
    bool OnPlayerCanUseChat(Player* player, uint32 /*type*/, uint32 lang, std::string& msg, Player* receiver) override
    {
        if (lang != LANG_ADDON || !receiver || receiver != player)
            return true;

        std::string const prefixTab = std::string(PREFIX) + "\t";
        if (msg.compare(0, prefixTab.size(), prefixTab) != 0)
            return true;

        if (!GetConfig().enabled)
        {
            Send(player, "OFF:0");
            return false;
        }

        Dispatch(player, std::string_view(msg).substr(prefixTab.size()));
        return false;
    }

    void OnPlayerLogout(Player* player) override
    {
        sSessions.erase(player->GetGUID().GetCounter());
        Appearances::Forget(player->GetSession()->GetAccountId());
    }
};

class RetailAHAuctionScript : public AuctionHouseScript
{
public:
    RetailAHAuctionScript() : AuctionHouseScript("RetailAHAuctionScript",
        {
            AUCTIONHOUSEHOOK_ON_AUCTION_ADD,
            AUCTIONHOUSEHOOK_ON_AUCTION_REMOVE,
            AUCTIONHOUSEHOOK_ON_BEFORE_AUCTIONHOUSEMGR_SEND_AUCTION_WON_MAIL,
            AUCTIONHOUSEHOOK_ON_BEFORE_AUCTIONHOUSEMGR_SEND_AUCTION_SUCCESSFUL_MAIL,
            AUCTIONHOUSEHOOK_ON_BEFORE_AUCTIONHOUSEMGR_SEND_AUCTION_EXPIRED_MAIL
        }) { }

    void OnAuctionAdd(AuctionHouseObject* /*ah*/, AuctionEntry* entry) override
    {
        OnAuctionAdded(entry);
    }

    // The gold ledger. A sale's mails go out before the auction leaves the house, so by the
    // time it's removed the ledger knows it wasn't a cancel.
    void OnAuctionRemove(AuctionHouseObject* /*ah*/, AuctionEntry* entry) override
    {
        Ledger::OnRemoved(entry);
    }

    void OnBeforeAuctionHouseMgrSendAuctionWonMail(AuctionHouseMgr* /*mgr*/, AuctionEntry* auction, Player* /*bidder*/,
        uint32& /*bidderAccId*/, bool& /*sendNotification*/, bool& /*updateAchievementCriteria*/, bool& /*sendMail*/) override
    {
        Ledger::OnBought(auction);
    }

    void OnBeforeAuctionHouseMgrSendAuctionSuccessfulMail(AuctionHouseMgr* /*mgr*/, AuctionEntry* auction, Player* /*owner*/,
        uint32& /*ownerAccId*/, uint32& /*profit*/, bool& /*sendNotification*/, bool& /*updateAchievementCriteria*/, bool& /*sendMail*/) override
    {
        Ledger::OnSold(auction);
    }

    void OnBeforeAuctionHouseMgrSendAuctionExpiredMail(AuctionHouseMgr* /*mgr*/, AuctionEntry* auction, Player* /*owner*/,
        uint32& /*ownerAccId*/, bool& /*sendNotification*/, bool& /*sendMail*/) override
    {
        Ledger::OnExpired(auction);
    }
};

class RetailAHWorldScript : public WorldScript
{
public:
    RetailAHWorldScript() : WorldScript("RetailAHWorldScript", { WORLDHOOK_ON_AFTER_CONFIG_LOAD, WORLDHOOK_ON_STARTUP }) { }

    void OnAfterConfigLoad(bool /*reload*/) override
    {
        LoadConfig();
    }

    void OnStartup() override
    {
        ReagentBank::CheckTable();
        Appearances::CheckTable();
        AhBot::LoadVendorItems();
        Ledger::CheckTable();
    }
};

void AddRetailAHScripts()
{
    new RetailAHPlayerScript();
    new RetailAHAuctionScript();
    new RetailAHWorldScript();
}
