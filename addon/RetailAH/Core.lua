-- RetailAH core: saved settings, the server protocol, item info, formatting and the hand-over
-- from the Blizzard auction window.

RetailAH = RetailAH or {}
local RAH = RetailAH

RAH.PREFIX = "RAH"
RAH.PROTOCOL = 1

-- Flags the server puts on result rows (see src/RetailAHBrowse.cpp).
RAH.GROUP_COMMODITY = 1
RAH.GROUP_BID_ONLY = 2
RAH.GROUP_OWN = 4
RAH.GROUP_UNCOLLECTED = 8  -- a mod-transmog-plus appearance the account hasn't collected
RAH.GROUP_SUFFIX = 16      -- one suffix of a random-enchant item ("of the Monkey")
RAH.AUCTION_OWN = 1
RAH.AUCTION_HIGH_BIDDER = 2
RAH.AUCTION_HAS_BID = 4

local floor = math.floor

-----------------------------------------
-- tiny event bus, so tabs can react to each other without knowing about each other

local listeners = {}

function RAH.On(event, fn)
	listeners[event] = listeners[event] or {}
	table.insert(listeners[event], fn)
end

function RAH.Fire(event, ...)
	local list = listeners[event]
	if not list then return end
	for i = 1, #list do list[i](...) end
end

-----------------------------------------
-- timers (3.3.5a has no C_Timer)

local timerFrame = CreateFrame("Frame")
local timers = {}

function RAH.After(delay, fn)
	table.insert(timers, { at = GetTime() + delay, fn = fn })
	timerFrame:Show()
end

-- Runs fn once, `delay` seconds after the last call with the same key.
local debounced = {}
function RAH.Debounce(key, delay, fn)
	debounced[key] = { at = GetTime() + delay, fn = fn }
	timerFrame:Show()
end

timerFrame:SetScript("OnUpdate", function (self)
	local now = GetTime()
	local i = 1
	while i <= #timers do
		if timers[i].at <= now then
			local t = table.remove(timers, i)
			t.fn()
		else
			i = i + 1
		end
	end
	for key, entry in pairs(debounced) do
		if entry.at <= now then
			debounced[key] = nil
			entry.fn()
		end
	end
	if #timers == 0 and not next(debounced) then self:Hide() end
end)

-----------------------------------------
-- formatting

local GOLD = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t"
local SILVER = "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:2:0|t"
local COPPER = "|TInterface\\MoneyFrame\\UI-CopperIcon:12:12:2:0|t"

local function thousands(n)
	local s = tostring(n)
	local sep
	repeat
		s, sep = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
	until sep == 0
	return s
end

-- 12,345g 06s 07c, with coin icons, the way retail prints prices. Zero silver or copper is
-- left out unless something smaller follows it.
function RAH.Money(copper)
	copper = floor(tonumber(copper) or 0)
	local g, s, c = floor(copper / 10000), floor(copper / 100) % 100, copper % 100
	local parts = {}
	if g > 0 then table.insert(parts, thousands(g) .. GOLD) end
	if s > 0 or (g > 0 and c > 0) then
		table.insert(parts, (g > 0 and string.format("%02d", s) or tostring(s)) .. SILVER)
	end
	if c > 0 or #parts == 0 then
		table.insert(parts, ((g > 0 or s > 0) and string.format("%02d", c) or tostring(c)) .. COPPER)
	end
	return table.concat(parts, " ")
end

function RAH.Number(n)
	return thousands(floor(tonumber(n) or 0))
end

function RAH.TimeLeft(seconds)
	seconds = tonumber(seconds) or 0
	if seconds <= 0 then return "|cff808080--|r" end
	local h = floor(seconds / 3600)
	if h >= 24 then
		return string.format("%dd %dh", floor(h / 24), h % 24)
	elseif h >= 1 then
		return string.format("%dh %dm", h, floor(seconds / 60) % 60)
	end
	local m = floor(seconds / 60)
	if m >= 1 then
		return "|cffff8000" .. m .. "m|r"
	end
	return "|cffff2020< 1m|r"
end

function RAH.Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff4fc3f7Auction House:|r " .. msg)
end

-----------------------------------------
-- item info: GetItemInfo only answers for cached items, so ask the server and poll

local waiting = {}
local waitingCount = 0
local scanTip = CreateFrame("GameTooltip", "RetailAHScanTooltip", nil, "GameTooltipTemplate")
scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")

local function itemString(item)
	if type(item) == "number" then return "item:" .. item end
	return item
end

-- What the server told us about items (see src/RetailAHItemInfo.cpp), kept in RetailAHDB.items
-- across sessions: "<quality>\t<item level>\t<required level>\t<class>\t<subclass>\t
-- <inventory type>\t<max stack>\t<sell price>\t<name>", keyed by entry or "<entry>/<suffix>".
-- The client's own item cache lives in its Cache folder, which a patch change wipes, and fills
-- one slow query at a time; this one fills 40 items a message and survives.
local parsed = {}     -- key -> info table built from RetailAHDB.items
local queued = {}     -- key -> item, waiting for the next item-info request
local asked = {}      -- key -> true once sent this session (answered or handed to the client)
local MAX_TOKENS_LEN = 200

-- "item:15210:0:0:0:0:0:-7:55" -> "15210/-7", entry, suffix id, suffix factor.
local function itemKey(item)
	local body = type(item) == "number" and tostring(item) or (type(item) == "string" and item:match("item:([%-%d:]+)"))
	if not body then return nil end
	local parts = {}
	for v in (body .. ":"):gmatch("([^:]*):") do table.insert(parts, tonumber(v) or 0) end
	local entry, rp, sf = parts[1], parts[7] or 0, parts[8] or 0
	if not entry or entry == 0 then return nil end
	return rp ~= 0 and (entry .. "/" .. rp) or tostring(entry), entry, rp, sf
end

local function savedInfo(key, entry, rp, sf)
	local info = parsed[key]
	if info then return info end
	local line = RetailAHDB and RetailAHDB.items and RetailAHDB.items[key]
	if not line then return nil end
	local q, ilvl, req, cls, sub, inv, stack, sell, name = strsplit("\t", line)
	if not name then return nil end
	local _, _, _, hex = RAH.QualityColor(tonumber(q))
	info = {
		name = name, quality = tonumber(q) or 1, itemLevel = tonumber(ilvl) or 0, reqLevel = tonumber(req) or 0,
		classId = tonumber(cls), subclassId = tonumber(sub), inventoryType = tonumber(inv),
		maxStack = tonumber(stack) or 1, sellPrice = tonumber(sell) or 0,
		texture = GetItemIcon and GetItemIcon(entry) or nil,
		link = hex .. "|Hitem:" .. entry .. ":0:0:0:0:0:" .. rp .. ":" .. sf .. ":" .. (UnitLevel and UnitLevel("player") or 80)
			.. "|h[" .. name .. "]|h|r",
	}
	parsed[key] = info
	return info
end

-- Hands an item to the client's own query, for servers without item info or items it didn't
-- know.
local function askClient(item)
	local key = itemString(item)
	if not waiting[key] then
		waiting[key] = GetTime()
		waitingCount = waitingCount + 1
		scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
		scanTip:SetHyperlink(key)
	end
end

local function unescape(text)
	return (text:gsub("%%(%x%x)", function (h) return string.char(tonumber(h, 16)) end))
end

local function flushItemInfo()
	if not (RAH.itemInfo and RAH.serverReady) then
		for key, item in pairs(queued) do askClient(item) end
		queued = {}
		return
	end
	local batch, items, len = {}, {}, 0
	local function send()
		if #batch == 0 then return end
		local mine, myItems = batch, items
		RAH.Request("N", { table.concat(mine, ",") }, function (result)
			local got = {}
			if result then
				for _, r in ipairs(result.rows) do
					-- The name is last and may hold spaces, but never an unescaped ',' or ';'.
					local key = tostring(r[1])
					if r[10] then
						RetailAHDB.items[key] = table.concat({ r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9],
							unescape(tostring(r[10])) }, "\t")
						parsed[key] = nil
						got[key] = true
					end
				end
			end
			for i, key in ipairs(mine) do
				if not got[key] then askClient(myItems[i]) end
			end
			RAH.Fire("ITEM_INFO")
		end)
		batch, items, len = {}, {}, 0
	end
	for key, item in pairs(queued) do
		if #batch >= 40 or len + #key + 1 > MAX_TOKENS_LEN then send() end
		table.insert(batch, key)
		table.insert(items, item)
		len = len + #key + 1
	end
	send()
	queued = {}
end

-- A new item template stamp from the server: what we saved may be out of date.
function RAH.SetItemStamp(stamp)
	local key = tostring(stamp) .. ":" .. (GetLocale and GetLocale() or "")
	if RetailAHDB.itemsStamp ~= key then
		RetailAHDB.items = {}
		RetailAHDB.itemsStamp = key
		parsed = {}
		asked = {}
	end
end

-- { name, link, quality, itemLevel, reqLevel, maxStack, texture, sellPrice, and class, subclass,
--   equipLoc from the client or classId, subclassId, inventoryType from the server } or nil
-- while nobody has answered yet.
function RAH.Item(item)
	if not item then return nil end
	local name, link, quality, itemLevel, reqLevel, class, subclass, maxStack, equipLoc, texture, sellPrice = GetItemInfo(item)
	if name then
		return {
			name = name, link = link, quality = quality or 1, itemLevel = itemLevel or 0,
			reqLevel = reqLevel or 0, class = class, subclass = subclass, maxStack = maxStack or 1,
			equipLoc = equipLoc, texture = texture, sellPrice = sellPrice or 0,
		}
	end

	local key, entry, rp, sf = itemKey(item)
	if not key then
		askClient(item)
		return nil
	end
	local info = savedInfo(key, entry, rp, sf)
	if info then return info end
	if not asked[key] then
		asked[key] = true
		queued[key] = item
		RAH.Debounce("iteminfo", 0.02, flushItemInfo)
	end
	return nil
end

-- A link for an auction row, including the random suffix the server told us about.
function RAH.ItemString(entry, randomProperty, suffixFactor)
	randomProperty = tonumber(randomProperty) or 0
	if randomProperty == 0 then return "item:" .. entry end
	return string.format("item:%d:0:0:0:0:0:%d:%d", entry, randomProperty, tonumber(suffixFactor) or 0)
end

-- The icon comes from the client's own Item.dbc, so it shows before the server has answered.
function RAH.ItemIcon(entry)
	local info = RAH.Item(entry)
	if info then return info.texture end
	return GetItemIcon and GetItemIcon(tonumber(entry) or entry) or nil
end

-- Asks the server about every item in a result at once, a few dozen per frame so a big
-- result doesn't stall one frame, instead of only as rows scroll into view.
local prefetch = {}
local prefetchFrame = CreateFrame("Frame")
prefetchFrame:Hide()
prefetchFrame:SetScript("OnUpdate", function (self)
	for _ = 1, 40 do
		local item = table.remove(prefetch)
		if not item then self:Hide() return end
		RAH.Item(item)
	end
end)

function RAH.Prefetch(items)
	prefetch = {}
	for i = #items, 1, -1 do table.insert(prefetch, items[i]) end
	prefetchFrame:Show()
end

-- No event tells a 3.3.5a addon that item info arrived, so poll, but often: the answer
-- usually comes back within a frame or two.
local pollFrame = CreateFrame("Frame")
local pollElapsed = 0
pollFrame:SetScript("OnUpdate", function (self, elapsed)
	if waitingCount == 0 then return end
	pollElapsed = pollElapsed + elapsed
	if pollElapsed < 0.03 then return end
	pollElapsed = 0

	local now, arrived = GetTime(), false
	for key, since in pairs(waiting) do
		if GetItemInfo(key) then
			waiting[key] = nil
			waitingCount = waitingCount - 1
			arrived = true
		elseif now - since > 20 then
			-- Give up; asking again later is harmless.
			waiting[key] = nil
			waitingCount = waitingCount - 1
		end
	end
	if arrived then RAH.Fire("ITEM_INFO") end
end)

-- An item's tooltip. Holding Shift puts what you have equipped in that slot beside it, as
-- elsewhere in the game; /rah compare shows that on every hover instead.
local tipOwner

local function wantCompare()
	return RetailAHDB.alwaysCompare or IsModifiedClick("COMPAREITEMS")
end

local function hideCompare()
	ShoppingTooltip1:Hide()
	ShoppingTooltip2:Hide()
	if ShoppingTooltip3 then ShoppingTooltip3:Hide() end
end

function RAH.ItemTooltip(owner, link, extra)
	tipOwner = owner
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	GameTooltip:SetHyperlink(link)
	if extra then extra(GameTooltip) end
	GameTooltip:Show()
	if wantCompare() then GameTooltip_ShowCompareItem() end
end

function RAH.HideItemTooltip()
	tipOwner = nil
	GameTooltip:Hide()
	hideCompare()
end

-- Pressing or letting go of Shift while hovering shows or hides the comparison right away.
local modifierFrame = CreateFrame("Frame")
modifierFrame:RegisterEvent("MODIFIER_STATE_CHANGED")
modifierFrame:SetScript("OnEvent", function ()
	if not tipOwner or not GameTooltip:IsShown() or not GameTooltip:IsOwned(tipOwner) then return end
	if wantCompare() then GameTooltip_ShowCompareItem() else hideCompare() end
end)

function RAH.QualityColor(quality)
	local c = ITEM_QUALITY_COLORS[quality or 1] or ITEM_QUALITY_COLORS[1]
	return c.r, c.g, c.b, c.hex
end

-----------------------------------------
-- favorites (account wide, like retail)

function RAH.IsFavorite(entry)
	return RetailAHDB and RetailAHDB.favorites[entry] and true or false
end

function RAH.SetFavorite(entry, on)
	RetailAHDB.favorites[entry] = on and true or nil
	RAH.Fire("FAVORITES")
end

function RAH.Favorites()
	local list = {}
	for entry in pairs(RetailAHDB.favorites) do table.insert(list, entry) end
	table.sort(list)
	return list
end

-----------------------------------------
-- server protocol

local nextReq = 0
local pending = {}

-- Requests that walk the whole auction house. They go out at once, but only HEAVY_IN_FLIGHT
-- wait for an answer at a time; the rest queue, and a new search drops the queued ones.
local HEAVY = { S = true, F = true }
local HEAVY_IN_FLIGHT = 4
local HEAVY_TIMEOUT = 5
local heavyQueue = {}
local inFlight = {}  -- req -> time sent
local inFlightCount = 0

local LISTS = { S = true, C = true, I = true, O = true, L = true, R = true, G = true, N = true, T = true }

local function send(msg)
	SendAddonMessage(RAH.PREFIX, msg, "WHISPER", UnitName("player"))
end

local function sendHeavy(p)
	inFlight[p.req] = GetTime()
	inFlightCount = inFlightCount + 1
	send(p.msg)
end

local function drainHeavy()
	while #heavyQueue > 0 and inFlightCount < HEAVY_IN_FLIGHT do
		sendHeavy(table.remove(heavyQueue, 1))
	end
end

local function landHeavy(req)
	if inFlight[req] then
		inFlight[req] = nil
		inFlightCount = inFlightCount - 1
		drainHeavy()
	end
end

-- A lost answer mustn't hold its slot forever.
local heavyFrame = CreateFrame("Frame")
heavyFrame:SetScript("OnUpdate", function (self)
	if inFlightCount == 0 then return end
	local now, expired = GetTime(), {}
	for req, sent in pairs(inFlight) do
		if now - sent > HEAVY_TIMEOUT then table.insert(expired, req) end
	end
	-- Landing sends queued requests, which adds to inFlight; not while iterating it.
	for _, req in ipairs(expired) do landHeavy(req) end
end)

-- handler(result, err): result is { rows = {...}, meta = {...} } for list answers and the
-- array of fields for single ones; err is set when the server refused ("far", "busy", "bad").
local function dispatch(p)
	if p.heavy then
		table.insert(heavyQueue, p)
		drainHeavy()
	else
		send(p.msg)
	end
end

-- Forgets searches that haven't gone out yet; a newer one replaces them.
function RAH.CancelQueuedSearches()
	for _, p in ipairs(heavyQueue) do pending[p.req] = nil end
	heavyQueue = {}
end

local function resetHeavy()
	RAH.CancelQueuedSearches()
	inFlight = {}
	inFlightCount = 0
end

function RAH.Request(cmd, fields, handler)
	nextReq = nextReq + 1
	local req = tostring(nextReq)

	local msg = cmd .. ":" .. req
	if fields and #fields > 0 then
		msg = msg .. ":" .. table.concat(fields, ":")
	end

	local p = { req = req, handler = handler, rows = {}, msg = msg, heavy = HEAVY[cmd], tries = 0 }
	pending[req] = p
	dispatch(p)
	return req
end

local function splitFields(text)
	local out = {}
	if text == nil or text == "" then return out end
	for field in (text .. ":"):gmatch("([^:]*):") do table.insert(out, field) end
	return out
end

local function parseRows(text, into)
	for row in text:gmatch("[^;]+") do
		local values = {}
		for value in row:gmatch("[^,]+") do table.insert(values, tonumber(value) or value) end
		table.insert(into, values)
	end
end

local function finish(req, result, err)
	landHeavy(req)
	local p = pending[req]
	if not p then return end
	pending[req] = nil
	if p.handler then p.handler(result, err) end
end

local function onAddonMessage(message)
	local code, req, rest = message:match("^([^:]+):([^:]*):?(.*)$")
	if not code then return end

	if code == "HELLO" then
		RAH.OnHello(splitFields(rest))
		finish(req, splitFields(rest))
		return
	elseif code == "OFF" then
		RAH.OnServerOff()
		return
	elseif code == "ERR" then
		-- The server rations requests per character; ask again shortly, same request id.
		local p = pending[req]
		if rest == "busy" and p and p.tries < 5 then
			p.tries = p.tries + 1
			landHeavy(req)
			RAH.After(0.15 * p.tries, function () if pending[req] == p then dispatch(p) end end)
			return
		end
		finish(req, nil, rest)
		return
	end

	local kind, part = code:sub(1, 1), code:sub(2)
	if #code == 2 and LISTS[kind] and (part == "R" or part == "D" or part == "E") then
		local p = pending[req]
		if not p then return end
		if part == "R" then
			p.meta = splitFields(rest)
		elseif part == "D" then
			parseRows(rest, p.rows)
		else
			finish(req, { rows = p.rows, meta = p.meta or {} })
		end
		return
	end

	finish(req, splitFields(rest))
end

-----------------------------------------
-- keeping chat quiet while we post a batch: the core confirms every auction separately

local quietUntil = 0
local seenQuiet = {}

function RAH.QuietChat(seconds)
	quietUntil = GetTime() + (seconds or 3)
	seenQuiet = {}
end

local QUIET = {}
local function quietFilter(self, event, msg)
	if GetTime() > quietUntil or not QUIET[msg] then return false end
	if seenQuiet[msg] then return true end
	seenQuiet[msg] = true
	return false
end

-----------------------------------------
-- the shopping list: ReagentBankUI keeps it (what recipes are short of, put there from the
-- profession window), the Buy tab lists it and reports what gets bought

local Shopping = {}
RAH.Shopping = Shopping

local function shoppingBank()
	local RB = _G.ReagentBankUI
	if RB and RB.GetShoppingListMap and RB.RecordShoppingPurchase then return RB end
end

function Shopping.Available()
	return shoppingBank() ~= nil
end

-- { { entry, need = units left to buy, bought = units bought so far } }
function Shopping.Items()
	local RB = shoppingBank()
	local items = {}
	if not RB then return items end
	local bought = RB.GetShoppingBoughtMap and RB:GetShoppingBoughtMap() or {}
	for key, amount in pairs(RB:GetShoppingListMap()) do
		local entry, need = tonumber(key), tonumber(amount) or 0
		if entry and need > 0 then
			table.insert(items, { entry = entry, need = need, bought = tonumber(bought[entry]) or 0 })
		end
	end
	table.sort(items, function (a, b) return a.entry < b.entry end)
	return items
end

-- Units of an item left to buy; 0 when it isn't on the list.
function Shopping.Need(entry)
	local RB = shoppingBank()
	return RB and tonumber(RB:GetShoppingListMap()[entry]) or 0
end

-- A purchase went through: ReagentBankUI counts it off the list.
function Shopping.Bought(entry, count)
	local RB = shoppingBank()
	if RB and Shopping.Need(entry) > 0 then pcall(RB.RecordShoppingPurchase, RB, entry, count) end
	RAH.Fire("SHOPPING")
end

function Shopping.Remove(entry)
	local RB = shoppingBank()
	if RB and RB.RemoveShoppingListItem then pcall(RB.RemoveShoppingListItem, RB, entry) end
	RAH.Fire("SHOPPING")
end

-- ReagentBankUI's "how many?" popup: puts an item on the list, or changes its amount (0 takes
-- it off).
function Shopping.Edit(entry)
	local RB = shoppingBank()
	if RB and RB.ShowShoppingAmountPopup then pcall(RB.ShowShoppingAmountPopup, RB, entry) end
end

function Shopping.Clear()
	local RB = shoppingBank()
	if RB and RB.ClearShoppingList then pcall(RB.ClearShoppingList, RB) end
	RAH.Fire("SHOPPING")
end

-- ReagentBankUI's own floating list belongs to the Blizzard window: it stays away while this
-- window is the one in use, and comes back with the classic one.
local function floatingShoppingList(show)
	local RB = _G.ReagentBankUI
	if not RB then return end
	if show and RB.ShowAuctionShoppingFrame then
		pcall(RB.ShowAuctionShoppingFrame, RB)
	elseif not show and RB.HideAuctionShoppingFrame then
		pcall(RB.HideAuctionShoppingFrame, RB, false)
	end
end

local function registerShoppingView()
	local RB = _G.ReagentBankUI
	if not (RB and RB.RegisterShoppingListView) then return end
	RB:RegisterShoppingListView({
		name = "RetailAH",
		IsActive = function () return RAH.active end,
		Refresh = function () RAH.Fire("SHOPPING") end,
		Search = function (entry) return RAH.Buy.OpenEntry(entry) end,
	})
end

-----------------------------------------
-- taking over from the Blizzard window

RAH.active = false       -- our window is the one in use for this visit
RAH.serverReady = false  -- the server answered HELLO for this visit
local helloTimer = 0
local switchingToClassic = false

local function showClassic()
	switchingToClassic = true
	if RetailAHFrame and RetailAHFrame:IsShown() then RetailAHFrame:Hide() end
	switchingToClassic = false
	RAH.active = false
	AuctionFrame_LoadUI()
	if AuctionFrame_Show then AuctionFrame_Show() end
	floatingShoppingList(true)
end
RAH.ShowClassic = showClassic

function RAH.IsSwitchingToClassic()
	return switchingToClassic
end

function RAH.OnHello(fields)
	if not RAH.active then return end
	local version = tonumber(fields[1])
	if version ~= RAH.PROTOCOL then
		RAH.Print("the server speaks a different version of the retail auction house (" .. tostring(version)
			.. ", this addon " .. RAH.PROTOCOL .. "). Using the classic window; update the RetailAH addon.")
		showClassic()
		return
	end
	RAH.serverReady = true
	RAH.cutPercent = tonumber(fields[2]) or 5
	RAH.depositPercent = tonumber(fields[3]) or 15
	-- Capability flags; an older server sends none.
	RAH.reagentBank = bit.band(tonumber(fields[4]) or 0, 1) ~= 0
	RAH.appearances = bit.band(tonumber(fields[4]) or 0, 2) ~= 0
	RAH.statFilters = bit.band(tonumber(fields[4]) or 0, 4) ~= 0
	RAH.itemInfo = bit.band(tonumber(fields[4]) or 0, 32) ~= 0
	if RAH.itemInfo then RAH.SetItemStamp(fields[5]) end
	RAH.botPrice = bit.band(tonumber(fields[4]) or 0, 8) ~= 0  -- mod-ah-bot-plus's buyer is on
	RAH.ledger = bit.band(tonumber(fields[4]) or 0, 16) ~= 0
	-- What this character may see: progression era (nil = no era gate), the highest level
	-- need shown (nil = no level gate) and the stat filters that exist in that era.
	RAH.gates = bit.band(tonumber(fields[4]) or 0, 64) ~= 0
	local era, levelCap = tonumber(fields[6]), tonumber(fields[7])
	RAH.era = RAH.gates and era and era ~= 255 and era or nil
	RAH.levelCap = RAH.gates and levelCap and levelCap > 0 and levelCap or nil
	RAH.statsAvailable = RAH.gates and tonumber(fields[8]) or nil
	RAH.Fire("READY")
end

function RAH.OnServerOff()
	if RAH.active then
		RAH.Print("the retail auction house is turned off on this realm.")
		showClassic()
	end
end

local function onAuctionHouseShow()
	if RetailAHDB.classic then
		showClassic()
		return
	end

	RAH.active = true
	RAH.serverReady = false
	RAH.auctioneer = UnitGUID("npc")
	RetailAHFrame:Show()
	-- Whichever addon hears about the visit first: now, and once more for a ReagentBankUI that
	-- shows its list after this without asking.
	floatingShoppingList(false)
	RAH.After(0.05, function () if RAH.active then floatingShoppingList(false) end end)

	helloTimer = helloTimer + 1
	local myTimer = helloTimer
	RAH.Request("HELLO", { RAH.auctioneer or "" }, function (result, err)
		if err and RAH.active and myTimer == helloTimer then
			if err == "far" then CloseAuctionHouse() end
		end
	end)

	-- No answer: the realm doesn't run mod-retail-ah.
	RAH.After(3, function ()
		if myTimer == helloTimer and RAH.active and not RAH.serverReady then
			RAH.Print("this realm doesn't have the retail auction house module; using the classic window.")
			showClassic()
		end
	end)
end

local function onAuctionHouseClosed()
	helloTimer = helloTimer + 1
	RAH.active = false
	RAH.serverReady = false
	resetHeavy()
	if RetailAHFrame and RetailAHFrame:IsShown() then RetailAHFrame:Hide() end
	StaticPopup_Hide("RETAILAH_CONFIRM")
	RAH.Fire("CLOSED")
end

-----------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("AUCTION_HOUSE_SHOW")
events:RegisterEvent("AUCTION_HOUSE_CLOSED")
events:RegisterEvent("CHAT_MSG_ADDON")
events:RegisterEvent("BAG_UPDATE")
events:RegisterEvent("PLAYER_MONEY")
events:RegisterEvent("NEW_AUCTION_UPDATE")

events:SetScript("OnEvent", function (self, event, ...)
	if event == "ADDON_LOADED" then
		if ... == "RetailAH" then
			RetailAHDB = RetailAHDB or {}
			RetailAHDB.favorites = RetailAHDB.favorites or {}
			RetailAHDB.duration = RetailAHDB.duration or 24
			RetailAHDB.filters = RetailAHDB.filters or {}
			RetailAHDB.items = RetailAHDB.items or {}
		end
	elseif event == "PLAYER_LOGIN" then
		-- The stock window only opens when we hand over to it.
		UIParent:UnregisterEvent("AUCTION_HOUSE_SHOW")

		-- Auctionator answers every auction-house visit and expects the Blizzard window to exist.
		if IsAddOnLoaded("Auctionator") then AuctionFrame_LoadUI() end

		registerShoppingView()

		for _, name in ipairs({ "ERR_AUCTION_STARTED", "ERR_AUCTION_REMOVED", "ERR_AUCTION_BID_PLACED", "ERR_AUCTION_WON" }) do
			if _G[name] then QUIET[_G[name]] = true end
		end
		ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", quietFilter)
	elseif event == "AUCTION_HOUSE_SHOW" then
		onAuctionHouseShow()
	elseif event == "AUCTION_HOUSE_CLOSED" then
		onAuctionHouseClosed()
	elseif event == "CHAT_MSG_ADDON" then
		local prefix, message, channel, sender = ...
		if prefix == RAH.PREFIX and sender == UnitName("player") then
			onAddonMessage(message)
		end
	elseif event == "BAG_UPDATE" then
		if RAH.active then RAH.Debounce("bags", 0.2, function () RAH.Fire("BAGS") end) end
	elseif event == "PLAYER_MONEY" then
		RAH.Fire("MONEY")
	elseif event == "NEW_AUCTION_UPDATE" then
		RAH.Fire("SELL_SLOT")
	end
end)

SLASH_RETAILAH1 = "/retailah"
SLASH_RETAILAH2 = "/rah"
SlashCmdList.RETAILAH = function (msg)
	msg = (msg or ""):lower():match("^%s*(.-)%s*$")
	if msg == "classic" then
		RetailAHDB.classic = true
		RAH.Print("the classic window opens from now on. |cffffd200/rah retail|r switches back.")
		-- At the auctioneer already: switch now.
		if RAH.active then showClassic() end
	elseif msg == "retail" then
		RetailAHDB.classic = nil
		RAH.Print("the retail window opens from now on"
			.. ((AuctionFrame and AuctionFrame:IsShown()) and ", starting with your next visit." or "."))
	elseif msg == "reset" then
		RAH.ResetPosition()
		RAH.Print("window position reset.")
	elseif msg == "compare" or msg == "compare on" or msg == "compare off" then
		if msg == "compare" then
			RetailAHDB.alwaysCompare = not RetailAHDB.alwaysCompare or nil
		else
			RetailAHDB.alwaysCompare = msg == "compare on" or nil
		end
		RAH.Print(RetailAHDB.alwaysCompare and "item tooltips compare with your equipped gear on every hover."
			or "item tooltips compare with your gear only while you hold Shift.")
	elseif msg == "tooltip" or msg == "tooltip on" or msg == "tooltip off" then
		local on
		if msg ~= "tooltip" then on = msg == "tooltip on" end
		on = RAH.ToggleTooltip(on)
		RAH.Print(on and "item tooltips show what the AH bot buys an item for, as it is and disenchanted."
			or "item tooltips no longer show AH bot prices.")
	else
		RAH.Print("|cffffd200/rah classic|r or |cffffd200/rah retail|r picks which window opens at the auctioneer. "
			.. "|cffffd200/rah reset|r moves the window back. "
			.. "|cffffd200/rah compare|r compares hovered items with your gear without Shift, or only with Shift again. "
			.. "|cffffd200/rah tooltip|r turns the AH bot prices on item tooltips on or off.")
	end
end
