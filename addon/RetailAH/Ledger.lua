-- Ledger tab: whether the auction house makes or loses you money. The server writes down every
-- auction that ends for you (sold, bought, expired, cancelled); this tab shows the list or the
-- totals per item, for a period, for this character or the whole account.
-- Profit, not cash flow: a deposit only counts when it's lost, a sale counts after the cut.

local RAH = RetailAH

local panel = RAH.AddTab("Ledger")

local state = { view = 0, days = 7, account = false, req = nil }

local VIEWS = { { 0, "History" }, { 1, "By Item" } }
local PERIODS = { { 1, "Today" }, { 7, "7 Days" }, { 30, "30 Days" }, { 0, "All Time" } }

local KINDS = {
	[1] = "|cff20ff20Sold|r",
	[2] = "|cffffd200Bought|r",
	[3] = "|cff808080Expired|r",
	[4] = "|cffff8000Cancelled|r",
}

local floor, abs = math.floor, math.abs

-- +1g 20s in green, -50s in red, 0 plain.
local function signed(copper)
	copper = tonumber(copper) or 0
	if copper > 0 then return "|cff20ff20+" .. RAH.Money(copper) .. "|r" end
	if copper < 0 then return "|cffff4040-" .. RAH.Money(-copper) .. "|r" end
	return RAH.Money(0)
end

local function ago(seconds)
	seconds = tonumber(seconds) or 0
	if seconds < 60 then return "just now" end
	if seconds < 3600 then return floor(seconds / 60) .. "m ago" end
	if seconds < 86400 then return floor(seconds / 3600) .. "h ago" end
	return floor(seconds / 86400) .. "d ago"
end

local function who(name)
	if name == "*" then return "|cff4fc3f7AH bot|r" end
	if name == "-" or name == nil then return "" end
	return tostring(name)
end

-----------------------------------------
-- top row: view, period, account

local viewButtons, periodButtons = {}, {}
local load

for i, v in ipairs(VIEWS) do
	local btn = RAH.CreateButton(panel, v[2], 90, 22)
	btn.value = v[1]
	if i == 1 then
		btn:SetPoint("TOPLEFT", panel, "TOPLEFT", 2, -2)
	else
		btn:SetPoint("LEFT", viewButtons[i - 1], "RIGHT", 6, 0)
	end
	viewButtons[i] = btn
end

for i, p in ipairs(PERIODS) do
	local btn = RAH.CreateButton(panel, p[2], 76, 22)
	btn.value = p[1]
	if i == 1 then
		btn:SetPoint("LEFT", viewButtons[#viewButtons], "RIGHT", 24, 0)
	else
		btn:SetPoint("LEFT", periodButtons[i - 1], "RIGHT", 4, 0)
	end
	periodButtons[i] = btn
end

local accountCheck = RAH.CreateCheck(panel, "All characters")
accountCheck:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -100, -1)

local pane = RAH.CreateInset(panel)
pane:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -30)
pane:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 36)

-----------------------------------------
-- lists

local function itemLink(r) return "item:" .. r.entry end
local function itemIcon(r) return RAH.ItemIcon(r.entry) end
local function itemSort(r) local info = RAH.Item(r.entry) return info and info.name or "~" end
local function itemText(r, count)
	local info = RAH.Item(r.entry)
	if not info then return "|cff808080Loading...|r" end
	local _, _, _, hex = RAH.QualityColor(info.quality)
	return hex .. info.name .. "|r" .. (count and count > 1 and ("|cffffffff x" .. RAH.Number(count) .. "|r") or "")
end

-- The sum behind a row, on its tooltip.
local function historyTip(r, tip)
	tip:AddLine(" ")
	if r.kind == 1 then
		tip:AddDoubleLine("Sold for", RAH.Money(r.gross), 1, 1, 1, 1, 1, 1)
		tip:AddDoubleLine("House cut", "-" .. RAH.Money(r.fee), 1, 1, 1, 1, 0.3, 0.3)
	elseif r.kind == 2 then
		tip:AddDoubleLine("Paid", RAH.Money(r.gross), 1, 1, 1, 1, 1, 1)
	elseif r.kind == 3 then
		tip:AddDoubleLine("Deposit lost", "-" .. RAH.Money(r.fee), 1, 1, 1, 1, 0.3, 0.3)
	else
		tip:AddDoubleLine("Deposit and cut lost", "-" .. RAH.Money(r.fee), 1, 1, 1, 1, 0.3, 0.3)
	end
	if who(r.other) ~= "" then
		tip:AddDoubleLine(r.kind == 2 and "Seller" or "Buyer", who(r.other), 1, 1, 1, 1, 1, 1)
	end
end

local function historyColumns(withCharacter)
	local columns = {
		{ title = "When", width = 76, text = function (r) return "|cffa0a0a0" .. ago(r.age) .. "|r" end,
			sort = function (r) return r.age end },
		{ title = "Item", icon = itemIcon, text = function (r) return itemText(r, r.count) end, sort = itemSort },
		{ title = "Type", width = 80, align = "CENTER", text = function (r) return KINDS[r.kind] or "?" end,
			sort = function (r) return r.kind end },
		{ title = "With", width = 100, text = function (r) return who(r.other) end,
			sort = function (r) return r.other == "*" and "" or tostring(r.other) end },
	}
	if withCharacter then
		table.insert(columns, { title = "Character", width = 90, text = function (r) return who(r.character) end,
			sort = function (r) return tostring(r.character) end })
	end
	table.insert(columns, { title = "Amount", width = 130, align = "RIGHT", text = function (r) return signed(r.amount) end,
		sort = function (r) return r.amount end })
	return columns
end

local EMPTY = "Nothing in this period. Sales, purchases, expired and cancelled auctions show up here."

local function makeList(columns, defaultSort, tooltipExtra)
	local list = RAH.CreateList(pane, {
		rows = 19,
		columns = columns,
		defaultSort = defaultSort,
		link = itemLink,
		tooltipExtra = tooltipExtra,
		empty = EMPTY,
	})
	list:SetPoint("TOPLEFT", pane, "TOPLEFT", 4, -4)
	list:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -4, 4)
	list:Hide()
	return list
end

local historyList = makeList(historyColumns(false), 1, historyTip)
local accountHistoryList = makeList(historyColumns(true), 1, historyTip)

local itemList = makeList({
	{ title = "Item", icon = itemIcon, text = function (r) return itemText(r) end, sort = itemSort },
	{ title = "Sold", width = 60, align = "RIGHT", text = function (r) return r.sold > 0 and RAH.Number(r.sold) or "" end,
		sort = function (r) return r.sold end },
	{ title = "Income", width = 120, align = "RIGHT", text = function (r) return r.income > 0 and RAH.Money(r.income) or "" end,
		sort = function (r) return r.income end },
	{ title = "Bought", width = 60, align = "RIGHT", text = function (r) return r.bought > 0 and RAH.Number(r.bought) or "" end,
		sort = function (r) return r.bought end },
	{ title = "Spent", width = 120, align = "RIGHT", text = function (r) return r.spent > 0 and RAH.Money(r.spent) or "" end,
		sort = function (r) return r.spent end },
	{ title = "Net", width = 130, align = "RIGHT", text = function (r) return signed(r.net) end,
		sort = function (r) return r.net end },
}, 6, function (r, tip)
	tip:AddLine(" ")
	if r.sold > 0 then tip:AddDoubleLine("Sold " .. RAH.Number(r.sold) .. ", after the cut", RAH.Money(r.income), 1, 1, 1, 1, 1, 1) end
	if r.bought > 0 then tip:AddDoubleLine("Bought " .. RAH.Number(r.bought), "-" .. RAH.Money(r.spent), 1, 1, 1, 1, 0.3, 0.3) end
	if r.lost > 0 then tip:AddDoubleLine("Deposits and fees lost", "-" .. RAH.Money(r.lost), 1, 1, 1, 1, 0.3, 0.3) end
	tip:AddDoubleLine("Last", ago(r.age), 1, 1, 1, 0.7, 0.7, 0.7)
end)
-- Best earners first.
itemList.sortDesc = true

local function currentList()
	if state.view == 1 then return itemList end
	return state.account and accountHistoryList or historyList
end

-----------------------------------------
-- totals along the bottom

local totals = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
totals:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 6, 14)
totals:SetPoint("RIGHT", panel, "RIGHT", -230, 0)
totals:SetJustifyH("LEFT")

local net = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
net:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -6, 10)
net:SetJustifyH("RIGHT")

local function showTotals(meta)
	local sales, cut, lost, spent, total = tonumber(meta[1]) or 0, tonumber(meta[2]) or 0, tonumber(meta[3]) or 0,
		tonumber(meta[4]) or 0, tonumber(meta[5]) or 0
	local sold, bought, ended = tonumber(meta[6]) or 0, tonumber(meta[7]) or 0, tonumber(meta[8]) or 0
	local parts = {
		"Sales " .. RAH.Money(sales) .. " |cff808080(" .. sold .. ")|r",
		"Cut |cffff4040-" .. RAH.Money(cut) .. "|r",
		"Fees lost |cffff4040-" .. RAH.Money(lost) .. "|r |cff808080(" .. ended .. ")|r",
		"Bought |cffff4040-" .. RAH.Money(spent) .. "|r |cff808080(" .. bought .. ")|r",
	}
	totals:SetText(table.concat(parts, "   "))
	net:SetText("Net " .. signed(total))
	if meta[9] == "1" then
		RAH.Status("Showing the most recent rows only; the totals cover the whole period.")
	end
end

-----------------------------------------

local function updateButtons()
	for _, btn in ipairs(viewButtons) do RAH.SetEnabled(btn, btn.value ~= state.view) end
	for _, btn in ipairs(periodButtons) do RAH.SetEnabled(btn, btn.value ~= state.days) end
	accountCheck:SetChecked(state.account)
	for _, list in ipairs({ historyList, accountHistoryList, itemList }) do
		if list == currentList() then list:Show() else list:Hide() end
	end
end

function load()
	updateButtons()
	local list = currentList()
	if not RAH.serverReady then return end
	if not RAH.ledger then
		list:SetEmptyText("This realm's server doesn't keep a ledger.")
		list:SetItems({})
		totals:SetText("")
		net:SetText("")
		return
	end
	list:SetEmptyText(EMPTY)

	local token = {}
	state.req = token
	local view = state.view
	RAH.Request("G", { view, state.account and 1 or 0, state.days }, function (result, err)
		if state.req ~= token then return end
		if err or not result then
			RAH.Status("Couldn't load the ledger.", true)
			return
		end
		local rows, items = {}, {}
		for i, r in ipairs(result.rows) do
			local row
			if view == 0 then
				row = { age = r[1], kind = r[2], entry = r[3], count = r[4], gross = r[5], fee = r[6], amount = r[7],
					other = r[8], character = r[9], order = i }
			else
				row = { entry = r[1], sold = r[2], income = r[3], bought = r[4], spent = r[5], lost = r[6], net = r[7],
					age = r[8], order = i }
			end
			table.insert(rows, row)
			table.insert(items, "item:" .. row.entry)
		end
		RAH.Prefetch(items)
		currentList():SetItems(rows)
		showTotals(result.meta)
	end)
end

for _, btn in ipairs(viewButtons) do
	btn:SetScript("OnClick", function (self) state.view = self.value; load() end)
end
for _, btn in ipairs(periodButtons) do
	btn:SetScript("OnClick", function (self)
		state.days = self.value
		RetailAHDB.ledgerDays = self.value
		load()
	end)
end
accountCheck:SetScript("OnClick", function (self)
	state.account = self:GetChecked() and true or false
	RetailAHDB.ledgerAccount = state.account or nil
	load()
end)

RAH.On("ITEM_INFO", function ()
	if panel:IsShown() then
		RAH.Debounce("ledger-items", 0.2, function () currentList():Refresh() end)
	end
end)
RAH.On("READY", function () if panel:IsShown() then load() end end)

panel:SetScript("OnShow", function ()
	state.days = RetailAHDB.ledgerDays or state.days
	state.account = RetailAHDB.ledgerAccount and true or false
	load()
end)
