# Retail Auction House

An [AzerothCore](https://www.azerothcore.org/) (WotLK 3.3.5a) module and addon that replace the
old auction window with the **retail** one: the Buy / Sell / Auctions window from modern WoW,
backed by a server module that makes the parts the 3.3.5a protocol can't express actually work.

Everyone shares the same auctions as before. Players on the old window, AH bots, playerbots and
other modules keep working, because every auction is still an ordinary AzerothCore auction.

## What players get

**Buy**
- Search box, a **category tree** (weapons by type, armor by material and slot, gems by color,
  glyphs by class, trade goods, recipes by profession, pets, mounts...) and **filters**:
  usable only, exact match, level range, and rarity checkboxes.
  **Item Enhancement** splits into Weapon Enchantments and Armor Enchantments by what each
  enchant scroll, armor kit or weapon chain goes on (the game files them all as one kind of
  item, so the server reads it from the enchant itself); vellums are under Trade Goods.
- **Stat filters**: tick Agility, Crit, Spell Power, Defense, Sockets and so on in the Filters
  dropdown to see only gear that has **all** of them. The server checks the item's own stats,
  heirloom scaling, "Equip:" bonuses (older items give hit, crit, attack power or spell damage
  that way) and the random enchantment on each copy, so "of the Monkey" items match Agility and
  Stamina.
- Results are **grouped by item**, like retail: one row per item with the lowest price, item
  level (**iLvl**), the level needed to use it (**Req**) and how many are available. Sort by any column. No pages. Gear with random enchantments
  gets a row per suffix ("Bandit Cinch of the Monkey", "... of the Bear"), so searching "monkey"
  finds only the Monkey ones, and opening a row lists only that suffix.
- Hold **Shift** while hovering an item to compare it with what you have equipped, as
  elsewhere in the game. `/rah compare` compares on every hover instead, and back.
- **Favorites**: right-click a result, or click the star on an item. The window opens on your
  favorites. Favorites are account-wide.
- **Shopping list** (with [mod-reagent-bank-account](https://github.com/buildthehomelab/mod-reagent-bank-account)'s
  ReagentBankUI): the note button beside the star lists what your recipes are short of, put
  there with **Add to Shopping List** in the profession window, each with what's left to buy,
  what you've bought, the cheapest price and how many are listed (red when the house can't cover
  it). Click one and the quantity is already what's left; every purchase counts it down, and an
  item you've finished drops off. Right-click changes an amount, Shift-right-click removes the
  item, **Clear List** empties it, and Ctrl+Shift-click on any search result adds that item.
  When there's something on the list, the window opens on it instead of your favorites.
- **Commodities** (anything that stacks): type a quantity and see the total, filled from the
  cheapest listings first. **Buy any quantity**: if you want 7 herbs and the cheapest stack has
  20, you buy 7 and the seller keeps the other 13 listed. Click a price row to ask for
  everything up to that price. After a purchase the quantity stays, so **Buy Now** again buys
  the same amount at the new cheapest prices (Shift-click skips the confirmation).
  **Bid on Stacks** switches to the separate stacks, to bid on one or buy a whole stack (bots and
  the old window list stacks with a starting bid).
- **Everything else**: every listing of the item with bid, buyout, item level (random suffixes
  included) and time left. Bid or buy out. The cheapest listing is picked for you, with its price
  beside **Buy Now**; after each purchase the next cheapest is picked, so you can keep buying
  (Shift-click skips the confirmation).
- The item view keeps a running **Purchased: N for X** total while you stay on the item.
- **Transmog** (with [mod-transmog-plus](https://github.com/buildthehomelab/wow-mod-transmog-plus)):
  gear whose look your account hasn't collected is tagged **new look** in the results and the
  item view, with "You haven't collected this appearance" in the tooltip, and the filters have
  **Uncollected appearances only**, like retail. A look counts as collected from any item that
  shares it, the same way transmog-plus counts it.
- Everything you buy arrives in your mailbox, as it always has.

**Sell**
- Right-click an item in your bags, drop it on the slot, or pick it from the list of your
  sellable items.
- **Commodities are posted as a quantity at a unit price.** The module gathers them from all your
  bags and lists them as full stacks, so you never split stacks by hand.
  An optional **bid per unit** lists the stacks with a starting bid too; left empty they are
  buyout only, as retail lists commodities.
- With [mod-reagent-bank-account](https://github.com/buildthehomelab/mod-reagent-bank-account),
  your **reagent bank** counts too: its contents show in the item list (a blue `+` on the count),
  and a post takes from your bags first and then the bank, like retail's reagent bank. The
  **Include reagent bank** checkbox above the item list turns that off, so the list and every
  post stick to what's in your bags; the choice is remembered for the account.
- Other items get a buyout and an optional starting bid, and you can post several identical
  ones at once.
- The price starts at the current lowest listing (click any listing to match it), the deposit
  is worked out by the server, and 12 / 24 / 48 hour durations.
- **AH bot price** (with [mod-ah-bot-plus](https://github.com/NathanHandley/mod-ah-bot-plus)'s
  buyer bot on): above the listings, **AH buyer pays: X** shows what the bot pays for the item,
  and the price box starts there: the most the bot pays every time it looks, so the post sells
  even when no player is around to buy it. Players can still buy it, and may pay more. If the
  bot sometimes pays more (its price has a random part), the line says how much. Click the line
  to put the bot's price back. Items vendors sell are left out; the bot only pays vendor price
  for them.

**Auctions**
- Your auctions, with bids and time left; cancel them.
- Auctions you hold the top bid on; raise the bid or buy them out.

**Ledger**
- Whether the auction house makes or loses you money. Every auction that ends for you is
  written down: **sold** (after the house cut), **bought**, **expired** (the deposit is lost) and
  **cancelled** (the deposit, and the cut if someone had bid). A deposit only counts when it's
  lost, since a sale returns it.
- **History** lists them newest first, with who was on the other side (**AH bot** or a player);
  **By Item** adds them up per item, best earners first, so you can see what's worth farming.
- Today, 7 days, 30 days or all time, for this character or **all characters** on the account,
  with sales, cut, lost deposits, purchases and the **net** along the bottom.

**Craft for profit** (with [mod-retail-professions](https://github.com/buildthehomelab/wow-mod-retail-professions))
- The RetailProfessions addon's profit view asks this module for prices from the profession
  window, wherever the player is: the lowest buyout and units listed (their own auctions left
  out), what the AH bot buyer pays, vendor prices of reagents vendors sell, and how much sold in
  the last 14 days. It ranks the recipes a player knows by profit, with what they can craft right
  now from their bags and reagent bank first. `RetailAH.CraftPrices = 0` turns it off.

**AH bot prices on item tooltips**
- Every item tooltip, anywhere in the world, shows what the AH bot buyer pays for it (per unit,
  plus the stack total in your bags), and for gear what it pays for the materials one disenchant
  gives on average. The better of the two is green, so you can tell whether to sell an item or
  disenchant it first. Without enough Enchanting the disenchant line is grey and shows the skill
  it needs. Bound items show no AH price. `/rah tooltip` turns the lines off;
  `RetailAH.Tooltip = 0` turns them off for everyone.

The window is built from stock Blizzard frames: the dialog frame with its header plate, tooltip-
bordered panes, the auction window's own category buttons and column headers, stock buttons,
checkboxes and scroll bars. With [DragonUI](https://github.com/NeticSoul/DragonUI) loaded it
wears DragonUI's retail skin instead. Drag it by the title bar; it stays
where you put it. `/rah classic` opens the old window, and with it Auctionator, for players who
want it.

## What players see

Two gates keep the auction house in step with the character looking at it. They apply to the
retail window, to the classic window's search, and to bids and buyouts from either window, so
an addon or a stale list can't reach a hidden auction.

- **Level**: items needing a level more than 2 (`RetailAH.LevelGate.Margin`) above the
  character's are hidden. Gear is judged by its required level. Items without one (trade goods,
  recipes, bags) are judged by their item level, so a level 15 character doesn't see Thorium
  Bars. Gear isn't judged by item level, because greens sit about five item levels above their
  required level: that rule would hide every on-level green. Once a character reaches their era's
  level cap (60 before TBC, 70 before WotLK), the level gate steps aside and the era decides
  alone. Otherwise a level 60 player would lose Nexus Crystals and raid recipes, whose item
  levels are past 62.
- **Era** (with [mod-individual-progression](https://github.com/ZhengPeiRu21/mod-individual-progression)):
  items the player's progression hasn't unlocked are hidden. A character who hasn't cleared
  Molten Core sees no Blackwing Lair, Zul'Gurub, AQ, Naxxramas, Outland or Northrend items.
  Clear MC and the BWL-era items show up on the next search.
- **The Sell tab still prices what you own** (bags, bank, reagent bank): opening an item you
  hold lists its auctions even if it's locked for you, so you can price a post. Owning one doesn't
  let you buy more: searches hide it and purchases and bids are refused until you unlock it.
- When a search hides matches, the result count says so (**37 items +5 locked**), and hovering
  it tells you when they unlock: "3 unlock as you level (next at 24), 2 unlock after Molten
  Core". A search where everything is locked says that instead of "No items found".
- The **stat filters** only offer stats your era's gear has: no Resilience, Expertise, Armor
  Penetration or Sockets before TBC. The level range shows the highest level you can see.

Nothing is taken off the auction house. Everyone shares the same auctions, and each player sees
the part their level and progression allow. A player further along can still buy an item a
fresh character put up. GMs with GM mode on, and accounts matching IP's
`ExcludedAccountsRegex` or `BotAccountsRegex`, see everything.

### Which era unlocks an item

The era gate uses mod-individual-progression's own states:

| State | Unlocked by | For example |
|------:|-------------|-------------|
| 0 | nothing | Linen Cloth, Arcanite Bar, Lava Core, Righteous Orb, Black Lotus |
| 1 | Molten Core cleared | Elementium Ore, BWL trash epics |
| 3 | Blackwing Lair cleared | Zul'Gurub drops (follows `IndividualProgression.RequiredZulGurubProgression`) |
| 4 | AQ gates open | AQ20 / AQ40 drops |
| 6 | AQ40 cleared | Naxxramas (40) drops |
| 8 | TBC | Netherweave Cloth, Fel Iron Ore, Arcane Dust, Hellfire greens, crafts above 300 skill |
| 9 / 10 / 12 | SSC & TK / Hyjal & BT / Sunwell | drops from those raids and Isle of Quel'Danas |
| 13 | WotLK | Titanium Ore, Borean Leather, level 71+ gear, crafts above 375 skill |
| 14–17 | Ulduar / ToC / ICC / Ruby Sanctum | drops from those raids |

`IndividualProgression.ProgressionLimit` caps this as it caps IP: items past the limit are
hidden from everyone.

The world DB has no "added in patch" field, so at startup the module works out each item's
state from **where it can be obtained**, and takes the easiest source:

1. **Loot and spawns.** Creature loot (plus pickpocketing and skinning), chests, gathering nodes
   and fishing. Each source gets the state of the map it's spawned on, using the gates IP puts on
   those maps (BWL = 1, AQ = 4, Outland = 8, Northrend = 13, Ulduar = 14, …). A level 64+
   creature standing in the old world counts as TBC, and a level 74+ one as WotLK. Vendors only
   count for items that nothing else gives (no drop, container, quest or craft). The Darkmoon
   Faire sells Northrend leather and gem pouches, and Shattrath sells flour.
2. **Derived sources, followed until they settle.** Container contents, disenchanting,
   prospecting and milling results, and items made by using another item (a full set of
   Darkmoon cards makes the deck). Quest rewards get the quest giver's state and the state of
   the items the quest asks for. Crafted items get the easiest place to learn the recipe
   (trainer, recipe item or quest), the state of their reagents, and a **skill tier**: a craft
   that needs more than 300 skill (vanilla's cap) is TBC, and more than 375 is WotLK. Enchant
   scrolls (an enchant cast on vellum) and random craft results count as crafts. Crafts learned
   by research or discovery only date items that nothing else gives.
3. **Expansion floors.** Required level 61+ counts as TBC and 71+ as WotLK. Gear, gems and ammo
   with an item level no vanilla (or TBC) item of that quality ever had are floored the same
   way, and every socket gem is TBC or later. Items needing more than 300 (375) profession
   skill, recipes included, are TBC (WotLK), and so are flying mounts. A container that holds
   only floored items gets the easiest of their floors.
4. **Overrides.** A row in `mod_retail_ah_item_era` (world DB, created at startup) replaces all
   of the above. Rows in mod-ah-progression's old `mod_ah_progression_item` are read too.

Professions are gated by tier, not by profession: jewelcrafting, inscription, prospecting and
milling work from the start, so low-level cut gems, inks and glyphs are visible to everyone.
When nothing is known about an item it stays **visible**.

```sql
-- always show it
REPLACE INTO mod_retail_ah_item_era (entry, state, comment) VALUES (12345, 0, 'why');
-- hide it until the AQ gates open
REPLACE INTO mod_retail_ah_item_era (entry, state, comment) VALUES (12345, 4, 'why');
```

Then `.rah reload` in game. `.rah item <id>` says what holds an item back, for example
`Elementium Ore (18562): ... Era: needs progression 1 (Molten Core cleared, BWL unlocked).
Easiest source: dropped by creature 13996.`

This replaces **mod-ah-progression**, which did the era gate for the classic window only. Remove
it from `modules/`; while its config is still loaded, RetailAH logs an error and leaves the
classic window's search to it.

## How it works

The addon replaces the Blizzard window when you talk to an auctioneer. It talks to the server
over addon whispers (prefix `RAH`), the way mod-transmog-plus does. If the server doesn't answer
(the module isn't installed, or `RetailAH.Enable = 0`), the addon opens the classic window
instead, so installing the addon early never locks anyone out of the auction house.

On the server:
- **Searches** walk the auction house once and group auctions by item. The addon shows a
  search it has already run this visit at once and swaps in the fresh answer when it arrives,
  drops searches that a newer one replaced before they went out, and asks for item names and
  icons for the whole result straight away. An auction is shown only if the gates above allow
  it and every other module's `OnPlayerCanPlaceAuctionBid` does too.
- **The classic window's search** is answered by the module for players with something to
  hide: it parses the stock request, filters with the same gates, and answers with the core's
  own sorting and paging, so there are no empty pages. Everyone else keeps the core's threaded
  search. This search runs on the world thread, and with the level gate on it covers almost every
  character below the level cap, so scanning addons such as Auctionator cost more than they did
  with the core's search.
- **Item names and levels** come from the server's item templates, up to 40 items per message,
  and the addon keeps them in its saved variables. The client's own item cache fills one slow
  query at a time and is wiped with every patch change, which used to leave a fresh search full
  of "Loading..." rows; now only the first sight of an item waits, and only briefly. The server
  sends a stamp of its item templates with HELLO, and the addon throws its copy away when the
  stamp changes (an item edited, stack sizes changed).
- **Buying a whole auction, bidding, cancelling and posting** are handed to the core's own
  auction handlers, as if the stock window had sent them. Deposits, the house cut, mails,
  achievements, GM logging and every other module's hooks behave exactly as before.
- **Transmog collections** are read from mod-transmog-plus's `mod_transmog_plus_appearances`
  table when the player opens the auction house (and at most once a minute after that), and
  what counts as an appearance follows transmog-plus's own rules and `Transmog.Allow*` options.
  The two modules don't link to each other; either builds without the other.
- **Posting from the reagent bank** is done by the module: the reagent bank stores amounts, not
  items, so there is nothing for the core's sell handler to take. The module finds the player's
  bank row the way mod-reagent-bank-account does (account-wide or per character, shared banks
  included), creates the auction and takes the units off the bank row in one transaction, and
  tells ReagentBankUI to refresh.
- **Buying part of a stack** is the other new trade. The seller's auction is replaced by one for the
  rest of the stack (same unit price, same expiry, the rest of the deposit), and the bought part
  is settled like a buyout: the seller gets the sale mails and the money minus the cut and plus
  that share of the deposit, and the buyer gets the items by mail. All of it, the split included,
  is one database transaction. A stack someone has bid on is never split.
- **The AH bot price** reads mod-ah-bot-plus's own `AuctionHouseBot.*` options and works out
  its price formula (`CalculateItemValue`) with the random roll at its low end (what the buyer
  pays every time) and at its high end (its best roll), times
  `AuctionHouseBot.Buyer.AcceptablePriceModifier`. The buyer buys out when the buyout is below
  what it's willing to pay, so the price shown is one copper under that. The two modules don't
  link to each other; the formula is mirrored from mod-ah-bot-plus as of July 2026 (f685832).
- **The ledger** comes from the core's auction mail hooks (sale, purchase, expiry), which every
  way of ending an auction goes through: the stock window, this module, the AH bot's buyer and
  the house's own expiry. A cancel is an auction that leaves the house without having sold or
  expired. Rows go to `mod_retail_ah_ledger` in the characters database, created at startup;
  AH bot characters get none.
- You can't buy from yourself or your other characters, as with the old window (including an
  alt that is logged in as a playerbot).
- One purchase takes from at most 100 listings; the window tells the player when that limits
  the quantity.
- Every request walks the auction house on the world thread, so each character gets a small
  request budget (12 at once, 6 per second), plus an optional search cooldown. The addon waits and
  retries when it runs out; a modified client can't flood the server.

## Requirements

- An AzerothCore WotLK server (`azerothcore-wotlk`, master). The module creates its own tables at
  startup, so no SQL has to be applied.
- The bundled **RetailAH** addon (`addon/RetailAH`) on each player's WoW 3.3.5a (12340) client.
  Without the module on the server, the addon falls back to the classic auction window.
- Optional, each switches on one part of the window:
  - [mod-individual-progression](https://github.com/ZhengPeiRu21/mod-individual-progression):
    the era gate.
  - [mod-transmog-plus](https://github.com/buildthehomelab/wow-mod-transmog-plus): uncollected
    appearance tags and filter.
  - [mod-reagent-bank-account](https://github.com/buildthehomelab/mod-reagent-bank-account):
    posting from the reagent bank.
  - [mod-ah-bot-plus](https://github.com/NathanHandley/mod-ah-bot-plus): AH bot prices.
  - [mod-retail-professions](https://github.com/buildthehomelab/wow-mod-retail-professions):
    craft-for-profit prices.
  - [DragonUI](https://github.com/NeticSoul/DragonUI): the window wears its skin.
- Remove **mod-ah-progression** if it is installed; this module replaces it.

## Install

### Server

```
cd azerothcore/modules
git clone https://github.com/buildthehomelab/wow-mod-retail-ah.git mod-retail-ah
```

The folder must be named `mod-retail-ah`: AzerothCore derives the loader name from it. Re-run
CMake and rebuild, copy `conf/mod_retail_ah.conf.dist` to `mod_retail_ah.conf` if you want to
change the defaults, and restart. There is no SQL to apply: the ledger and era override tables
are created at startup (`data/sql/` has the same statements for setups that want them).
Deriving the era table takes a few seconds at startup. Remove mod-ah-progression if it is
installed.

### Addon

The addon is in `addon/RetailAH`. Copy that folder into `Interface/AddOns` (the folder must be
called `RetailAH`), or hand it out with Portalkeeper: `sql/portalkeeper_addon.sql` adds it to
mod-realm-config as a **required** addon, so every player gets it. Run that file by hand against
`acore_world`.

## Configuration

| Option | Default | |
|---|---|---|
| `RetailAH.Enable` | 1 | 0 sends every player to the classic window. |
| `RetailAH.MaxResults` | 500 | Most item groups one search returns (cut off alphabetically). |
| `RetailAH.MaxDetailRows` | 300 | Most price tiers or listings shown for one item. |
| `RetailAH.SearchCooldownMs` | 0 | Extra gap between two searches from one player; 0 = off. |
| `RetailAH.ReagentBank` | 1 | Post commodities from mod-reagent-bank-account's reagent bank too. |
| `RetailAH.Transmog` | 1 | Mark and filter mod-transmog-plus appearances the account hasn't collected. |
| `RetailAH.BotPrice` | 1 | Show and suggest what mod-ah-bot-plus's buyer pays (needs `AuctionHouseBot.Buyer.Enabled`). |
| `RetailAH.Ledger` | 1 | Keep the gold ledger for the Ledger tab (restart to turn on). |
| `RetailAH.Ledger.KeepDays` | 180 | Ledger rows older than this are deleted at startup; 0 = keep. |
| `RetailAH.Ledger.MaxRows` | 300 | Most rows the Ledger tab gets at once; totals cover everything. |
| `RetailAH.EraGate` | 1 | Hide items the player's mod-individual-progression state hasn't unlocked. |
| `RetailAH.EraGate.DeriveFromSources` | 1 | Work out eras from loot, vendors, quests and crafts; 0 = floors and overrides only. |
| `RetailAH.EraGate.ExpansionFloors` | 1 | Level 61+/71+, past-era item levels and skill tiers count as TBC/WotLK. |
| `RetailAH.LevelGate` | 1 | Hide items needing a level well above the character's. |
| `RetailAH.LevelGate.Margin` | 2 | How far above the character's level an item may be and still show. |
| `RetailAH.LevelGate.ItemLevel` | 1 | Judge items without a required level (mats, recipes, bags) by item level. |
| `RetailAH.Gates.ClassicWindow` | 1 | Filter the classic window's search through the gates too. |
| `RetailAH.CraftPrices` | 1 | Answer the RetailProfessions profit view's price lookups anywhere. |
| `RetailAH.Tooltip` | 1 | AH bot prices (as is and disenchanted) on item tooltips, anywhere. |

The era gate also reads mod-individual-progression's `IndividualProgression.Enable`,
`.ProgressionLimit`, `.RequiredZulGurubProgression`, `.RequiredZulAmanProgression`,
`.ExcludedAccountsRegex` and `.BotAccountsRegex`, so there's nothing to keep in sync.

## Commands

- `/rah classic` switches to the old window (right away if you're at the auctioneer) and keeps
  it as the default; `/rah retail` switches back.
- `/rah reset` moves the window back to its default spot.
- `/rah compare` toggles comparing hovered items with your equipped gear without Shift (off by default).
- `/rah tooltip` toggles the AH bot prices on item tooltips (on by default).
- In the Buy tab, click the selected category again to clear it and search every category.

GM commands on the server:

- `.rah item <id or shift-click link>`: the item's level need and the era that unlocks it, with
  the source that decided it.
- `.rah player`: what the selected player (or you) can see, and how many items each gate hides.
- `.rah reload` (admin): re-read the gate options and rebuild the era table.

## Not included

- Retail's "upgrades" filter, the WoW Token and region-wide commodity markets have no 3.3.5a
  equivalent here.
- Commodity listings without a buyout (from the old window or a bot) show in search but can't
  be bought through the quantity box, since retail commodities are buyout only. They can still
  be bid on from the classic window.

## Development

- `tools/addon_smoke_test.lua` loads the addon against a stubbed 3.3.5a API and a fake server and
  clicks through the main flows: `lua tools/addon_smoke_test.lua addon/RetailAH`.
- The wire protocol is documented at the top of `src/RetailAHBrowse.cpp` and
  `src/RetailAHTrade.cpp`. Change `PROTOCOL_VERSION` (server) and `RAH.PROTOCOL` (addon)
  together when a message changes shape.

## Troubleshooting

- **Talking to an auctioneer opens the classic window.** The server didn't answer the addon:
  the module isn't built into the worldserver, or `RetailAH.Enable` is `0`. `/rah classic` also
  keeps the classic window as the default; `/rah retail` switches back.
- **An item or auction isn't showing up.** The level gate or the era gate is hiding it. Use
  `.rah item <id>` to see what holds an item back and `.rah player` to see what a player can
  see. To override the era, add a row to `mod_retail_ah_item_era` and run `.rah reload`.
- **The log says RetailAH is leaving the classic search to mod-ah-progression.** That module is
  still installed and its config is loaded. Remove it from `modules/`.
- **The addon doesn't load.** The folder must be called `RetailAH` inside `Interface/AddOns`.

## Credits

The AH bot price formula mirrors the one in
[mod-ah-bot-plus](https://github.com/NathanHandley/mod-ah-bot-plus) by NathanHandley.

Author: [buildthehomelab](https://github.com/buildthehomelab)

## License

MIT. See [LICENSE](LICENSE).
