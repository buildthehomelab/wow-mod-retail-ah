/*
 * mod-retail-ah: item names, quality and levels straight from the server's item templates.
 *
 * The 3.3.5a client only knows an item after asking the server about it, one query per item,
 * and keeps the answers in its Cache folder, which a patch change wipes. A search full of items
 * the client hasn't seen showed rows of "Loading..." for a long time. The addon asks this module
 * instead, up to 40 items per message, and keeps the answers in its saved variables, so the
 * next visit only waits for prices.
 *
 * HELLO carries a stamp of the item templates; when it changes (an item edited in the
 * database, a module changing stack sizes), the addon drops what it saved.
 */

#include "RetailAH.h"
#include "DBCStores.h"
#include "ItemTemplate.h"
#include "ObjectMgr.h"
#include "Player.h"
#include "WorldSession.h"

namespace RetailAH::ItemInfo
{
    namespace
    {
        constexpr std::size_t MAX_ITEMS = 40;

        uint32 sStamp = 0;

        uint64 Fnv(uint64 hash, uint64 value)
        {
            for (int i = 0; i < 8; ++i)
            {
                hash ^= (value >> (i * 8)) & 0xFF;
                hash *= 1099511628211ull;
            }
            return hash;
        }

        // The addon splits rows on ',' and ';' and saves names in a tab-separated string.
        std::string Escape(std::string const& text)
        {
            std::string out;
            out.reserve(text.size());
            for (char c : text)
            {
                switch (c)
                {
                    case '%': out += "%25"; break;
                    case ',': out += "%2C"; break;
                    case ';': out += "%3B"; break;
                    case '|': out += "%7C"; break;
                    case '\t': out += ' '; break;
                    default: out += c; break;
                }
            }
            return out;
        }

        // The item's name in the player's language, with a random suffix ("of the Monkey") when
        // the token asks for one.
        std::string Name(WorldSession* session, ItemTemplate const* proto, int32 randomProperty)
        {
            std::string name = proto->Name1;
            if (ItemLocale const* locale = sObjectMgr->GetItemLocale(proto->ItemId))
                ObjectMgr::GetLocaleString(locale->Name, session->GetSessionDbLocaleIndex(), name);

            char const* suffix = nullptr;
            LocaleConstant dbc = session->GetSessionDbcLocale();
            if (randomProperty > 0)
            {
                if (ItemRandomPropertiesEntry const* entry = sItemRandomPropertiesStore.LookupEntry(uint32(randomProperty)))
                    suffix = entry->Name[dbc];
            }
            else if (randomProperty < 0)
            {
                if (ItemRandomSuffixEntry const* entry = sItemRandomSuffixStore.LookupEntry(uint32(-randomProperty)))
                    suffix = entry->Name[dbc];
            }
            if (suffix && *suffix)
                name += std::string(" ") + suffix;
            return name;
        }
    }

    // Order-independent, so the template map's iteration order doesn't matter.
    uint32 Stamp()
    {
        if (sStamp)
            return sStamp;

        uint64 sum = 0;
        for (auto const& [entry, proto] : *sObjectMgr->GetItemTemplateStore())
        {
            uint64 h = 14695981039346656037ull;
            h = Fnv(h, entry);
            h = Fnv(h, proto.Quality);
            h = Fnv(h, proto.ItemLevel);
            h = Fnv(h, proto.RequiredLevel);
            h = Fnv(h, proto.Class);
            h = Fnv(h, proto.SubClass);
            h = Fnv(h, proto.InventoryType);
            h = Fnv(h, uint32(proto.GetMaxStackSize()));
            h = Fnv(h, proto.SellPrice);
            for (char c : proto.Name1)
                h = Fnv(h, uint8(c));
            sum += h;
        }
        sStamp = uint32(sum ^ (sum >> 32));
        if (!sStamp)
            sStamp = 1;
        return sStamp;
    }

    void ResetStamp()
    {
        sStamp = 0;
    }

    // N:<req>:<token>,<token>,...   A token is an entry, or <entry>/<random property id>.
    // Rows: <token>,<quality>,<item level>,<required level>,<class>,<subclass>,<inventory type>,
    // <max stack>,<vendor sell price>,<name with ',' ';' '%' '|' escaped as %XX>. Unknown items
    // get no row.
    void HandleInfo(Context& ctx, std::vector<std::string_view> const& args)
    {
        if (args.size() < 3)
        {
            SendError(ctx, "bad");
            return;
        }

        std::vector<std::string_view> tokens = Split(args[2], ',');
        if (tokens.size() > MAX_ITEMS)
            tokens.resize(MAX_ITEMS);

        std::vector<std::string> rows;
        for (std::string_view token : tokens)
        {
            std::vector<std::string_view> parts = Split(token, '/', 2);
            uint32 entry = 0;
            int32 randomProperty = 0;
            if (!ParseUInt(parts[0], entry) || (parts.size() > 1 && !ParseInt(parts[1], randomProperty)))
                continue;
            ItemTemplate const* proto = sObjectMgr->GetItemTemplate(entry);
            if (!proto)
                continue;

            rows.push_back(std::string(token) + "," + std::to_string(proto->Quality) + "," + std::to_string(proto->ItemLevel) + ","
                + std::to_string(proto->RequiredLevel) + "," + std::to_string(proto->Class) + "," + std::to_string(proto->SubClass) + ","
                + std::to_string(proto->InventoryType) + "," + std::to_string(proto->GetMaxStackSize()) + ","
                + std::to_string(proto->SellPrice) + "," + Escape(Name(ctx.player->GetSession(), proto, randomProperty)));
        }

        Send(ctx.player, "NR:" + ctx.req);
        SendRows(ctx.player, "ND:" + ctx.req, rows);
        Send(ctx.player, "NE:" + ctx.req);
    }
}
