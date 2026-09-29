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

-- { name, link, quality, itemLevel, reqLevel, class, subclass, maxStack, equipLoc, texture,
--   sellPrice } or nil while the client is still asking the server.
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

	local key = itemString(item)
	if not waiting[key] then
		waiting[key] = GetTime()
		waitingCount = waitingCount + 1
		scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
		scanTip:SetHyperlink(key)
	end
	return nil
end

-- A link for an auction row, including the random suffix the server told us about.
function RAH.ItemString(entry, randomProperty, suffixFactor)
	randomProperty = tonumber(randomProperty) or 0
	if randomProperty == 0 then return "item:" .. entry end
	return string.format("item:%d:0:0:0:0:0:%d:%d", entry, randomProperty, tonumber(suffixFactor) or 0)
end

local pollFrame = CreateFrame("Frame")
local pollElapsed = 0
pollFrame:SetScript("OnUpdate", function (self, elapsed)
	if waitingCount == 0 then return end
	pollElapsed = pollElapsed + elapsed
	if pollElapsed < 0.25 then return end
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

-- Requests that walk the whole auction house; the server takes one every 250 ms per player.
local HEAVY = { S = true, F = true }
local HEAVY_GAP = 0.3
local heavyQueue = {}
local lastHeavy = 0

local LISTS = { S = true, C = true, I = true, O = true, L = true }

local function send(msg)
	SendAddonMessage(RAH.PREFIX, msg, "WHISPER", UnitName("player"))
end

local heavyFrame = CreateFrame("Frame")
heavyFrame:Hide()
heavyFrame:SetScript("OnUpdate", function (self)
	if #heavyQueue == 0 then self:Hide() return end
	if GetTime() - lastHeavy < HEAVY_GAP then return end
	lastHeavy = GetTime()
	send(table.remove(heavyQueue, 1))
end)

-- handler(result, err): result is { rows = {...}, meta = {...} } for list answers and the
-- array of fields for single ones; err is set when the server refused ("far", "busy", "bad").
local function dispatch(p)
	if p.heavy then
		table.insert(heavyQueue, p.msg)
		heavyFrame:Show()
	else
		send(p.msg)
	end
end

function RAH.Request(cmd, fields, handler)
	nextReq = nextReq + 1
	local req = tostring(nextReq)

	local msg = cmd .. ":" .. req
	if fields and #fields > 0 then
		msg = msg .. ":" .. table.concat(fields, ":")
	end

	local p = { handler = handler, rows = {}, msg = msg, heavy = HEAVY[cmd], tries = 0 }
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
		if rest == "busy" and p and p.tries < 4 then
			p.tries = p.tries + 1
			RAH.After(0.4 * p.tries, function () if pending[req] == p then dispatch(p) end end)
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
-- taking over from the Blizzard window

RAH.active = false       -- our window is the one in use for this visit
RAH.serverReady = false  -- the server answered HELLO for this visit
local helloTimer = 0
local switchingToClassic = false

local function showClassic()
	switchingToClassic = true
	if RetailAHFrame and RetailAHFrame:IsShown() then HideUIPanel(RetailAHFrame) end
	switchingToClassic = false
	RAH.active = false
	AuctionFrame_LoadUI()
	if AuctionFrame_Show then AuctionFrame_Show() end
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
	ShowUIPanel(RetailAHFrame)
	if not RetailAHFrame:IsShown() then
		-- Another panel refused to give way; don't strand the player without a window.
		showClassic()
		return
	end

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
	if RetailAHFrame and RetailAHFrame:IsShown() then HideUIPanel(RetailAHFrame) end
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
		end
	elseif event == "PLAYER_LOGIN" then
		-- The stock window only opens when we hand over to it.
		UIParent:UnregisterEvent("AUCTION_HOUSE_SHOW")

		-- Auctionator answers every auction-house visit and expects the Blizzard window to exist.
		if IsAddOnLoaded("Auctionator") then AuctionFrame_LoadUI() end

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
	elseif msg == "retail" then
		RetailAHDB.classic = nil
		RAH.Print("the retail window opens from now on.")
	else
		RAH.Print("|cffffd200/rah classic|r or |cffffd200/rah retail|r picks which window opens at the auctioneer. "
			.. "The Classic button in the retail window switches for one visit.")
	end
end
