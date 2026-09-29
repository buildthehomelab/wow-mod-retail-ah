-- Sell tab: pick an item (right-click it in your bags, drop it on the slot, or pick it from the
-- list), set quantity, price and duration, and post. Commodities are priced per unit and go up
-- as full stacks gathered from all your bags and, when the server has mod-reagent-bank-account
-- and the player hasn't turned it off, the reagent bank; other items get a buyout and an
-- optional bid.

local RAH = RetailAH

local panel, TAB = RAH.AddTab("Sell")
local Sell = {}
RAH.Sell = Sell

local state = {
	item = nil,         -- { bag, slot, entry, link, name, texture, quality, commodity, sellPrice, identity }
	available = 0,
	stack = 1,
	deposit = 0,
	priceTouched = false,  -- the player set the price; stop suggesting one
	settingPrice = false,  -- the addon is filling the price box, not the player
	listingsReq = nil,
	depositReq = nil,
	bank = {},          -- reagent bank contents, entry -> amount
	bankReq = nil,
}

local DURATIONS = { 12, 24, 48 }

-- The server's "bag" for addressing a commodity by entry, so it can come from the reagent bank.
local BAG_BY_ENTRY = 255
local BANK_MARK = "|cff4fc3f7+|r"
-- Last field of D and PC: leave the reagent bank alone.
local POST_BAGS_ONLY = 1

-- Selling from the reagent bank is on unless the player turned it off (account wide).
local function useBank()
	return RAH.reagentBank and RetailAHDB.sellFromBank ~= false
end

local function postFlags()
	return useBank() and 0 or POST_BAGS_ONLY
end

-----------------------------------------
-- the form

local form = RAH.CreateInset(panel)
form:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
form:SetSize(300, 290)

local slot = RAH.CreateItemButton(form, 42)
slot:SetPoint("TOPLEFT", form, "TOPLEFT", 14, -14)
slot:RegisterForClicks("LeftButtonUp", "RightButtonUp")
local slotEmpty = slot:CreateTexture(nil, "BACKGROUND")
slotEmpty:SetAllPoints(slot)
slotEmpty:SetTexture("Interface\\Buttons\\UI-EmptySlot-Disabled")
slotEmpty:SetTexCoord(0.15, 0.85, 0.15, 0.85)

local itemName = form:CreateFontString(nil, "OVERLAY", "GameFontNormal")
itemName:SetPoint("TOPLEFT", slot, "TOPRIGHT", 10, -2)
itemName:SetPoint("RIGHT", form, "RIGHT", -12, 0)
itemName:SetJustifyH("LEFT")
itemName:SetHeight(28)

local inBags = form:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
inBags:SetPoint("TOPLEFT", itemName, "BOTTOMLEFT", 0, 0)

local hint = form:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
hint:SetPoint("TOPLEFT", slot, "BOTTOMLEFT", 0, -14)
hint:SetPoint("RIGHT", form, "RIGHT", -12, 0)
hint:SetJustifyH("LEFT")
hint:SetText("Right-click an item in your bags, drop one here, or pick one from the list below.")

local fields = CreateFrame("Frame", nil, form)
fields:SetPoint("TOPLEFT", slot, "BOTTOMLEFT", 0, -10)
fields:SetPoint("BOTTOMRIGHT", form, "BOTTOMRIGHT", -12, 12)

local qtyLabel = RAH.CreateLabel(fields, "Quantity")
qtyLabel:SetPoint("TOPLEFT", fields, "TOPLEFT", 0, -6)
local qtyBox = RAH.CreateEditBox(fields, 60, true)
qtyBox:SetMaxLetters(5)
qtyBox:SetPoint("TOPLEFT", fields, "TOPLEFT", 94, -2)
local maxButton = RAH.CreateButton(fields, "Max", 50, 20)
maxButton:SetPoint("LEFT", qtyBox, "RIGHT", 6, 0)

local priceLabel = RAH.CreateLabel(fields, "Unit Price")
priceLabel:SetPoint("TOPLEFT", qtyLabel, "BOTTOMLEFT", 0, -20)
local priceInput = RAH.CreateMoneyInput(fields)
priceInput:SetPoint("TOPLEFT", fields, "TOPLEFT", 90, -34)

local bidLabel = RAH.CreateLabel(fields, "Starting Bid", "GameFontNormalSmall")
bidLabel:SetPoint("TOPLEFT", priceLabel, "BOTTOMLEFT", 0, -20)
local bidInput = RAH.CreateMoneyInput(fields)
bidInput:SetPoint("TOPLEFT", fields, "TOPLEFT", 90, -64)
-- Optional: left at 0 the auction is buyout only.
local bidHint = fields:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
bidHint:SetPoint("TOPLEFT", bidLabel, "BOTTOMLEFT", 0, -1)
bidHint:SetText("optional")

local durationLabel = RAH.CreateLabel(fields, AUCTION_DURATION or "Duration")
durationLabel:SetPoint("TOPLEFT", fields, "TOPLEFT", 0, -102)
local durationChecks = {}
for i, hours in ipairs(DURATIONS) do
	local cb = RAH.CreateCheck(fields, hours .. " Hours")
	cb.hours = hours
	if i == 1 then
		cb:SetPoint("TOPLEFT", fields, "TOPLEFT", 86, -96)
	else
		cb:SetPoint("LEFT", durationChecks[i - 1], "RIGHT", 64, 0)
	end
	durationChecks[i] = cb
end
-- Three in a row don't fit with labels; put the third under the first.
durationChecks[3]:ClearAllPoints()
durationChecks[3]:SetPoint("TOPLEFT", durationChecks[1], "BOTTOMLEFT", 0, 4)

local depositLabel = RAH.CreateLabel(fields, "Deposit", "GameFontNormalSmall")
depositLabel:SetPoint("TOPLEFT", fields, "TOPLEFT", 0, -148)
local depositValue = RAH.CreateMoneyText(fields, "GameFontHighlightSmall")
depositValue:SetPoint("TOPRIGHT", fields, "TOPRIGHT", 0, -148)

local totalLabel = RAH.CreateLabel(fields, "Total Price")
totalLabel:SetPoint("TOPLEFT", depositLabel, "BOTTOMLEFT", 0, -10)
local totalValue = RAH.CreateMoneyText(fields, "GameFontHighlight")
totalValue:SetPoint("TOPRIGHT", depositValue, "BOTTOMRIGHT", 0, -10)

local postButton = RAH.CreateButton(fields, "Post", 150, 26)
postButton:SetPoint("BOTTOM", fields, "BOTTOM", 0, 0)

-----------------------------------------
-- the player's sellable items

local bagPane = RAH.CreateInset(panel)
bagPane:SetPoint("TOPLEFT", form, "BOTTOMLEFT", 0, -6)
bagPane:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 0)
bagPane:SetWidth(300)

local bankCheck = RAH.CreateCheck(bagPane, "Include reagent bank")
bankCheck:SetPoint("TOPLEFT", bagPane, "TOPLEFT", 6, -2)
bankCheck.label:SetTextColor(0.31, 0.76, 0.97)
bankCheck:SetScript("OnEnter", function (self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine("Include reagent bank")
	GameTooltip:AddLine("List what's in your reagent bank with your bags, and post commodities from it once "
		.. "your bags run out. Off: only what's in your bags.", 1, 1, 1, true)
	GameTooltip:Show()
end)
bankCheck:SetScript("OnLeave", function () GameTooltip:Hide() end)
bankCheck:Hide()

local bagItems = RAH.CreateList(bagPane, {
	rows = 6,
	rowHeight = 20,
	columns = {
		{ title = "Your Items", icon = function (b) return b.texture end,
			text = function (b)
				local _, _, _, hex = RAH.QualityColor(b.quality)
				return hex .. b.name .. "|r"
			end,
			sort = function (b) return b.name end },
		{ title = "Count", width = 64, align = "RIGHT",
			text = function (b)
				local n = RAH.Number(b.count + (b.bank or 0))
				return (b.bank or 0) > 0 and (n .. BANK_MARK) or n
			end,
			sort = function (b) return b.count + (b.bank or 0) end, defaultDesc = true },
	},
	defaultSort = 1,
	link = function (b) return b.link end,
	tooltipExtra = function (b, tip)
		if (b.bank or 0) > 0 then
			tip:AddLine(" ")
			tip:AddDoubleLine("In your bags", RAH.Number(b.count), 1, 1, 1, 1, 1, 1)
			tip:AddDoubleLine("In your reagent bank", RAH.Number(b.bank), 0.31, 0.76, 0.97, 0.31, 0.76, 0.97)
		end
	end,
	isSelected = function (b) return state.item and state.item.identity == b.identity end,
	onClick = function (b) Sell.SelectGroup(b) end,
	empty = "Nothing in your bags can be auctioned.",
})
bagItems:SetPoint("BOTTOMRIGHT", bagPane, "BOTTOMRIGHT", -4, 4)

-- The checkbox only takes room when the realm has a reagent bank.
local function placeBagList()
	bagItems:ClearAllPoints()
	bagItems:SetPoint("BOTTOMRIGHT", bagPane, "BOTTOMRIGHT", -4, 4)
	if RAH.reagentBank then
		bankCheck:SetChecked(useBank())
		bankCheck:Show()
		bagItems:SetPoint("TOPLEFT", bagPane, "TOPLEFT", 4, -26)
	else
		bankCheck:Hide()
		bagItems:SetPoint("TOPLEFT", bagPane, "TOPLEFT", 4, -4)
	end
end
placeBagList()

-----------------------------------------
-- current listings, to price against

local listingPane = RAH.CreateInset(panel)
listingPane:SetPoint("TOPLEFT", form, "TOPRIGHT", 6, 0)
listingPane:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)

local listingTitle = listingPane:CreateFontString(nil, "OVERLAY", "GameFontNormal")
listingTitle:SetPoint("TOPLEFT", listingPane, "TOPLEFT", 10, -8)
listingTitle:SetText("Current Listings")

local listingNote = listingPane:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
listingNote:SetPoint("TOPRIGHT", listingPane, "TOPRIGHT", -10, -10)
listingNote:SetText("Click a price to match it")

local function setPrice(copper)
	state.priceTouched = true
	priceInput:SetCopper(copper)
end

-- Fill the price box without it counting as the player's choice.
local function suggestPrice(copper)
	state.settingPrice = true
	priceInput:SetCopper(copper)
	state.settingPrice = false
end

local tierList = RAH.CreateList(listingPane, {
	rows = 20,
	columns = {
		{ title = "Unit Price", width = 170, align = "RIGHT", text = function (t) return RAH.Money(t.price) end,
			sort = function (t) return t.price end },
		{ title = "Available", align = "RIGHT", text = function (t) return RAH.Number(t.units) end },
		{ title = "Yours", width = 70, align = "RIGHT",
			text = function (t) return t.own > 0 and ("|cff4fc3f7" .. RAH.Number(t.own) .. "|r") or "" end },
	},
	defaultSort = 1,
	onClick = function (t) setPrice(t.price) end,
	empty = "Nobody is selling this right now.",
})
tierList:SetPoint("TOPLEFT", listingPane, "TOPLEFT", 4, -28)
tierList:SetPoint("BOTTOMRIGHT", listingPane, "BOTTOMRIGHT", -4, 4)

local auctionList = RAH.CreateList(listingPane, {
	rows = 20,
	columns = {
		{ title = "Bid", width = 120, align = "RIGHT", text = function (a) return RAH.Money(a.bid) end,
			sort = function (a) return a.minBid end },
		{ title = "Buyout", width = 120, align = "RIGHT",
			text = function (a) return a.buyout > 0 and RAH.Money(a.buyout) or "|cff808080--|r" end,
			sort = function (a) return a.buyout > 0 and a.buyout or math.huge end },
		{ title = "Name", icon = function (a) local i = RAH.Item(a.link) return i and i.texture end,
			text = function (a)
				local i = RAH.Item(a.link)
				if not i then return "|cff808080Loading...|r" end
				local _, _, _, hex = RAH.QualityColor(i.quality)
				return hex .. i.name .. "|r"
			end },
		{ title = "Time Left", width = 76, align = "RIGHT", text = function (a) return RAH.TimeLeft(a.timeLeft) end,
			sort = function (a) return a.timeLeft end },
		{ title = "", width = 36, align = "CENTER",
			text = function (a) return bit.band(a.flags, RAH.AUCTION_OWN) ~= 0 and "|cff4fc3f7You|r" or "" end },
	},
	defaultSort = 2,
	link = function (a) return a.link end,
	onClick = function (a) if a.buyout > 0 then setPrice(a.buyout) end end,
	empty = "Nobody is selling this right now.",
})
auctionList:SetPoint("TOPLEFT", listingPane, "TOPLEFT", 4, -28)
auctionList:SetPoint("BOTTOMRIGHT", listingPane, "BOTTOMRIGHT", -4, 4)
auctionList:Hide()

-----------------------------------------
-- bag scanning

local scanTip = RetailAHScanTooltip
local NOT_POSTABLE = {}

local function isPostable(bag, slotIndex)
	scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
	scanTip:ClearLines()
	scanTip:SetBagItem(bag, slotIndex)
	for i = 2, math.min(scanTip:NumLines(), 6) do
		local line = _G["RetailAHScanTooltipTextLeft" .. i]
		local text = line and line:GetText()
		if text and NOT_POSTABLE[text] then return false end
	end
	return true
end

-- One row per kind of item: commodities by entry, gear by exact link (random suffixes differ).
local function scanBags()
	local groups, list = {}, {}
	for bag = 0, NUM_BAG_SLOTS do
		for s = 1, GetContainerNumSlots(bag) do
			local link = GetContainerItemLink(bag, s)
			if link then
				local texture, count = GetContainerItemInfo(bag, s)
				local entry = tonumber(link:match("item:(%d+)"))
				local name, _, quality, _, _, _, _, maxStack, _, _, sellPrice = GetItemInfo(link)
				if entry and name and isPostable(bag, s) then
					local commodity = (maxStack or 1) > 1
					local identity = commodity and ("c" .. entry) or link:match("item:([%-%d:]+)")
					local g = groups[identity]
					if not g then
						g = {
							identity = identity, bag = bag, slot = s, entry = entry, link = link, name = name,
							texture = texture, quality = quality or 1, commodity = commodity, count = 0,
							sellPrice = sellPrice or 0, order = #list + 1,
						}
						groups[identity] = g
						table.insert(list, g)
					end
					g.count = g.count + (count or 1)
				end
			end
		end
	end

	-- Reagent bank contents join their bag stacks, or get a row of their own.
	for entry, amount in pairs(useBank() and state.bank or {}) do
		local identity = "c" .. entry
		local g = groups[identity]
		if g then
			g.bank = amount
		else
			local info = RAH.Item(entry)
			if info and info.maxStack > 1 then
				g = {
					identity = identity, bag = BAG_BY_ENTRY, slot = entry, entry = entry, link = info.link, name = info.name,
					texture = info.texture, quality = info.quality, commodity = true, count = 0, bank = amount,
					sellPrice = info.sellPrice, order = #list + 1,
				}
				groups[identity] = g
				table.insert(list, g)
			end
		end
	end
	return list, groups
end

-----------------------------------------
-- keeping the form in sync

local function hours()
	return RetailAHDB.duration or 24
end

local function quantity()
	return tonumber(qtyBox:GetText()) or 0
end

local function updateTotal()
	local item = state.item
	if not item then totalValue:SetText("") return end
	totalValue:SetMoney(priceInput:GetCopper() * math.max(quantity(), 0))
end

local function updatePostButton()
	local item, qty = state.item, quantity()
	local price = priceInput:GetCopper()
	local ok = item and qty > 0 and qty <= state.available and price > 0
	if ok then
		-- Per unit for commodities, like the price; never above it.
		local bid = bidInput:GetCopper()
		ok = bid == 0 or bid <= price
	end
	RAH.SetEnabled(postButton, ok and RAH.serverReady and GetMoney() >= state.deposit)
end

local function requestDeposit()
	local item = state.item
	if not item then return end
	RAH.Debounce("deposit", 0.2, function ()
		if state.item ~= item then return end
		local token = {}
		state.depositReq = token
		RAH.Request("D", { item.bag, item.slot, math.max(quantity(), 1), hours(), postFlags() }, function (result)
			if state.depositReq ~= token or not result then return end
			state.deposit = tonumber(result[1]) or 0
			state.available = tonumber(result[2]) or 0
			state.stack = tonumber(result[3]) or 1
			depositValue:SetMoney(state.deposit)
			local bank = tonumber(result[4]) or 0
			if item.commodity and bank > 0 then
				inBags:SetText("Bags: " .. RAH.Number(state.available - bank) .. "   |cff4fc3f7Reagent bank: " .. RAH.Number(bank) .. "|r")
			elseif item.commodity then
				inBags:SetText("In bags: " .. RAH.Number(state.available))
			else
				inBags:SetText(state.available > 1 and ("Identical in bags: " .. state.available) or "")
			end
			if state.available == 0 then
				RAH.Status("That item can't be auctioned.", true)
			end
			updatePostButton()
		end)
	end)
end

local function defaultPrice(lowest)
	local item = state.item
	if state.priceTouched or not item then return end
	if lowest and lowest > 0 then
		suggestPrice(lowest)
	else
		-- Nothing to compare with: a few times what a vendor pays.
		suggestPrice(math.max(item.sellPrice * 3, 100))
	end
	updateTotal()
	updatePostButton()
end

local function loadListings()
	local item = state.item
	if not item then return end
	local token = {}
	state.listingsReq = token
	if item.commodity then
		tierList:Show(); auctionList:Hide()
		RAH.Request("C", { item.entry }, function (result)
			if state.listingsReq ~= token or not result then return end
			local list, lowest = {}, nil
			for i, r in ipairs(result.rows) do
				table.insert(list, { price = r[1], units = r[2], own = r[3], order = i })
				if r[3] < r[2] and (not lowest or r[1] < lowest) then lowest = r[1] end
			end
			tierList:SetItems(list)
			defaultPrice(lowest)
		end)
	else
		tierList:Hide(); auctionList:Show()
		RAH.Request("I", { item.entry }, function (result)
			if state.listingsReq ~= token or not result then return end
			local list, lowest = {}, nil
			for i, r in ipairs(result.rows) do
				local a = { id = r[1], count = r[2], bid = r[3], minBid = r[4], buyout = r[5], timeLeft = r[6], flags = r[7],
					link = RAH.ItemString(item.entry, r[8], r[9]), order = i }
				table.insert(list, a)
				if a.buyout > 0 and bit.band(a.flags, RAH.AUCTION_OWN) == 0 and (not lowest or a.buyout < lowest) then
					lowest = a.buyout
				end
			end
			auctionList:SetItems(list)
			defaultPrice(lowest)
		end)
	end
end

local function showForm(item)
	if item then
		slotEmpty:Hide()
		slot:SetItem(item.texture, item.quality)
		local _, _, _, hex = RAH.QualityColor(item.quality)
		itemName:SetText(hex .. item.name .. "|r")
		hint:Hide()
		fields:Show()
		priceLabel:SetText(item.commodity and "Unit Price" or "Buyout Price")
		bidLabel:SetText(item.commodity and "Bid per Unit" or "Starting Bid")
		listingNote:Show()
	else
		slotEmpty:Show()
		slot:SetItem(nil)
		itemName:SetText("")
		inBags:SetText("")
		hint:Show()
		fields:Hide()
		tierList:SetItems({}); auctionList:SetItems({})
		tierList:Show(); auctionList:Hide()
		listingNote:Hide()
	end
	for _, cb in ipairs(durationChecks) do cb:SetChecked(cb.hours == hours()) end
end

-- Pick a row of the item list (which may be reagent-bank only).
function Sell.SelectGroup(item)
	state.item = item
	state.priceTouched = false
	state.available = item.count
	state.deposit = 0
	suggestPrice(0)
	bidInput:SetCopper(0)
	qtyBox:SetText(tostring(item.commodity and (item.count + (item.bank or 0)) or 1))
	showForm(item)
	bagItems:Refresh()
	loadListings()
	requestDeposit()
end

-- Pick the item in a bag slot.
function Sell.Select(bag, slotIndex)
	local link = GetContainerItemLink(bag, slotIndex)
	if not link then return end
	local _, groups = scanBags()
	local item
	for _, g in pairs(groups) do
		if g.link == link or (g.commodity and g.entry == tonumber(link:match("item:(%d+)"))) then item = g break end
	end
	if not item then
		RAH.Status("That item can't be auctioned.", true)
		return
	end
	-- Point at the stack that was actually picked.
	item.bag, item.slot = bag, slotIndex
	Sell.SelectGroup(item)
end

function Sell.Clear()
	state.item = nil
	state.listingsReq = nil
	state.depositReq = nil
	showForm(nil)
	bagItems:Refresh()
end

-- After a post the picked stack may be gone; find another stack of the same thing, if any.
local function relocate()
	local item = state.item
	if not item then return end
	local list, groups = scanBags()
	local g = groups[item.identity]
	if not g then
		Sell.Clear()
		return
	end
	item.bag, item.slot, item.count, item.bank = g.bag, g.slot, g.count, g.bank
	requestDeposit()
end

-----------------------------------------
-- controls

qtyBox:SetScript("OnTextChanged", function () updateTotal(); updatePostButton(); requestDeposit() end)
maxButton:SetScript("OnClick", function () qtyBox:SetText(tostring(state.available or 0)) end)
MoneyInputFrame_SetOnValueChangedFunc(priceInput, function ()
	if not state.settingPrice then state.priceTouched = true end
	updateTotal()
	updatePostButton()
end)
MoneyInputFrame_SetOnValueChangedFunc(bidInput, updatePostButton)

for _, cb in ipairs(durationChecks) do
	cb:SetScript("OnClick", function (self)
		RetailAHDB.duration = self.hours
		for _, other in ipairs(durationChecks) do other:SetChecked(other == self) end
		requestDeposit()
	end)
end

local STATUS_TEXT = {
	money = "You can't pay the deposit for any more.",
	count = "You don't have that many.",
	price = "That price isn't allowed.",
	item = "That item can't be auctioned.",
	fail = "The auction house refused that.",
}

postButton:SetScript("OnClick", function ()
	local item = state.item
	if not item then return end
	local qty, price = quantity(), priceInput:GetCopper()
	RAH.SetEnabled(postButton, false)
	RAH.QuietChat(5)
	local args
	if item.commodity then
		-- The bid goes last, so a server without it just posts buyout only.
		args = { item.bag, item.slot, qty, price, hours(), bidInput:GetCopper(), postFlags() }
	else
		local bid = bidInput:GetCopper()
		if bid == 0 then bid = price end
		args = { item.bag, item.slot, qty, bid, price, hours() }
	end
	RAH.Request(item.commodity and "PC" or "PI", args, function (result, err)
		if err or not result then
			RAH.Status("Posting failed.", true)
			updatePostButton()
			return
		end
		local created, requested, status = tonumber(result[1]) or 0, tonumber(result[2]) or 0, result[3]
		if created > 0 and status == "ok" then
			local what = item.commodity and (RAH.Number(qty) .. " x " .. item.link) or item.link
			RAH.Status("Posted " .. what .. (created > 1 and (" in " .. created .. " auctions") or "") .. ".")
			PlaySound("LOOTWINDOWCOINSOUND")
		elseif created > 0 then
			RAH.Status("Posted " .. created .. " of " .. requested .. " auctions. " .. (STATUS_TEXT[status] or ""), true)
		else
			RAH.Status(STATUS_TEXT[status] or "Posting failed.", true)
		end
		state.priceTouched = true
		RAH.After(0.3, function ()
			relocate()
			loadListings()
		end)
		RAH.Fire("POSTED")
	end)
end)

-- Drop an item on the slot (or click it holding one).
local function takeCursorItem()
	local kind, _, link = GetCursorInfo()
	if kind ~= "item" then return false end
	for bag = 0, NUM_BAG_SLOTS do
		for s = 1, GetContainerNumSlots(bag) do
			local _, _, locked = GetContainerItemInfo(bag, s)
			if locked and GetContainerItemLink(bag, s) == link then
				ClearCursor()
				Sell.Select(bag, s)
				return true
			end
		end
	end
	ClearCursor()
	RAH.Status("Drop items from your bags.", true)
	return true
end
slot:SetScript("OnReceiveDrag", takeCursorItem)
slot:SetScript("OnClick", function (self, button)
	if takeCursorItem() then return end
	if button == "RightButton" then Sell.Clear() end
end)
slot:SetScript("OnEnter", function (self)
	if state.item then
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		if state.item.bag == BAG_BY_ENTRY then
			GameTooltip:SetHyperlink(state.item.link)
		else
			GameTooltip:SetBagItem(state.item.bag, state.item.slot)
		end
		GameTooltip:AddLine("Right-click to clear", 0.5, 0.8, 1)
		GameTooltip:Show()
	end
end)
slot:SetScript("OnLeave", function () GameTooltip:Hide() end)

-----------------------------------------
-- right-click in the bags: with the auction house open the client drops the item into its own
-- (hidden) sell slot; take it back out and load it here instead

RAH.On("SELL_SLOT", function ()
	if not RAH.active then return end
	local name = GetAuctionSellItemInfo()
	-- Never click the sell slot while the player holds something: it would swap it in.
	if not name or CursorHasItem() then return end

	local found
	for bag = 0, NUM_BAG_SLOTS do
		for s = 1, GetContainerNumSlots(bag) do
			local _, _, locked = GetContainerItemInfo(bag, s)
			local link = locked and GetContainerItemLink(bag, s)
			if link and GetItemInfo(link) == name then found = { bag, s } break end
		end
		if found then break end
	end

	ClickAuctionSellItemButton()
	ClearCursor()

	if found then
		if RAH.currentTab ~= TAB then RAH.SelectTab(TAB) end
		Sell.Select(found[1], found[2])
	end
end)

-----------------------------------------

local function refreshBags()
	local list = scanBags()
	bagItems:SetItems(list, true)
end

local function loadBank()
	placeBagList()
	if not RAH.reagentBank then
		state.bank = {}
		return
	end
	local token = {}
	state.bankReq = token
	RAH.Request("RB", nil, function (result)
		if state.bankReq ~= token or not result then return end
		local bank = {}
		for _, r in ipairs(result.rows) do bank[r[1]] = r[2] end
		state.bank = bank
		if panel:IsShown() then
			refreshBags()
			if state.item then relocate() end
		end
	end)
end

RAH.On("BAGS", function ()
	if panel:IsShown() then refreshBags() end
end)

bankCheck:SetScript("OnClick", function (self)
	RetailAHDB.sellFromBank = self:GetChecked() and true or false
	refreshBags()
	-- A bank-only pick disappears; anything else now counts with or without the bank.
	relocate()
	if state.item and state.item.commodity then
		qtyBox:SetText(tostring(state.item.count + (state.item.bank or 0)))
	end
end)
RAH.On("POSTED", function () if panel:IsShown() then loadBank() end end)

RAH.On("READY", function ()
	if panel:IsShown() then updatePostButton(); loadBank() end
end)

RAH.On("MONEY", function () if panel:IsShown() then updatePostButton() end end)

RAH.On("CLOSED", function () Sell.Clear(); state.bank = {} end)

RAH.On("ITEM_INFO", function ()
	if panel:IsShown() then
		RAH.Debounce("sell-items", 0.2, function ()
			auctionList:Refresh()
			-- Reagent-bank-only rows appear once their item info arrives.
			if next(state.bank) then refreshBags() end
		end)
	end
end)

panel:SetScript("OnShow", function ()
	for _, key in ipairs({ "ITEM_SOULBOUND", "ITEM_BIND_QUEST", "ITEM_CONJURED", "ITEM_ACCOUNTBOUND", "ITEM_BIND_TO_ACCOUNT" }) do
		if _G[key] then NOT_POSTABLE[_G[key]] = true end
	end
	refreshBags()
	loadBank()
	if state.item then relocate(); loadListings() else showForm(nil) end
end)
