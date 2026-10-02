-- Smoke test for the RetailAH addon outside the game: stubs just enough of the 3.3.5a API,
-- loads the addon in .toc order and replays fake server replies through the real protocol code.
-- Usage (any Lua 5.3+): lua tools/addon_smoke_test.lua addon/RetailAH

local dir = arg[1]
unpack = table.unpack
bit = {
	band = function (a, b) return math.floor(a) & math.floor(b) end,
	lshift = function (a, n) return math.floor(a) << n end,
	bor = function (a, b) return math.floor(a) | math.floor(b) end,
	bnot = function (a) return ~math.floor(a) end,
}
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
_G = _G

local now = 0
function GetTime() return now end

local errors = 0
local function report(where, err)
	errors = errors + 1
	print("ERROR in " .. where .. ": " .. tostring(err))
	print(debug.traceback())
end

-- Frames: tables with scripts; unknown methods are no-ops returning nil.
local frameMeta = {}
local allFrames = {}
local function newObject(kind, name, parent)
	local o = { __kind = kind, __name = name, __scripts = {}, __shown = kind ~= "Frame" or true, __text = "",
		__width = 100, __height = 20, __checked = nil, __children = {}, __parent = parent, __level = 1, __enabled = true }
	setmetatable(o, frameMeta)
	if name then _G[name] = o end
	table.insert(allFrames, o)
	return o
end

local methods = {}
function methods:SetScript(event, fn) self.__scripts[event] = fn end
function methods:GetScript(event) return self.__scripts[event] end
function methods:HookScript(event, fn)
	local old = self.__scripts[event]
	self.__scripts[event] = function (...) if old then old(...) end fn(...) end
end
function methods:Show() local was = self.__shown; self.__shown = true; if not was and self.__scripts.OnShow then self.__scripts.OnShow(self) end end
function methods:Hide() local was = self.__shown; self.__shown = false; if was and self.__scripts.OnHide then self.__scripts.OnHide(self) end end
function methods:IsShown() return self.__shown end
function methods:IsVisible() return self.__shown end
function methods:SetText(t) self.__text = t == nil and "" or tostring(t) end
function methods:GetText() return self.__text end
function methods:GetNumber() return tonumber(self.__text) or 0 end
function methods:SetChecked(c) self.__checked = c and 1 or nil end
function methods:GetChecked() return rawget(self, "__checked") end
function methods:GetWidth() return self.__width end
function methods:GetHeight() return self.__height end
function methods:SetWidth(w) self.__width = w end
function methods:SetHeight(h) self.__height = h end
function methods:SetSize(w, h) self.__width, self.__height = w, h end
function methods:GetName() return self.__name end
function methods:GetFrameLevel() return self.__level end
function methods:GetObjectType() return self.__kind end
function methods:GetRegions() return end
function methods:GetChildren() return end
function methods:CreateTexture() return newObject("Texture") end
function methods:CreateFontString() return newObject("FontString") end
function methods:GetTexture() return nil end
function methods:Enable() self.__enabled = true end
function methods:Disable() self.__enabled = false end
function methods:IsEnabled() return self.__enabled and 1 or nil end
function methods:HasFocus() return false end
function methods:GetID() return self.__id or 0 end
function methods:SetID(i) self.__id = i end
function methods:NumLines() return 0 end
function methods:GetStringWidth() return #self.__text * 7 end
function methods:IsOwned() return false end
function methods:GetVerticalScroll() return 0 end
frameMeta.__index = function (t, k)
	if methods[k] then return methods[k] end
	return function () end
end

function CreateFrame(kind, name, parent, template)
	local f = newObject(kind, name, parent)
	f.__shown = true
	if name and template then
		if template:find("Check") then _G[name .. "Text"] = newObject("FontString") end
		if template:find("MoneyInput") then
			for _, p in ipairs({ "Gold", "Silver", "Copper" }) do _G[name .. p] = newObject("EditBox") end
			f.__copper = 0
		end
		if template:find("FauxScroll") then _G[name .. "ScrollBar"] = newObject("Slider") end
	end
	return f
end

function MoneyInputFrame_GetCopper(f) return f.__copper or 0 end
function MoneyInputFrame_SetCopper(f, c) f.__copper = c; if f.onValueChangedFunc then f.onValueChangedFunc() end end
function MoneyInputFrame_SetOnValueChangedFunc(f, fn) f.onValueChangedFunc = fn end
function FauxScrollFrame_Update() end
function FauxScrollFrame_GetOffset() return 0 end
function FauxScrollFrame_SetOffset() end
function FauxScrollFrame_OnVerticalScroll(self, offset, h, fn) fn() end
function PanelTemplates_SetTab() end
function PanelTemplates_SetNumTabs() end
function PanelTemplates_TabResize() end
function PlaySound() end
function SetPortraitTexture() end
function OpenAllBags() end
function IsAddOnLoaded() return false end
function IsModifiedClick() return false end
function IsShiftKeyDown() return false end
function CursorHasItem() return false end
function GetCursorInfo() return nil end
function ClearCursor() end
function ChatEdit_InsertLink() end
function DressUpItemLink() end
function ChatFrame_AddMessageEventFilter() end
function StaticPopup_Hide() end
local lastPopup
function StaticPopup_Show(which, text)
	lastPopup = { which = which, text = text }
	return lastPopup
end
function UnitName() return "Tester" end
function UnitGUID() return "0xF130001234005678" end
function GetMoney() return 5000000 end
function GetAuctionSellItemInfo() return nil end
function ClickAuctionSellItemButton() end
function CloseAuctionHouse() print("  (client) CloseAuctionHouse") end
function AuctionFrame_LoadUI() print("  (client) AuctionFrame_LoadUI") end
function AuctionFrame_Show() print("  (client) AuctionFrame_Show") end
function ShowUIPanel(f) f:Show() end
function HideUIPanel(f) f:Hide() end

local itemDB = {
	[2589] = { "Linen Cloth", 1, 5, 20, 13, 0 },
	[15210] = { "Raider's Shortsword", 2, 25, 1, 3000, 2 },
	[2447] = { "Peacebloom", 1, 5, 20, 4, 0 },
}
function GetItemInfo(item)
	local entry = type(item) == "number" and item or tonumber(tostring(item):match("item:(%d+)"))
	local d = itemDB[entry]
	if not d then return nil end
	return d[1], "|cffffffff|Hitem:" .. entry .. ":0:0:0:0:0:0:0:0|h[" .. d[1] .. "]|h|r", d[2], d[3], 1, "Trade Goods", "Cloth", d[4], "", "Interface\\Icons\\X", d[5]
end

local bags = { [0] = { [1] = { 2589, 20 }, [2] = { 2589, 7 }, [3] = { 15210, 1 } } }
function GetContainerNumSlots(bag) return bag == 0 and 16 or 0 end
function GetContainerItemLink(bag, slot)
	local it = bags[bag] and bags[bag][slot]
	if not it then return nil end
	local _, link = GetItemInfo(it[1])
	return link
end
function GetContainerItemInfo(bag, slot)
	local it = bags[bag] and bags[bag][slot]
	if not it then return nil end
	return "Interface\\Icons\\X", it[2], false
end
NUM_BAG_SLOTS = 4

ITEM_QUALITY_COLORS = {}
for i = 0, 7 do ITEM_QUALITY_COLORS[i] = { r = 1, g = 1, b = 1, hex = "|cffffffff" } end
for i = 0, 7 do _G["ITEM_QUALITY" .. i .. "_DESC"] = "Q" .. i end
ACCEPT, CANCEL, SEARCH = "Accept", "Cancel", "Search"
ERR_AUCTION_STARTED = "Auction created."
UIParent = newObject("Frame", "UIParent")
WorldFrame = newObject("Frame", "WorldFrame")
GameTooltip = newObject("GameTooltip", "GameTooltip")
ShoppingTooltip1 = newObject("GameTooltip", "ShoppingTooltip1")
ShoppingTooltip2 = newObject("GameTooltip", "ShoppingTooltip2")
local compared = 0
function GameTooltip_ShowCompareItem() compared = compared + 1 end
DEFAULT_CHAT_FRAME = { AddMessage = function (_, m) print("  [chat] " .. m) end }
GameFontHighlightSmall, GameFontNormalSmall = {}, {}
UIPanelWindows, StaticPopupDialogs, SlashCmdList, UISpecialFrames = {}, {}, {}, {}

-- Outgoing messages go to a fake server that answers like mod-retail-ah.
local outbox = {}
function SendAddonMessage(prefix, msg, channel, target)
	assert(prefix == "RAH" and channel == "WHISPER", "bad addon message")
	assert(#prefix + 1 + #msg <= 254, "addon message too long: " .. #msg)
	table.insert(outbox, msg)
end

local eventFrames = {}
function methods:RegisterEvent(e) eventFrames[e] = eventFrames[e] or {}; table.insert(eventFrames[e], self) end
function methods:UnregisterEvent() end
local function fire(event, ...)
	for _, f in ipairs(eventFrames[event] or {}) do
		local ok, err = pcall(f.__scripts.OnEvent, f, event, ...)
		if not ok then report(event, err) end
	end
end

local function reply(msg)
	fire("CHAT_MSG_ADDON", "RAH", msg, "WHISPER", "Tester")
end

local busyOnce = {}
local function serve(msg)
	local cmd, req = msg:match("^([^:]+):([^:]*)")
	print("  -> " .. msg)
	-- The first owned-auctions request is refused as busy, to exercise the retry.
	if cmd == "O" and not busyOnce[req] then busyOnce[req] = true; reply("ERR:" .. req .. ":busy"); return end
	if cmd == "HELLO" then reply("HELLO:" .. req .. ":1:5:15:31")
	elseif cmd == "S" or cmd == "F" then
		reply("SR:" .. req .. ":2:0")
		-- 15210 is one suffix of a random-enchant item (flags 8 + 16, suffix -7, factor 55).
		reply("SD:" .. req .. ":2589,13,47,3,5;15210,45000,2,2,24,-7,55")
		reply("SE:" .. req)
	elseif cmd == "C" then
		reply("CR:" .. req .. ":2589"); reply("CD:" .. req .. ":10,20,0;13,27,7"); reply("CE:" .. req)
	elseif cmd == "I" then
		reply("IR:" .. req .. ":15210:2"); reply("ID:" .. req .. ":101,1,3000,3150,45000,7200,4,-7,55;102,1,0,5000,0,600,1,0,0"); reply("IE:" .. req)
	elseif cmd == "Q" then reply("QR:" .. req .. ":2589:5:50:0")
	elseif cmd == "B" then reply("BR:" .. req .. ":ok:5:50:5:50")
	elseif cmd == "P" then
		local id, price = msg:match("^P:[^:]*:(%d+):(%d+)")
		reply("PR:" .. req .. ":" .. ((id == "101" and price == "45000") and "bought" or "bid"))
	elseif cmd == "X" then reply("XR:" .. req .. ":ok")
	elseif cmd == "D" then reply("DR:" .. req .. ":60:77:20:50")
	elseif cmd == "RB" then reply("RR:" .. req); reply("RD:" .. req .. ":2589,50;2447,30"); reply("RE:" .. req)
	elseif cmd == "PC" or cmd == "PI" then reply("POR:" .. req .. ":2:2:ok")
	elseif cmd == "O" then reply("OR:" .. req); reply("OD:" .. req .. ":201,2589,20,0,300,86000,5,0,0"); reply("OE:" .. req)
	elseif cmd == "V" then reply("V:" .. req .. ":1234:1800")
	elseif cmd == "G" then
		reply("GR:" .. req .. ":50000:2500:300:12000:35200:3:1:2:0")
		if msg:match("^G:%d+:0:") then
			reply("GD:" .. req .. ":120,1,2589,20,30000,1500,28500,*,Tester;7200,2,15210,1,12000,0,-12000,Seller,Tester;90000,3,2589,20,0,300,-300,-,Tester")
		else
			reply("GD:" .. req .. ":2589,20,28500,0,0,300,28200,120;15210,0,0,1,12000,0,-12000,7200")
		end
		reply("GE:" .. req)
	elseif cmd == "BL" then reply("LR:" .. req); reply("LD:" .. req .. ":101,15210,1,3000,3150,45000,7200,-7,55"); reply("LE:" .. req)
	else print("  !! unknown command " .. cmd) end
end

local function tick(seconds)
	for _ = 1, math.ceil(seconds / 0.05) do
		now = now + 0.05
		for _, f in ipairs(allFrames) do
			if f.__shown and f.__scripts.OnUpdate then
				local ok, err = pcall(f.__scripts.OnUpdate, f, 0.05)
				if not ok then report("OnUpdate", err) end
			end
		end
		while #outbox > 0 do serve(table.remove(outbox, 1)) end
	end
end

local function step(name, fn)
	print("== " .. name)
	local ok, err = xpcall(fn, debug.traceback)
	if not ok then errors = errors + 1; print("ERROR: " .. err) end
	tick(1)
end

-- load the addon in .toc order
for line in io.lines(dir .. "/RetailAH.toc") do
	if line:match("%.lua$") then
		local chunk, err = loadfile(dir .. "/" .. line)
		if not chunk then report("load " .. line, err) else
			local ok, e = pcall(chunk, "RetailAH", {})
			if not ok then report("run " .. line, e) end
		end
	end
end

local RAH = RetailAH
local function find(pred)
	for _, f in ipairs(allFrames) do if pred(f) then return f end end
end

step("login", function () fire("ADDON_LOADED", "RetailAH"); fire("PLAYER_LOGIN") end)
step("open auction house", function () fire("AUCTION_HOUSE_SHOW") end)
step("server ready", function ()
	assert(RAH.serverReady, "not ready after HELLO")
	assert(RAH.appearances, "appearances flag not read")
end)
step("uncollected filter sends flag 4", function ()
	RetailAHDB.filters.uncollected = true
	local sent
	local original = SendAddonMessage
	SendAddonMessage = function (p, m, c, t) sent = m; original(p, m, c, t) end
	RAH.Buy.Search()
	tick(0.5)
	SendAddonMessage = original
	assert(sent and sent:match("^S:%d+:4:"), "search did not carry the uncollected flag: " .. tostring(sent))
	RetailAHDB.filters.uncollected = nil
end)
step("stat filters: the mask rides on the flags field, and on opening a result", function ()
	assert(RAH.statFilters, "stat filter flag not read")
	local function check(label)
		return find(function (f) local l = rawget(f, "label") return type(l) == "table" and l.__text == label end)
	end
	local agi, crit = check("Agility"), check("Crit")
	assert(agi and crit, "stat checkboxes missing")
	for _, cb in ipairs({ agi, crit }) do cb:SetChecked(true); cb.__scripts.OnClick(cb) end
	assert(RetailAHDB.filters.stats == 2 + 256, "stat mask not saved: " .. tostring(RetailAHDB.filters.stats))
	assert(find(function (f) return f.__kind == "Button" and f.__text:find("00ff00Filters") end), "Filters button not lit")

	local sent = {}
	local original = SendAddonMessage
	SendAddonMessage = function (p, m, c, t) table.insert(sent, m); original(p, m, c, t) end
	RAH.Buy.Search()
	tick(0.5)
	local search
	for _, m in ipairs(sent) do if m:match("^S:") then search = m end end
	assert(search and search:match("^S:%d+:0,258:"), "search did not carry the stat mask: " .. tostring(search))
	local gear
	for _, f in ipairs(allFrames) do
		local items = rawget(f, "items")
		if type(items) == "table" then
			for _, g in ipairs(items) do if g.entry == 15210 and g.auctions then gear = g end end
		end
	end
	assert(gear, "gear result not listed")
	RAH.Buy.OpenDetail(gear)
	tick(0.5)
	SendAddonMessage = original
	local detail
	for _, m in ipairs(sent) do if m:match("^I:") then detail = m end end
	assert(detail and detail:match("^I:%d+:15210:258:%-7$"), "item view did not carry the stat mask and suffix: " .. tostring(detail))
	RAH.Buy.CloseDetail()
	for _, cb in ipairs({ agi, crit }) do cb:SetChecked(false); cb.__scripts.OnClick(cb) end
	assert(RetailAHDB.filters.stats == nil, "stat mask not cleared")
end)
step("search", function () RAH.Buy.Search() end)
step("a suffix group links and opens only its suffix", function ()
	local gear
	for _, f in ipairs(allFrames) do
		local items = rawget(f, "items")
		if type(items) == "table" then
			for _, g in ipairs(items) do if g.entry == 15210 and g.auctions then gear = g end end
		end
	end
	assert(gear and gear.link == "item:15210:0:0:0:0:0:-7:55", "suffix missing from the result link: " .. tostring(gear and gear.link))
	local sent
	local original = SendAddonMessage
	SendAddonMessage = function (p, m, c, t) if m:match("^I:") then sent = m end original(p, m, c, t) end
	RAH.Buy.OpenDetail(gear)
	tick(0.5)
	SendAddonMessage = original
	assert(sent and sent:match("^I:%d+:15210:0:%-7$"), "item view did not ask for the suffix: " .. tostring(sent))
	RAH.Buy.CloseDetail()
end)
step("hovering an item compares with equipped gear by default", function ()
	local row = find(function (f) return f.__kind == "Button" and rawget(f, "item") and rawget(f, "item").link end)
	assert(row, "no result row")
	local before = compared
	row.__scripts.OnEnter(row)
	assert(compared == before + 1, "no comparison on hover")
	row.__scripts.OnLeave(row)
	SlashCmdList.RETAILAH("compare off")
	row.__scripts.OnEnter(row)
	assert(compared == before + 1, "compared although turned off")
	row.__scripts.OnLeave(row)
	SlashCmdList.RETAILAH("compare")
	assert(not RetailAHDB.noCompare, "toggle did not turn it back on")
end)
step("repeated search shows cached results at once", function ()
	RAH.Buy.Search()
	-- No tick yet: the server hasn't answered, but the last answer is already on screen.
	assert(find(function (f) return f.__kind == "FontString" and f.__text == "2 items" end),
		"cached results not shown before the answer")
end)
step("rapid searches drop the superseded ones", function ()
	local searches = 0
	local original = SendAddonMessage
	SendAddonMessage = function (p, m, c, t) if m:match("^S:") then searches = searches + 1 end original(p, m, c, t) end
	for _ = 1, 8 do RAH.Buy.Search() end
	tick(0.5)
	SendAddonMessage = original
	-- Four go out at once, the four after them replace each other in the queue.
	assert(searches == 5, "expected 5 searches sent, got " .. searches)
end)
step("open commodity", function () RAH.Buy.OpenDetail({ entry = 2589, price = 13, units = 47, auctions = 3, flags = 5 }) end)
step("buy now", function ()
	-- The quote comes in through the debounced Q request; press the button's script.
	for _, f in ipairs(allFrames) do
		if f.__kind == "Button" and f.__text == "Buy Now" and f.__scripts.OnClick and f.__enabled then
			f.__scripts.OnClick(f)
			break
		end
	end
	assert(lastPopup, "no confirm dialog")
	print("  confirm: " .. lastPopup.text)
	lastPopup.data()
end)
step("commodity: bid on stacks toggle", function ()
	for _, f in ipairs(allFrames) do
		if f.__kind == "Button" and f.__text == "Bid on Stacks" and f.__scripts.OnClick then f.__scripts.OnClick(f) end
	end
end)
step("commodity: back to quantity", function ()
	local found
	for _, f in ipairs(allFrames) do
		if f.__kind == "Button" and f.__text == "Buy by Quantity" and f.__scripts.OnClick then found = f end
	end
	assert(found, "toggle label didn't change")
	found.__scripts.OnClick(found)
end)
step("open gear", function () RAH.Buy.OpenDetail({ entry = 15210, price = 45000, units = 2, auctions = 2, flags = 0 }) end)
local function findText(pattern)
	for _, f in ipairs(allFrames) do
		if f.__kind == "FontString" and f.__text:find(pattern) then return f.__text end
	end
end
step("new look marker", function ()
	assert(findText("new look"), "no new look marker in the item view")
end)
step("cheapest listing preselected, buy it", function ()
	local price = findText("45,000") or findText("4g 50s") or findText("GoldIcon")
	assert(price, "no buyout price shown beside Buy Now")
	print("  price shown: " .. price)
	for _, f in ipairs(allFrames) do
		if f.__kind == "Button" and f.__text == "Buy Now" and f.__enabled and f.__scripts.OnEnter then
			f.__scripts.OnClick(f)
		end
	end
	assert(lastPopup, "no confirm")
	print("  confirm: " .. lastPopup.text)
	lastPopup.data()
end)
step("tally shows the purchase", function ()
	local tally = findText("^Purchased:")
	assert(tally, "no tally")
	print("  " .. tally)
end)
step("favorites", function () RAH.SetFavorite(2589, true); RAH.Buy.ShowFavorites() end)
step("sell tab", function () RAH.SelectTab(2) end)
step("select commodity", function () RAH.Sell.Select(0, 1) end)
step("post", function ()
	for _, f in ipairs(allFrames) do
		if f.__kind == "Button" and f.__text == "Post" then
			print("  post enabled: " .. tostring(f.__enabled))
			f.__scripts.OnClick(f)
		end
	end
end)
step("reagent bank flag", function () assert(RAH.reagentBank, "HELLO flag not read") end)
step("select bank-only commodity", function ()
	RAH.Sell.SelectGroup({ identity = "c2447", bag = 255, slot = 2447, entry = 2447, link = "item:2447", name = "Peacebloom",
		texture = "x", quality = 1, commodity = true, count = 0, bank = 30, sellPrice = 4 })
end)
step("post bank-only", function ()
	for _, f in ipairs(allFrames) do
		if f.__kind == "Button" and f.__text == "Post" then f.__scripts.OnClick(f) end
	end
end)
step("reagent bank toggle off: bank-only pick cleared, bags-only flag sent", function ()
	local check = find(function (f) local l = rawget(f, "label") return type(l) == "table" and l.__text == "Include reagent bank" end)
	assert(check and check:IsShown(), "reagent bank checkbox not shown")
	assert(check:GetChecked(), "reagent bank should default to on")
	RAH.Sell.SelectGroup({ identity = "c2447", bag = 255, slot = 2447, entry = 2447, link = "item:2447", name = "Peacebloom",
		texture = "x", quality = 1, commodity = true, count = 0, bank = 30, sellPrice = 4 })
	check:SetChecked(false)
	check.__scripts.OnClick(check)
	assert(RetailAHDB.sellFromBank == false, "setting not saved")
	assert(not find(function (f) return f.__kind == "FontString" and f.__text:find("Peacebloom") end),
		"bank-only item still selected")

	local sent
	local original = SendAddonMessage
	SendAddonMessage = function (p, m, c, t) if m:match("^D:") then sent = m end original(p, m, c, t) end
	RAH.Sell.Select(0, 1)
	tick(0.5)
	SendAddonMessage = original
	assert(sent and sent:match(":1$"), "deposit request without the bags-only flag: " .. tostring(sent))

	check:SetChecked(true)
	check.__scripts.OnClick(check)
	assert(RetailAHDB.sellFromBank == true, "setting not saved back on")
end)
step("bot price: suggested and shown", function ()
	RAH.Sell.Select(0, 1)
	tick(0.5)
	assert(RAH.botPrice, "bot price flag not read")
	local line = find(function (f) return f.__kind == "FontString" and f.__text:find("AH buyer pays") end)
	assert(line, "no bot price line")
	local priceBox = find(function (f) return rawget(f, "__copper") == 1234 end)
	assert(priceBox, "price box not set to the bot's sure price")
end)
step("select gear", function () RAH.Sell.Select(0, 3) end)
step("ledger tab", function ()
	assert(RAH.ledger, "ledger flag not read")
	local sent
	local original = SendAddonMessage
	SendAddonMessage = function (p, m, c, t) if m:match("^G:") then sent = m end original(p, m, c, t) end
	RAH.SelectTab(4)
	tick(0.5)
	assert(sent and sent:match("^G:%d+:0:0:7$"), "ledger request: " .. tostring(sent))
	assert(find(function (f) return f.__kind == "FontString" and f.__text:find("^Net ") end), "no net total")
	for _, f in ipairs(allFrames) do
		if f.__kind == "Button" and f.__text == "By Item" then f.__scripts.OnClick(f) end
	end
	tick(0.5)
	assert(sent:match("^G:%d+:1:0:7$"), "by-item request: " .. tostring(sent))
	local check = find(function (f) local l = rawget(f, "label") return type(l) == "table" and l.__text == "All characters" end)
	check:SetChecked(true)
	check.__scripts.OnClick(check)
	tick(0.5)
	assert(sent:match("^G:%d+:1:1:7$"), "account request: " .. tostring(sent))
	assert(RetailAHDB.ledgerAccount, "account choice not saved")
	SendAddonMessage = original
end)
step("auctions tab", function () RAH.SelectTab(3) end)
step("bids view", function ()
	for _, f in ipairs(allFrames) do
		if f.__kind == "Button" and f.__text == "Bids" and f.__scripts.OnClick then f.__scripts.OnClick(f) end
	end
end)
step("no Classic button; /rah classic switches at once", function ()
	assert(not find(function (f) return f.__kind == "Button" and f.__text == "Classic" end), "Classic button still there")
	local shown
	local original = AuctionFrame_Show
	AuctionFrame_Show = function () shown = true end
	SlashCmdList.RETAILAH("classic")
	AuctionFrame_Show = original
	assert(shown and not RAH.active, "didn't switch to the classic window")
	SlashCmdList.RETAILAH("retail")
	assert(not RetailAHDB.classic, "retail not saved")
	RetailAHFrame:Show(); RAH.active = true
end)
step("close", function () RetailAHFrame:Hide(); fire("AUCTION_HOUSE_CLOSED") end)
step("module missing", function ()
	fire("AUCTION_HOUSE_SHOW")
	outbox = {} -- the server never answers
end)
tick(4)
print(errors == 0 and "ALL OK" or (errors .. " error(s)"))
