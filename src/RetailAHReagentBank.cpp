/*
 * mod-retail-ah: posting straight from mod-reagent-bank-account's reagent bank.
 *
 * That module keeps reagents as rows (account or character, entry, amount), not as items, and
 * reads and writes its table directly on every request, with no cache. So this file does the
 * same: it finds the player's row the way the reagent bank does (account-wide or per character,
 * redirected to the owner of a shared bank) and takes units off it in the same transaction that
 * creates the auction. Without the module (no table, or ReagentBankAccount.Enable = 0) all of
 * this is off.
 *
 *   RB  reagent bank contents -> RR:<req>, RD rows <entry>,<amount>, RE
 */

#include "RetailAH.h"
#include "Chat.h"
#include "Config.h"
#include "DatabaseEnv.h"
#include "Log.h"
#include "Player.h"
#include "WorldSession.h"

namespace RetailAH::ReagentBank
{
    namespace
    {
        bool sTablePresent = false;

        struct Keys
        {
            uint32 account = 0;
            uint32 guid = 0;
        };

        // Mirrors ReagentBank::GetStorageKeys in mod-reagent-bank-account.
        Keys KeysFor(Player const* player)
        {
            bool const accountWide = sConfigMgr->GetOption<bool>("ReagentBankAccount.AccountWide", false, false);
            bool const sharing = sConfigMgr->GetOption<bool>("ReagentBankAccount.EnableSharing", false, false);

            uint32 key = accountWide ? player->GetSession()->GetAccountId() : uint32(player->GetGUID().GetCounter());
            if (sharing)
            {
                if (QueryResult result = CharacterDatabase.Query(
                    "SELECT owner_key FROM mod_reagent_bank_share_members WHERE member_key = {}", key))
                {
                    uint32 owner = (*result)[0].Get<uint32>();
                    if (owner && owner != key)
                        key = owner;
                }
            }

            Keys keys;
            if (accountWide)
                keys.account = key;
            else
                keys.guid = key;
            return keys;
        }
    }

    void CheckTable()
    {
        sTablePresent = false;
        if (QueryResult result = CharacterDatabase.Query("SHOW TABLES LIKE 'mod_reagent_bank_account'"))
            sTablePresent = true;
        if (sTablePresent && GetConfig().reagentBank)
            LOG_INFO("module", "mod-retail-ah: posting from mod-reagent-bank-account's reagent bank is on.");
    }

    bool Enabled()
    {
        return sTablePresent && GetConfig().reagentBank
            && sConfigMgr->GetOption<bool>("ReagentBankAccount.Enable", true, false);
    }

    uint32 Stored(Player const* player, uint32 entry)
    {
        if (!Enabled())
            return 0;

        Keys keys = KeysFor(player);
        QueryResult result = CharacterDatabase.Query(
            "SELECT amount FROM mod_reagent_bank_account WHERE account_id = {} AND guid = {} AND item_entry = {}",
            keys.account, keys.guid, entry);
        if (!result)
            return 0;
        int32 amount = (*result)[0].Get<int32>();
        return amount > 0 ? uint32(amount) : 0;
    }

    std::vector<std::pair<uint32, uint32>> Contents(Player const* player)
    {
        std::vector<std::pair<uint32, uint32>> contents;
        if (!Enabled())
            return contents;

        Keys keys = KeysFor(player);
        QueryResult result = CharacterDatabase.Query(
            "SELECT item_entry, amount FROM mod_reagent_bank_account WHERE account_id = {} AND guid = {} AND amount > 0",
            keys.account, keys.guid);
        if (!result)
            return contents;

        do
        {
            contents.emplace_back((*result)[0].Get<uint32>(), (*result)[1].Get<uint32>());
        } while (result->NextRow());
        return contents;
    }

    // Relative, so a write the reagent bank has queued in between still adds up.
    void Take(Player const* player, uint32 entry, uint32 count, CharacterDatabaseTransaction trans)
    {
        Keys keys = KeysFor(player);
        trans->Append("UPDATE mod_reagent_bank_account SET amount = amount - {} WHERE account_id = {} AND guid = {} AND item_entry = {}",
            count, keys.account, keys.guid, entry);
        trans->Append("DELETE FROM mod_reagent_bank_account WHERE account_id = {} AND guid = {} AND item_entry = {} AND amount <= 0",
            keys.account, keys.guid, entry);
    }

    // ReagentBankUI reloads its window on this line (and hides it from chat).
    void NotifyChanged(Player* player)
    {
        ChatHandler(player->GetSession()).SendSysMessage("RBANK:SHARE:REFRESH");
    }

    // RB:<req>
    void HandleContents(Context& ctx)
    {
        std::vector<std::string> rows;
        for (auto const& [entry, amount] : Contents(ctx.player))
            rows.push_back(std::to_string(entry) + "," + std::to_string(amount));

        Send(ctx.player, "RR:" + ctx.req);
        SendRows(ctx.player, "RD:" + ctx.req, rows);
        Send(ctx.player, "RE:" + ctx.req);
    }
}
