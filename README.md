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
- Results are **grouped by item**, like retail: one row per item with the lowest price, item
  level and how many are available. Sort by any column. No pages.
- **Favorites**: right-click a result, or click the star on an item. The window opens on your
  favorites. Favorites are account-wide.
- **Commodities** (anything that stacks): type a quantity and see the total, filled from the
  cheapest listings first. **Buy any quantity**: if you want 7 herbs and the cheapest stack has
  20, you buy 7 and the seller keeps the other 13 listed. Click a price row to ask for
  everything up to that price.
- **Everything else**: every listing of the item with bid, buyout, item level (random suffixes
  included) and time left. Bid or buy out. The cheapest listing is picked for you, with its price
  beside **Buy Now**; after each purchase the next cheapest is picked, so you can keep buying
  (Shift-click skips the confirmation).
- The item view keeps a running **Purchased: N for X** total while you stay on the item.
- Everything you buy arrives in your mailbox, as it always has.

**Sell**
- Right-click an item in your bags, drop it on the slot, or pick it from the list of your
  sellable items.
- **Commodities are posted as a quantity at a unit price.** The module gathers them from all your
  bags and lists them as full stacks, so you never split stacks by hand.
- With [mod-reagent-bank-account](https://github.com/buildthehomelab/mod-reagent-bank-account),
  your **reagent bank** counts too: its contents show in the item list (a blue `+` on the count),
  and a post takes from your bags first and then the bank, like retail's reagent bank.
- Other items get a buyout and an optional starting bid, and you can post several identical
  ones at once.
- The price starts at the current lowest listing (click any listing to match it), the deposit
  is worked out by the server, and 12 / 24 / 48 hour durations.

**Auctions**
- Your auctions, with bids and time left; cancel them.
- Auctions you hold the top bid on; raise the bid or buy them out.

The window uses [DragonUI](https://github.com/NeticSoul/DragonUI)'s retail art when DragonUI is
loaded, and a dark retail-style look of its own otherwise. Drag it by the title bar; it stays
where you put it. A **Classic** button (and
`/rah classic`) opens the old window, and with it Auctionator, for players who want it.

## How it works

The addon replaces the Blizzard window when you talk to an auctioneer. It talks to the server
over addon whispers (prefix `RAH`), the way mod-transmog-plus does. If the server doesn't answer
(the module isn't installed, or `RetailAH.Enable = 0`), the addon opens the classic window
instead, so installing the addon early never locks anyone out of the auction house.

On the server:
- **Searches** walk the auction house once and group auctions by item. Each player can search
  every 250 ms (configurable). Other modules' visibility rules are honoured: an auction is shown
  only if `OnPlayerCanPlaceAuctionBid` allows it, which is how
  mod-ah-progression hides items above a player's progression. That needs
  `AHProgression.BlockBids = 1` (its default); with 0, RetailAH shows everything.
- **Buying a whole auction, bidding, cancelling and posting** are handed to the core's own
  auction handlers, as if the stock window had sent them. Deposits, the house cut, mails,
  achievements, GM logging and every other module's hooks behave exactly as before.
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
- You can't buy from yourself or your other characters, as with the old window (including an
  alt that is logged in as a playerbot).
- One purchase takes from at most 100 listings; the window tells the player when that limits
  the quantity.
- Every request walks the auction house on the world thread, so each character gets a small
  request budget (12 at once, 6 per second) on top of the search cooldown. The addon waits and
  retries when it runs out; a modified client can't flood the server.

## Install

### Server

```
cd azerothcore/modules
git clone https://github.com/buildthehomelab/wow-mod-retail-ah.git mod-retail-ah
```

The folder must be named `mod-retail-ah`: AzerothCore derives the loader name from it. Re-run
CMake and rebuild, copy `conf/mod_retail_ah.conf.dist` to `mod_retail_ah.conf` if you want to
change the defaults, and restart. There is no SQL to apply.

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
| `RetailAH.SearchCooldownMs` | 250 | Shortest time between two searches from one player. |
| `RetailAH.ReagentBank` | 1 | Post commodities from mod-reagent-bank-account's reagent bank too. |

## Commands

- `/rah classic` makes the old window open at the auctioneer; `/rah retail` switches back.
- `/rah reset` moves the window back to its default spot.
- In the Buy tab, click the selected category again to clear it and search every category.

## Not included

- Retail's "uncollected appearances" and "upgrades" filters, the WoW Token and region-wide
  commodity markets have no 3.3.5a equivalent here.
- Commodity listings without a buyout (from the old window or a bot) show in search but can't
  be bought through the quantity box, since retail commodities are buyout only. They can still
  be bid on from the classic window.

## Development

- `tools/addon_smoke_test.lua` loads the addon against a stubbed 3.3.5a API and a fake server and
  clicks through the main flows: `lua tools/addon_smoke_test.lua addon/RetailAH`.
- The wire protocol is documented at the top of `src/RetailAHBrowse.cpp` and
  `src/RetailAHTrade.cpp`. Change `PROTOCOL_VERSION` (server) and `RAH.PROTOCOL` (addon)
  together when a message changes shape.

## License

MIT
