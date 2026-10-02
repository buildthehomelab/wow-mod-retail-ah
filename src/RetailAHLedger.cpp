/*
 * mod-retail-ah: the gold ledger. Every auction that ends for a player leaves a row in
 * `mod_retail_ah_ledger` (characters database), and the Ledger tab adds them up, so a player can
 * see whether the auction house makes or loses them money.
 *
 * The ledger counts profit, not cash flow: a deposit only counts when it's lost.
 *   sold       +bid - house cut           (the deposit comes back with the money)
 *   bought     -price paid
 *   expired    -deposit
 *   cancelled  -deposit, -house cut too when someone had bid
 *
 * Sales, purchases and expiries come from the core's auction mail hooks, which every way of
 * ending an auction goes through: the stock window, this module's trades, mod-ah-bot-plus's
 * buyer and the house's own expiry. A cancel has no mail hook of its own, so it is the removal
 * of an auction that neither sold nor expired. AH bot characters (AuctionHouseBot.GUIDs) get
 * no rows; they show up as the other side of a player's trade.
 */

#include "RetailAH.h"
#include "AuctionHouseMgr.h"
#include "CharacterCache.h"
#include "DatabaseEnv.h"
#include "GameTime.h"
#include "Log.h"
#include "Player.h"
#include "WorldSession.h"
#include <unordered_map>
#include <unordered_set>

namespace RetailAH::Ledger
{
    namespace
    {
        enum Kind : uint8
        {
            KIND_SOLD      = 1,
            KIND_BOUGHT    = 2,
            KIND_EXPIRED   = 3,
            KIND_CANCELLED = 4,
        };

        // Auctions whose end was recorded by a mail hook, so their removal isn't a cancel.
        std::unordered_set<uint32> sSettled;

        bool Recording()
        {
            return GetConfig().ledger;
        }

        // The owner's account, or 0 for an AH bot or a deleted character: no row for those.
        uint32 PlayerAccount(ObjectGuid guid)
        {
            if (!guid || AhBot::IsBot(guid.GetCounter()))
                return 0;
            return sCharacterCache->GetCharacterAccountIdByGuid(guid);
        }

        void Record(ObjectGuid who, uint32 account, Kind kind, AuctionEntry const* auction, uint32 gross, uint32 fee,
            int64 amount, ObjectGuid other)
        {
            CharacterDatabase.Execute("INSERT INTO mod_retail_ah_ledger (guid, account, time, kind, item, count, gross, fee, amount, other) "
                "VALUES ({}, {}, {}, {}, {}, {}, {}, {}, {}, {})",
                who.GetCounter(), account, uint32(GameTime::GetGameTime().count()), uint32(kind), auction->item_template,
                auction->itemCount, gross, fee, amount, other.GetCounter());
        }

        // A character's name for a row: "*" for an AH bot, "-" for nobody or a deleted
        // character. Never empty: the addon's row parser skips empty values.
        std::string NameOf(uint32 guid)
        {
            if (!guid)
                return "-";
            if (AhBot::IsBot(guid))
                return "*";
            std::string name;
            if (!sCharacterCache->GetCharacterNameByGuid(ObjectGuid::Create<HighGuid::Player>(guid), name) || name.empty())
                return "-";
            return name;
        }
    }

    void CheckTable()
    {
        if (!Recording())
            return;

        CharacterDatabase.DirectExecute(
            "CREATE TABLE IF NOT EXISTS `mod_retail_ah_ledger` ("
            "`id` INT UNSIGNED NOT NULL AUTO_INCREMENT,"
            "`guid` INT UNSIGNED NOT NULL,"
            "`account` INT UNSIGNED NOT NULL,"
            "`time` INT UNSIGNED NOT NULL,"
            "`kind` TINYINT UNSIGNED NOT NULL,"
            "`item` INT UNSIGNED NOT NULL,"
            "`count` INT UNSIGNED NOT NULL,"
            "`gross` INT UNSIGNED NOT NULL DEFAULT 0,"
            "`fee` INT UNSIGNED NOT NULL DEFAULT 0,"
            "`amount` BIGINT NOT NULL,"
            "`other` INT UNSIGNED NOT NULL DEFAULT 0,"
            "PRIMARY KEY (`id`),"
            "KEY `guid_time` (`guid`, `time`),"
            "KEY `account_time` (`account`, `time`)"
            ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4");

        if (uint32 days = GetConfig().ledgerKeepDays)
        {
            uint32 now = uint32(GameTime::GetGameTime().count());
            uint32 cutoff = now > days * DAY ? now - days * DAY : 0;
            CharacterDatabase.Execute("DELETE FROM mod_retail_ah_ledger WHERE time < {}", cutoff);
        }
    }

    void OnSold(AuctionEntry const* auction)
    {
        uint32 account = Recording() ? PlayerAccount(auction->owner) : 0;
        if (!account)
            return;
        sSettled.insert(auction->Id);
        uint32 cut = auction->GetAuctionCut();
        Record(auction->owner, account, KIND_SOLD, auction, auction->bid, cut, int64(auction->bid) - int64(cut), auction->bidder);
    }

    void OnBought(AuctionEntry const* auction)
    {
        uint32 account = Recording() ? PlayerAccount(auction->bidder) : 0;
        if (!account)
            return;
        Record(auction->bidder, account, KIND_BOUGHT, auction, auction->bid, 0, -int64(auction->bid), auction->owner);
    }

    void OnExpired(AuctionEntry const* auction)
    {
        uint32 account = Recording() ? PlayerAccount(auction->owner) : 0;
        if (!account)
            return;
        sSettled.insert(auction->Id);
        Record(auction->owner, account, KIND_EXPIRED, auction, 0, auction->deposit, -int64(auction->deposit), ObjectGuid::Empty);
    }

    void OnRemoved(AuctionEntry const* auction)
    {
        if (sSettled.erase(auction->Id))
            return;
        uint32 account = Recording() ? PlayerAccount(auction->owner) : 0;
        if (!account)
            return;
        // An expiry whose item went missing skips the expired mail, and so the hook, but the
        // house removes it all the same; the house expires auctions up to a minute early.
        if (!auction->bidder && auction->expire_time <= GameTime::GetGameTime().count() + MINUTE)
        {
            Record(auction->owner, account, KIND_EXPIRED, auction, 0, auction->deposit, -int64(auction->deposit), ObjectGuid::Empty);
            return;
        }
        // The cancel handler took the house cut from the owner when there was a bidder.
        uint32 fee = auction->deposit + (auction->bidder ? auction->GetAuctionCut() : 0);
        Record(auction->owner, account, KIND_CANCELLED, auction, 0, fee, -int64(fee), auction->bidder);
    }

    void Settle(uint32 auctionId)
    {
        sSettled.insert(auctionId);
    }

    void Forget(uint32 auctionId)
    {
        sSettled.erase(auctionId);
    }

    // G:<req>:<view>:<scope>:<days>
    //   view 0 = history, 1 = by item; scope 0 = this character, 1 = every character on the
    //   account; days 0 = all time.
    // Meta: <sales>:<house cut>:<lost deposits and cancel cuts>:<spent>:<net>:<sold>:<bought>:<expired or
    //   cancelled>:<truncated>, over the whole period, not just the rows sent.
    // History rows, newest first: <seconds ago>,<kind>,<entry>,<count>,<gross>,<fee>,<amount>,
    //   <other side>,<character>; "*" = AH bot, "-" = nobody.
    // By item rows, best first: <entry>,<sold units>,<sales net of cut>,<bought units>,<spent>,
    //   <lost deposits>,<net>,<seconds since last>
    void HandleLedger(Context& ctx, std::vector<std::string_view> const& args)
    {
        uint32 view = 0, scope = 0, days = 0;
        if (args.size() < 5 || !ParseUInt(args[2], view) || !ParseUInt(args[3], scope) || !ParseUInt(args[4], days)
            || view > 1 || scope > 1)
        {
            SendError(ctx, "bad");
            return;
        }
        if (!Recording())
        {
            SendError(ctx, "off");
            return;
        }

        uint32 const now = uint32(GameTime::GetGameTime().count());
        uint32 const since = days && now > days * DAY ? now - days * DAY : 0;
        std::string const who = scope
            ? "account = " + std::to_string(ctx.player->GetSession()->GetAccountId())
            : "guid = " + std::to_string(ctx.player->GetGUID().GetCounter());
        uint32 const limit = GetConfig().ledgerMaxRows;

        int64 sales = 0, cut = 0, lost = 0, spent = 0, net = 0;
        uint64 sold = 0, bought = 0, ended = 0;
        if (QueryResult totals = CharacterDatabase.Query("SELECT kind, CAST(SUM(gross) AS SIGNED), CAST(SUM(fee) AS SIGNED), "
            "CAST(SUM(amount) AS SIGNED), CAST(COUNT(*) AS SIGNED) FROM mod_retail_ah_ledger WHERE {} AND time >= {} GROUP BY kind", who, since))
        {
            do
            {
                Field* f = totals->Fetch();
                uint8 kind = f[0].Get<uint8>();
                int64 gross = f[1].Get<int64>(), fee = f[2].Get<int64>(), amount = f[3].Get<int64>(), rows = f[4].Get<int64>();
                net += amount;
                if (kind == KIND_SOLD)
                {
                    sales += gross;
                    cut += fee;
                    sold += rows;
                }
                else if (kind == KIND_BOUGHT)
                {
                    spent += gross;
                    bought += rows;
                }
                else
                {
                    lost += fee;
                    ended += rows;
                }
            } while (totals->NextRow());
        }

        std::vector<std::string> rows;
        bool truncated = false;
        if (view == 0)
        {
            truncated = sold + bought + ended > limit;
            if (QueryResult result = CharacterDatabase.Query("SELECT time, kind, item, count, gross, fee, amount, other, guid "
                "FROM mod_retail_ah_ledger WHERE {} AND time >= {} ORDER BY id DESC LIMIT {}", who, since, limit))
            {
                std::unordered_map<uint32, std::string> names;
                auto nameOf = [&names](uint32 guid) -> std::string const&
                {
                    auto itr = names.find(guid);
                    if (itr == names.end())
                        itr = names.emplace(guid, NameOf(guid)).first;
                    return itr->second;
                };
                do
                {
                    Field* f = result->Fetch();
                    uint32 time = f[0].Get<uint32>();
                    rows.push_back(std::to_string(now > time ? now - time : 0) + "," + std::to_string(f[1].Get<uint8>()) + ","
                        + std::to_string(f[2].Get<uint32>()) + "," + std::to_string(f[3].Get<uint32>()) + ","
                        + std::to_string(f[4].Get<uint32>()) + "," + std::to_string(f[5].Get<uint32>()) + ","
                        + std::to_string(f[6].Get<int64>()) + "," + nameOf(f[7].Get<uint32>()) + ","
                        + nameOf(f[8].Get<uint32>()));
                } while (result->NextRow());
            }
        }
        else if (QueryResult result = CharacterDatabase.Query("SELECT item, "
            "CAST(SUM(IF(kind = 1, count, 0)) AS SIGNED), CAST(SUM(IF(kind = 1, amount, 0)) AS SIGNED), "
            "CAST(SUM(IF(kind = 2, count, 0)) AS SIGNED), CAST(SUM(IF(kind = 2, -amount, 0)) AS SIGNED), "
            "CAST(SUM(IF(kind >= 3, fee, 0)) AS SIGNED), CAST(SUM(amount) AS SIGNED), MAX(time), CAST(COUNT(*) OVER () AS SIGNED) "
            "FROM mod_retail_ah_ledger WHERE {} AND time >= {} GROUP BY item ORDER BY SUM(amount) DESC LIMIT {}", who, since, limit))
        {
            do
            {
                Field* f = result->Fetch();
                uint32 last = f[7].Get<uint32>();
                truncated = uint64(f[8].Get<int64>()) > limit;
                rows.push_back(std::to_string(f[0].Get<uint32>()) + "," + std::to_string(f[1].Get<int64>()) + ","
                    + std::to_string(f[2].Get<int64>()) + "," + std::to_string(f[3].Get<int64>()) + ","
                    + std::to_string(f[4].Get<int64>()) + "," + std::to_string(f[5].Get<int64>()) + ","
                    + std::to_string(f[6].Get<int64>()) + "," + std::to_string(now > last ? now - last : 0));
            } while (result->NextRow());
        }

        Send(ctx.player, "GR:" + ctx.req + ":" + std::to_string(sales) + ":" + std::to_string(cut) + ":" + std::to_string(lost)
            + ":" + std::to_string(spent) + ":" + std::to_string(net) + ":" + std::to_string(sold) + ":" + std::to_string(bought)
            + ":" + std::to_string(ended) + ":" + (truncated ? "1" : "0"));
        SendRows(ctx.player, "GD:" + ctx.req, rows);
        Send(ctx.player, "GE:" + ctx.req);
    }
}
