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
        sConfig.searchCooldownMs = sConfigMgr->GetOption<uint32>("RetailAH.SearchCooldownMs", 250);
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

            Send(player, "HELLO:" + req + ":" + std::to_string(PROTOCOL_VERSION) + ":"
                + std::to_string(ctx.houseEntry->cutPercent) + ":" + std::to_string(ctx.houseEntry->depositPercent));
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

        // Searches also sort and send hundreds of rows, so one per searchCooldownMs on top.
        bool SearchAllowed(SessionState& state)
        {
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

            if (!TakeToken(itr->second) || ((command == "S" || command == "F") && !SearchAllowed(itr->second)))
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
    }
};

class RetailAHAuctionScript : public AuctionHouseScript
{
public:
    RetailAHAuctionScript() : AuctionHouseScript("RetailAHAuctionScript", { AUCTIONHOUSEHOOK_ON_AUCTION_ADD }) { }

    void OnAuctionAdd(AuctionHouseObject* /*ah*/, AuctionEntry* entry) override
    {
        OnAuctionAdded(entry);
    }
};

class RetailAHWorldScript : public WorldScript
{
public:
    RetailAHWorldScript() : WorldScript("RetailAHWorldScript", { WORLDHOOK_ON_AFTER_CONFIG_LOAD }) { }

    void OnAfterConfigLoad(bool /*reload*/) override
    {
        LoadConfig();
    }
};

void AddRetailAHScripts()
{
    new RetailAHPlayerScript();
    new RetailAHAuctionScript();
    new RetailAHWorldScript();
}
