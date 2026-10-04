-- RetailAH item tooltips: what the AH bot buyer pays for an item, and for the materials
-- disenchanting it gives, on every item tooltip, wherever the player is. The bot is often the
-- only buyer on a small realm, so this is what an item sells for as it is or as dust and essences.
--
--   T:<req>:<entry>,<entry>,...  -> TD rows <entry>,<AH bot pays>,<disenchanted, AH bot pays>,
--                                           <enchanting needed>,<flags>
--                                   TE:<req>
-- flags 1: can be disenchanted, 2: the player's Enchanting is high enough, 4: binds on pickup.
-- See src/RetailAHTooltip.cpp. /rah tooltip turns the lines off and on.

local RAH = RetailAH

local DISENCHANTABLE, CAN_DISENCHANT, SOULBOUND = 1, 2, 4
local MAX_BATCH = 40
local CACHE_SECONDS = 600
local TIMEOUT = 5

local values = {}   -- entry -> { pays, disenchanted, skill, flags, at }
local queued = {}   -- entry -> true, waiting for the next request
local asking = {}   -- entry -> time asked
-- nil until the server answers once; false when it can't (an older module, or turned off),
-- so the tooltips stop asking for the rest of the session.
local supported
local timeouts = 0

local tips = {}
-- tooltip -> { done, count, pays, paysLine } for what it shows now; cleared with the tooltip.
local state = {}

local function entryOf(link)
	return link and tonumber(link:match("item:(%d+)"))
end

-- An item that's already bound can't go to the auction house, whatever its template says.
local BOUND = {}
local function isBound(tip)
	local name = tip:GetName()
	for i = 2, math.min(tip:NumLines(), 5) do
		local line = _G[name .. "TextLeft" .. i]
		local text = line and line:GetText()
		if text and BOUND[text] then return true end
	end
	return false
end

local GOLD_TEXT = { 1, 0.82, 0 }
local GREY_TEXT = { 0.5, 0.5, 0.5 }
local BETTER = { 0.25, 1, 0.25 }
local PLAIN = { 1, 1, 1 }

local function addLine(tip, label, labelColor, money, moneyColor)
	tip:AddDoubleLine(label, money, labelColor[1], labelColor[2], labelColor[3], moneyColor[1], moneyColor[2], moneyColor[3])
	return _G[tip:GetName() .. "TextRight" .. tip:NumLines()]
end

local function stackText(pays, count)
	if not count or count <= 1 then return RAH.Money(pays) end
	return RAH.Money(pays) .. " |cff808080(x" .. count .. ": |r" .. RAH.Money(pays * count) .. "|cff808080)|r"
end

local function addLines(tip, v)
	local st = state[tip]
	st.done = true
	local pays = (bit.band(v.flags, SOULBOUND) == 0 and not isBound(tip)) and v.pays or 0
	local disenchanted = bit.band(v.flags, DISENCHANTABLE) ~= 0 and v.disenchanted or 0
	if pays == 0 and disenchanted == 0 then return false end

	-- Green marks the better of the two when both are there.
	local both = pays > 0 and disenchanted > 0
	if pays > 0 then
		st.pays = pays
		st.paysLine = addLine(tip, "AH bot buys", GOLD_TEXT, stackText(pays, st.count),
			(both and pays >= disenchanted) and BETTER or PLAIN)
	end
	if disenchanted > 0 then
		local able = bit.band(v.flags, CAN_DISENCHANT) ~= 0
		local label = able and "Disenchant (AH bot)" or ("Disenchant |cff808080(Enchanting " .. v.skill .. ")|r")
		addLine(tip, label, able and GOLD_TEXT or GREY_TEXT, "~" .. RAH.Money(disenchanted),
			(both and disenchanted > pays) and BETTER or PLAIN)
	end
	return true
end

local function flush()
	if supported == false then queued = {} return end
	local batch = {}
	local function send()
		if #batch == 0 then return end
		local mine = batch
		batch = {}
		RAH.Request("T", { table.concat(mine, ",") }, function (result, err)
			for _, entry in ipairs(mine) do asking[entry] = nil end
			if err then
				-- "far": a module from before tooltips answers everything away from an
				-- auctioneer that way. "unknown": RetailAH.Tooltip = 0.
				if err == "far" or err == "unknown" then supported = false end
				return
			end
			supported = true
			timeouts = 0
			local now = GetTime()
			for _, r in ipairs(result.rows) do
				local entry = tonumber(r[1])
				if entry then
					values[entry] = { pays = tonumber(r[2]) or 0, disenchanted = tonumber(r[3]) or 0,
						skill = tonumber(r[4]) or 0, flags = tonumber(r[5]) or 0, at = now }
				end
			end
			-- Fill in the tooltips that were waiting for these.
			for _, tip in ipairs(tips) do
				if tip:IsShown() and not state[tip].done then
					local _, link = tip:GetItem()
					local v = values[entryOf(link)]
					if v and addLines(tip, v) then tip:Show() end
				end
			end
		end)
	end
	for entry in pairs(queued) do
		if #batch >= MAX_BATCH then send() end
		table.insert(batch, entry)
		asking[entry] = GetTime()
	end
	send()
	queued = {}
end

local function ask(entry)
	if supported == false then return end
	local since = asking[entry]
	if since then
		if GetTime() - since < TIMEOUT then return end
		-- No answer (RetailAH.Enable = 0 answers OFF, no module at all answers nothing): give
		-- up after a few.
		timeouts = timeouts + 1
		if timeouts >= 3 and not supported then supported = false return end
	end
	queued[entry] = true
	RAH.Debounce("tooltip", 0.05, flush)
end

local function onSetItem(tip)
	if state[tip].done or (RetailAHDB and RetailAHDB.noTooltip) then return end
	local _, link = tip:GetItem()
	local entry = entryOf(link)
	if not entry then return end
	local v = values[entry]
	if v and GetTime() - v.at < CACHE_SECONDS then
		addLines(tip, v)
	else
		ask(entry)
	end
end

local function onCleared(tip)
	state[tip] = {}
end

-- The stack size is only known to the call that filled the tooltip, which runs its
-- OnTooltipSetItem first; put the stack total on the line afterwards.
local function setCount(tip, count)
	local st = state[tip]
	st.count = count
	if count and count > 1 and st.paysLine then
		st.paysLine:SetText(stackText(st.pays, count))
		tip:Show()
	end
end

local function hook(tip)
	if not tip then return end
	table.insert(tips, tip)
	state[tip] = {}
	tip:HookScript("OnTooltipSetItem", onSetItem)
	tip:HookScript("OnTooltipCleared", onCleared)
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function ()
	for _, name in ipairs({ "ITEM_SOULBOUND", "ITEM_ACCOUNTBOUND", "ITEM_BNETACCOUNTBOUND" }) do
		if _G[name] then BOUND[_G[name]] = true end
	end
	hook(GameTooltip)
	hook(ItemRefTooltip)
	hooksecurefunc(GameTooltip, "SetBagItem", function (tip, bag, slot)
		local _, count = GetContainerItemInfo(bag, slot)
		setCount(tip, count)
	end)
	hooksecurefunc(GameTooltip, "SetInventoryItem", function (tip, unit, slot)
		setCount(tip, GetInventoryItemCount(unit, slot))
	end)
end)

function RAH.ToggleTooltip(on)
	if on == nil then on = RetailAHDB.noTooltip and true or false end
	RetailAHDB.noTooltip = not on or nil
	return on
end
