-- Buy tab: search bar, filters, categories, grouped results and the two item views retail has:
-- commodities (buy any quantity at the cheapest prices) and everything else (pick an auction).

local RAH = RetailAH

local panel = RAH.AddTab("Buy")
local STAR = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1"
local STAR_INLINE = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:12:12:0:0|t "

local Buy = {}
RAH.Buy = Buy

local state = {
	name = "",
	node = nil,       -- selected category
	lastQuery = nil,  -- "search" or "favorites"
	results = {},
	searchReq = nil,
	detail = nil,     -- the group being looked at
	detailReq = nil,
	quote = nil,      -- { quantity, found, total }
	selectedAuction = nil,
}

-----------------------------------------
-- search row

local favButton = RAH.CreateIconButton(panel, STAR, 22)
favButton:SetPoint("TOPLEFT", panel, "TOPLEFT", 2, -2)
favButton:SetScript("OnEnter", function (self)
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:AddLine("Favorites")
	GameTooltip:AddLine("Show the items you've starred.", 1, 1, 1)
	GameTooltip:Show()
end)
favButton:SetScript("OnLeave", function () GameTooltip:Hide() end)

local searchBox = RAH.CreateEditBox(panel, 330)
searchBox:SetPoint("LEFT", favButton, "RIGHT", 12, 0)
searchBox:SetMaxLetters(60)
local placeholder = searchBox:CreateFontString(nil, "OVERLAY", "GameFontDisable")
placeholder:SetPoint("LEFT", searchBox, "LEFT", 2, 0)
placeholder:SetText(SEARCH or "Search")
local function updatePlaceholder()
	if searchBox:GetText() == "" and not searchBox:HasFocus() then placeholder:Show() else placeholder:Hide() end
end
searchBox:SetScript("OnEditFocusGained", updatePlaceholder)
searchBox:SetScript("OnEditFocusLost", updatePlaceholder)
searchBox:SetScript("OnTextChanged", updatePlaceholder)

local filterButton = RAH.CreateButton(panel, "Filters", 90, 22)
filterButton:SetPoint("LEFT", searchBox, "RIGHT", 8, 0)

local searchButton = RAH.CreateButton(panel, SEARCH or "Search", 100, 22)
searchButton:SetPoint("LEFT", filterButton, "RIGHT", 6, 0)

local resultCount = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
resultCount:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -4, -8)
resultCount:SetJustifyH("RIGHT")

-----------------------------------------
-- filter panel

local filters = CreateFrame("Frame", nil, panel)
filters:SetSize(220, 262)
filters:SetPoint("TOPLEFT", filterButton, "BOTTOMLEFT", 0, -4)
filters:SetFrameStrata("DIALOG")
filters:SetBackdrop({
	bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
filters:SetBackdropColor(0.05, 0.05, 0.06, 0.97)
filters:SetBackdropBorderColor(0.6, 0.6, 0.65, 1)
filters:EnableMouse(true)
filters:Hide()

local usableCheck = RAH.CreateCheck(filters, "Usable only")
usableCheck:SetPoint("TOPLEFT", filters, "TOPLEFT", 10, -10)
local exactCheck = RAH.CreateCheck(filters, "Exact match")
exactCheck:SetPoint("TOPLEFT", usableCheck, "BOTTOMLEFT", 0, 2)

local levelLabel = RAH.CreateLabel(filters, "Level Range", "GameFontNormalSmall")
levelLabel:SetPoint("TOPLEFT", exactCheck, "BOTTOMLEFT", 4, -8)
local minLevel = RAH.CreateEditBox(filters, 36, true)
minLevel:SetMaxLetters(2)
minLevel:SetPoint("TOPLEFT", levelLabel, "BOTTOMLEFT", 4, -4)
local dash = RAH.CreateLabel(filters, "-", "GameFontHighlight")
dash:SetPoint("LEFT", minLevel, "RIGHT", 6, 0)
local maxLevel = RAH.CreateEditBox(filters, 36, true)
maxLevel:SetMaxLetters(2)
maxLevel:SetPoint("LEFT", minLevel, "RIGHT", 20, 0)

local rarityLabel = RAH.CreateLabel(filters, RARITY or "Rarity", "GameFontNormalSmall")
rarityLabel:SetPoint("TOPLEFT", minLevel, "BOTTOMLEFT", -4, -10)
local rarityChecks = {}
for i, q in ipairs(RAH.QUALITIES) do
	local cb = RAH.CreateCheck(filters, q[2])
	local r, g, b = RAH.QualityColor(q[1])
	cb.label:SetTextColor(r, g, b)
	cb.quality = q[1]
	if i % 2 == 1 then
		cb:SetPoint("TOPLEFT", i == 1 and rarityLabel or rarityChecks[i - 2], "BOTTOMLEFT", i == 1 and -4 or 0, i == 1 and -2 or 4)
	else
		cb:SetPoint("LEFT", rarityChecks[i - 1], "RIGHT", 80, 0)
	end
	rarityChecks[i] = cb
end

local resetFilters = RAH.CreateButton(filters, "Reset", 80, 20)
resetFilters:SetPoint("BOTTOMRIGHT", filters, "BOTTOMRIGHT", -10, 10)

local function saveFilters()
	local f = RetailAHDB.filters
	f.usable = usableCheck:GetChecked() and true or nil
	f.exact = exactCheck:GetChecked() and true or nil
	f.minLevel = tonumber(minLevel:GetText())
	f.maxLevel = tonumber(maxLevel:GetText())
	f.qualities = {}
	for _, cb in ipairs(rarityChecks) do
		if cb:GetChecked() then f.qualities[cb.quality] = true end
	end
end

local function loadFilters()
	local f = RetailAHDB.filters
	usableCheck:SetChecked(f.usable)
	exactCheck:SetChecked(f.exact)
	minLevel:SetText(f.minLevel and tostring(f.minLevel) or "")
	maxLevel:SetText(f.maxLevel and tostring(f.maxLevel) or "")
	for _, cb in ipairs(rarityChecks) do cb:SetChecked(f.qualities and f.qualities[cb.quality]) end
end

local function filtersActive()
	local f = RetailAHDB.filters
	if f.usable or f.exact or f.minLevel or f.maxLevel then return true end
	return f.qualities and next(f.qualities) ~= nil
end

local function updateFilterButton()
	filterButton:SetText(filtersActive() and "|cff00ff00Filters|r" or "Filters")
end

for _, cb in ipairs({ usableCheck, exactCheck, unpack(rarityChecks) }) do
	cb:SetScript("OnClick", function () saveFilters(); updateFilterButton() end)
end
for _, eb in ipairs({ minLevel, maxLevel }) do
	eb:SetScript("OnTextChanged", function () saveFilters(); updateFilterButton() end)
end
resetFilters:SetScript("OnClick", function ()
	RetailAHDB.filters = {}
	loadFilters()
	updateFilterButton()
end)
filterButton:SetScript("OnClick", function ()
	if filters:IsShown() then filters:Hide() else loadFilters(); filters:Show() end
end)

-----------------------------------------
-- categories

local categoryPane = RAH.CreateInset(panel)
categoryPane:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -30)
categoryPane:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 0)
categoryPane:SetWidth(176)

local CATEGORY_ROW = 20
local CATEGORY_ROWS = 21
local expanded = {}
local flat = {}

local function flatten()
	wipe(flat)
	local function walk(nodes, depth)
		for _, n in ipairs(nodes) do
			table.insert(flat, { node = n, depth = depth })
			if n.children and expanded[n] then walk(n.children, depth + 1) end
		end
	end
	walk(RAH.CATEGORIES, 0)
end

local categoryScrollName = RAH.UniqueName("CategoryScroll")
local categoryScroll = CreateFrame("ScrollFrame", categoryScrollName, categoryPane, "FauxScrollFrameTemplate")
categoryScroll:SetPoint("TOPLEFT", categoryPane, "TOPLEFT", 4, -4)
categoryScroll:SetPoint("BOTTOMRIGHT", categoryPane, "BOTTOMRIGHT", -24, 4)

local categoryButtons = {}
local refreshCategories

-- Clicking the selected category again clears it (and folds it), so a name search covers
-- every category again.
local function selectNode(n, depth)
	if state.node == n then
		state.node = nil
		expanded[n] = nil
	else
		if depth == 0 then
			for _, other in ipairs(RAH.CATEGORIES) do if other ~= n then expanded[other] = nil end end
		end
		state.node = n
		if n.children then expanded[n] = true end
	end
	refreshCategories()
	Buy.Search()
end

local D = RAH.Dragon()
for i = 1, CATEGORY_ROWS do
	local btn = CreateFrame("Button", nil, categoryPane)
	btn:SetHeight(CATEGORY_ROW)
	btn:SetPoint("TOPLEFT", categoryPane, "TOPLEFT", 6, -6 - (i - 1) * CATEGORY_ROW)
	btn:SetPoint("RIGHT", categoryPane, "RIGHT", -26, 0)
	if D then
		local function piece(atlas, w)
			local tex = btn:CreateTexture(nil, "BACKGROUND")
			D:SafeSetAtlas(tex, atlas)
			if w then tex:SetSize(w, CATEGORY_ROW) end
			return tex
		end
		local l = piece("options_listexpand_left", 12 * CATEGORY_ROW / 26)
		l:SetPoint("LEFT", btn, "LEFT")
		local r = piece("options_listexpand_right", 28 * CATEGORY_ROW / 26)
		r:SetPoint("RIGHT", btn, "RIGHT")
		local m = piece("_options_listexpand_middle")
		m:SetPoint("TOPLEFT", l, "TOPRIGHT")
		m:SetPoint("BOTTOMRIGHT", r, "BOTTOMLEFT")
		btn.bar = { l, m, r }
	else
		local bar = RAH.Solid(btn, "BACKGROUND", 0.2, 0.2, 0.24, 0.9)
		bar:SetAllPoints(btn)
		btn.bar = { bar }
	end
	btn.selected = RAH.Solid(btn, "BORDER", 0.25, 0.55, 1, 0.3)
	btn.selected:SetAllPoints(btn)
	local hl = btn:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints(btn)
	hl:SetTexture(1, 1, 1, 0.1)
	btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	btn.text:SetJustifyH("LEFT")
	btn.text:SetPoint("RIGHT", btn, "RIGHT", -6, 0)
	btn:SetScript("OnClick", function (self) if self.entry then selectNode(self.entry.node, self.entry.depth) end end)
	btn:SetScript("OnEnter", function (self)
		if self.entry and state.node == self.entry.node then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine("Click again to search all categories.", 1, 1, 1)
			GameTooltip:Show()
		end
	end)
	btn:SetScript("OnLeave", function () GameTooltip:Hide() end)
	categoryButtons[i] = btn
end

function refreshCategories()
	flatten()
	FauxScrollFrame_Update(categoryScroll, #flat, CATEGORY_ROWS, CATEGORY_ROW)
	local offset = FauxScrollFrame_GetOffset(categoryScroll)
	for i, btn in ipairs(categoryButtons) do
		local entry = flat[offset + i]
		btn.entry = entry
		if entry then
			local n, depth = entry.node, entry.depth
			btn.text:ClearAllPoints()
			btn.text:SetPoint("LEFT", btn, "LEFT", 8 + depth * 10, 0)
			btn.text:SetPoint("RIGHT", btn, "RIGHT", -6, 0)
			btn.text:SetText(n.name)
			if depth == 0 then
				btn.text:SetFontObject(GameFontNormalSmall)
			else
				btn.text:SetFontObject(GameFontHighlightSmall)
			end
			local alpha = depth == 0 and 1 or (depth == 1 and 0.45 or 0)
			for _, tex in ipairs(btn.bar) do tex:SetAlpha(alpha) end
			if state.node == n then btn.selected:Show() else btn.selected:Hide() end
			btn:Show()
		else
			btn:Hide()
		end
	end
end
categoryScroll:SetScript("OnVerticalScroll", function (self, offset)
	FauxScrollFrame_OnVerticalScroll(self, offset, CATEGORY_ROW, refreshCategories)
end)

-----------------------------------------
-- results

local resultsPane = RAH.CreateInset(panel)
resultsPane:SetPoint("TOPLEFT", categoryPane, "TOPRIGHT", 6, 0)
resultsPane:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)

local function itemName(entry)
	local info = RAH.Item(entry)
	if not info then return "|cff808080Loading...|r" end
	local _, _, _, hex = RAH.QualityColor(info.quality)
	return (RAH.IsFavorite(entry) and STAR_INLINE or "") .. hex .. info.name .. "|r"
end

local function itemIcon(entry)
	local info = RAH.Item(entry)
	return info and info.texture
end

local function sortName(entry)
	local info = RAH.Item(entry)
	return info and info.name or "~"
end

local function sortLevel(entry)
	local info = RAH.Item(entry)
	return info and info.itemLevel or 0
end

local results = RAH.CreateList(resultsPane, {
	rows = 20,
	columns = {
		{ title = "Price", width = 140, align = "RIGHT", defaultDesc = false,
			text = function (g)
				if g.auctions == 0 then return "|cff808080--|r" end
				local text = RAH.Money(g.price)
				if bit.band(g.flags, RAH.GROUP_BID_ONLY) ~= 0 then text = "|cffa0a0a0Bid|r " .. text end
				return text
			end,
			sort = function (g) return g.auctions > 0 and g.price or math.huge end },
		{ title = "Name", icon = function (g) return itemIcon(g.entry) end,
			text = function (g) return itemName(g.entry) end,
			sort = function (g) return sortName(g.entry) end },
		{ title = "Level", width = 60, align = "CENTER", defaultDesc = true,
			text = function (g) local l = sortLevel(g.entry); return l > 0 and tostring(l) or "" end,
			sort = function (g) return sortLevel(g.entry) end },
		{ title = "Available", width = 100, align = "RIGHT", defaultDesc = true,
			text = function (g)
				local n = bit.band(g.flags, RAH.GROUP_COMMODITY) ~= 0 and g.units or g.auctions
				return RAH.Number(n)
			end,
			sort = function (g) return bit.band(g.flags, RAH.GROUP_COMMODITY) ~= 0 and g.units or g.auctions end },
	},
	defaultSort = 1,
	link = function (g) return "item:" .. g.entry end,
	onClick = function (g, button)
		if button == "RightButton" then
			RAH.SetFavorite(g.entry, not RAH.IsFavorite(g.entry))
		elseif IsModifiedClick("CHATLINK") then
			local info = RAH.Item(g.entry)
			if info then ChatEdit_InsertLink(info.link) end
		elseif IsModifiedClick("DRESSUP") then
			local info = RAH.Item(g.entry)
			if info then DressUpItemLink(info.link) end
		elseif g.auctions > 0 then
			Buy.OpenDetail(g)
		end
	end,
	tooltipExtra = function (g, tip)
		tip:AddLine(" ")
		tip:AddLine("Right-click to " .. (RAH.IsFavorite(g.entry) and "remove from" or "add to") .. " favorites", 0.5, 0.8, 1)
	end,
	empty = "Search for items, or pick a category.",
})
results:SetPoint("TOPLEFT", resultsPane, "TOPLEFT", 4, -4)
results:SetPoint("BOTTOMRIGHT", resultsPane, "BOTTOMRIGHT", -4, 4)

local function showResults(rows, truncated, emptyText)
	state.results = {}
	for i, r in ipairs(rows) do
		table.insert(state.results, { entry = r[1], price = r[2], units = r[3], auctions = r[4], flags = r[5], order = i })
	end
	results:SetEmptyText(emptyText or "No items found.")
	results:SetItems(state.results)
	if truncated then
		resultCount:SetText("|cffff8000First " .. #rows .. " items; narrow the search to see more|r")
	elseif state.lastQuery == "favorites" then
		resultCount:SetText(#rows .. " favorites")
	else
		local text = #rows == 1 and "1 item" or (#rows .. " items")
		if state.node then
			text = text .. " in |cffffd200" .. state.node.name .. "|r"
		end
		resultCount:SetText(text)
	end
end

function Buy.Search()
	if not RAH.serverReady then return end
	Buy.CloseDetail()
	filters:Hide()
	searchBox:ClearFocus()
	state.lastQuery = "search"
	local f = RetailAHDB.filters
	local flags = (f.usable and 1 or 0) + (f.exact and 2 or 0)
	local mask = 0
	if f.qualities then
		for q in pairs(f.qualities) do mask = mask + bit.lshift(1, q) end
	end
	local n = state.node
	local name = searchBox:GetText():gsub("^%s+", ""):gsub("%s+$", "")

	resultCount:SetText("Searching...")
	-- Answers to a superseded search are dropped.
	local token = {}
	state.searchReq = token
	RAH.Request("S", {
		flags, f.minLevel or 0, f.maxLevel or 0, mask,
		n and n.class or -1, n and n.subclass or -1, n and n.invtype or -1, name,
	}, function (result, err)
		if state.searchReq ~= token then return end
		if err then
			resultCount:SetText("")
			RAH.Status(err == "far" and "You're too far from the auctioneer." or "Search failed; try again.", true)
			return
		end
		showResults(result.rows, result.meta[2] == "1")
	end)
end

function Buy.ShowFavorites()
	if not RAH.serverReady then return end
	Buy.CloseDetail()
	state.lastQuery = "favorites"
	state.node = nil
	refreshCategories()
	local favs = RAH.Favorites()
	if #favs == 0 then
		showResults({}, false, "No favorites yet. Right-click a result, or click the star on an item, to add one.")
		return
	end

	-- The server takes up to 30 per request.
	local rows, pendingChunks, token = {}, 0, {}
	state.searchReq = token
	resultCount:SetText("Loading favorites...")
	for i = 1, #favs, 30 do
		local chunk = {}
		for j = i, math.min(i + 29, #favs) do table.insert(chunk, favs[j]) end
		pendingChunks = pendingChunks + 1
		RAH.Request("F", { table.concat(chunk, ",") }, function (result, err)
			if state.searchReq ~= token then return end
			if result then
				for _, r in ipairs(result.rows) do table.insert(rows, r) end
			end
			pendingChunks = pendingChunks - 1
			if pendingChunks == 0 then showResults(rows, false) end
		end)
	end
end

searchButton:SetScript("OnClick", function () Buy.Search() end)
searchBox:SetScript("OnEnterPressed", function (self) self:ClearFocus(); Buy.Search() end)
favButton:SetScript("OnClick", function () Buy.ShowFavorites() end)

-----------------------------------------
-- item detail (shared top bar)

local detail = RAH.CreateInset(panel)
detail:SetPoint("TOPLEFT", resultsPane, "TOPLEFT")
detail:SetPoint("BOTTOMRIGHT", resultsPane, "BOTTOMRIGHT")
detail:SetFrameLevel(resultsPane:GetFrameLevel() + 5)
detail:EnableMouse(true)
detail:Hide()

local back = RAH.CreateButton(detail, "< Back", 70, 22)
back:SetPoint("TOPLEFT", detail, "TOPLEFT", 8, -8)
back:SetScript("OnClick", function () Buy.CloseDetail() end)

local detailIcon = RAH.CreateItemButton(detail, 34)
detailIcon:SetPoint("LEFT", back, "RIGHT", 12, -6)
detailIcon:SetScript("OnEnter", function (self)
	if state.detail then
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetHyperlink("item:" .. state.detail.entry)
		GameTooltip:Show()
	end
end)
detailIcon:SetScript("OnLeave", function () GameTooltip:Hide() end)

local detailName = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
detailName:SetPoint("LEFT", detailIcon, "RIGHT", 10, 0)
detailName:SetJustifyH("LEFT")

local detailFav = RAH.CreateIconButton(detail, STAR, 20)
detailFav:SetPoint("LEFT", detailName, "RIGHT", 8, 0)
detailFav:SetScript("OnClick", function ()
	if state.detail then RAH.SetFavorite(state.detail.entry, not RAH.IsFavorite(state.detail.entry)) end
end)
detailFav:SetScript("OnEnter", function (self)
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:AddLine(state.detail and RAH.IsFavorite(state.detail.entry) and "Remove from favorites" or "Add to favorites")
	GameTooltip:Show()
end)
detailFav:SetScript("OnLeave", function () GameTooltip:Hide() end)

local refresh = RAH.CreateButton(detail, REFRESH or "Refresh", 80, 22)
refresh:SetPoint("TOPRIGHT", detail, "TOPRIGHT", -8, -8)

local function updateDetailHeader()
	local g = state.detail
	if not g then return end
	local info = RAH.Item(g.entry)
	if info then
		local _, _, _, hex = RAH.QualityColor(info.quality)
		detailName:SetText(hex .. info.name .. "|r")
		detailIcon:SetItem(info.texture, info.quality)
	else
		detailName:SetText("|cff808080Loading...|r")
		detailIcon:SetItem("Interface\\Icons\\INV_Misc_QuestionMark")
	end
	detailFav.icon:SetDesaturated(not RAH.IsFavorite(g.entry))
	detailFav.icon:SetAlpha(RAH.IsFavorite(g.entry) and 1 or 0.5)
end

-----------------------------------------
-- commodity view: pick a quantity, pay the cheapest prices

local commodity = CreateFrame("Frame", nil, detail)
commodity:SetPoint("TOPLEFT", detail, "TOPLEFT", 0, -52)
commodity:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT", 0, 0)

local buyBox = RAH.CreateInset(commodity)
buyBox:SetPoint("TOPLEFT", commodity, "TOPLEFT", 8, 0)
buyBox:SetPoint("BOTTOMLEFT", commodity, "BOTTOMLEFT", 8, 8)
buyBox:SetWidth(230)

local qtyLabel = RAH.CreateLabel(buyBox, "Quantity")
qtyLabel:SetPoint("TOPLEFT", buyBox, "TOPLEFT", 16, -20)
local qtyBox = RAH.CreateEditBox(buyBox, 80, true)
qtyBox:SetMaxLetters(6)
qtyBox:SetPoint("TOPRIGHT", buyBox, "TOPRIGHT", -16, -16)

local unitLabel = RAH.CreateLabel(buyBox, "Unit Price", "GameFontNormalSmall")
unitLabel:SetPoint("TOPLEFT", qtyLabel, "BOTTOMLEFT", 0, -26)
local unitValue = RAH.CreateMoneyText(buyBox, "GameFontHighlight")
unitValue:SetPoint("TOPRIGHT", buyBox, "TOPRIGHT", -16, -66)

local totalLabel = RAH.CreateLabel(buyBox, "Total", "GameFontNormal")
totalLabel:SetPoint("TOPLEFT", unitLabel, "BOTTOMLEFT", 0, -22)
local totalValue = RAH.CreateMoneyText(buyBox, "GameFontHighlightLarge")
totalValue:SetPoint("TOPRIGHT", buyBox, "TOPRIGHT", -16, -98)

local quoteNote = buyBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
quoteNote:SetPoint("TOPLEFT", totalLabel, "BOTTOMLEFT", 0, -14)
quoteNote:SetPoint("RIGHT", buyBox, "RIGHT", -16, 0)
quoteNote:SetJustifyH("LEFT")

local buyNow = RAH.CreateButton(buyBox, "Buy Now", 198, 26)
buyNow:SetPoint("BOTTOM", buyBox, "BOTTOM", 0, 16)

local tiersPane = CreateFrame("Frame", nil, commodity)
tiersPane:SetPoint("TOPLEFT", buyBox, "TOPRIGHT", 8, 0)
tiersPane:SetPoint("BOTTOMRIGHT", commodity, "BOTTOMRIGHT", -8, 8)

local tiers
tiers = RAH.CreateList(tiersPane, {
	rows = 18,
	columns = {
		{ title = "Unit Price", width = 160, align = "RIGHT", text = function (t) return RAH.Money(t.price) end,
			sort = function (t) return t.price end },
		{ title = "Available", align = "RIGHT", text = function (t) return RAH.Number(t.units) end,
			sort = function (t) return t.units end, defaultDesc = true },
		{ title = "Yours", width = 70, align = "RIGHT",
			text = function (t) return t.own > 0 and ("|cff4fc3f7" .. RAH.Number(t.own) .. "|r") or "" end },
	},
	defaultSort = 1,
	-- Clicking a price tier asks for everything up to and including it, as retail does.
	onClick = function (t)
		local sum = 0
		for _, other in ipairs(tiers.items) do
			if other.price <= t.price then sum = sum + other.units - other.own end
		end
		if sum > 0 then
			qtyBox:SetText(tostring(sum))
		end
	end,
	empty = "Nothing listed.",
})
tiers:SetAllPoints(tiersPane)

local function updateQuote()
	local g = state.detail
	local qty = tonumber(qtyBox:GetText()) or 0
	RAH.SetEnabled(buyNow, false)
	if not g or qty <= 0 then
		unitValue:SetText("")
		totalValue:SetText("")
		quoteNote:SetText("")
		state.quote = nil
		return
	end
	quoteNote:SetText("|cff808080Checking prices...|r")
	RAH.Debounce("quote", 0.25, function ()
		local entry = g.entry
		RAH.Request("Q", { entry, qty }, function (result, err)
			if state.detail ~= g or tonumber(qtyBox:GetText()) ~= qty then return end
			if err or not result then quoteNote:SetText("|cffff2020Couldn't get a price.|r") return end
			local found, total, capped = tonumber(result[2]) or 0, tonumber(result[3]) or 0, result[4] == "1"
			state.quote = { quantity = qty, found = found, total = total }
			if found == 0 then
				unitValue:SetText("")
				totalValue:SetText("")
				quoteNote:SetText("|cffff2020None available from other sellers.|r")
				return
			end
			unitValue:SetMoney(math.ceil(total / found))
			totalValue:SetMoney(total)
			if found < qty and capped then
				quoteNote:SetText("|cffff2020One purchase can take from at most 100 listings: you can buy "
					.. RAH.Number(found) .. " at once.|r")
			elseif found < qty then
				quoteNote:SetText("|cffff2020Only " .. RAH.Number(found) .. " available.|r")
			elseif total > GetMoney() then
				quoteNote:SetText("|cffff2020You don't have enough money.|r")
			else
				quoteNote:SetText("")
				RAH.SetEnabled(buyNow, true)
			end
		end)
	end)
end
qtyBox:SetScript("OnTextChanged", updateQuote)

local loadDetail

buyNow:SetScript("OnClick", function ()
	local g, q = state.detail, state.quote
	if not (g and q and q.found >= q.quantity) then return end
	local info = RAH.Item(g.entry)
	local text = string.format("Buy %s x %s for %s?", info and info.link or ("item " .. g.entry), RAH.Number(q.quantity), RAH.Money(q.total))
	RAH.Confirm(text, function ()
		RAH.SetEnabled(buyNow, false)
		RAH.QuietChat(4)
		RAH.Request("B", { g.entry, q.quantity, q.total }, function (result, err)
			if err or not result then RAH.Status("Purchase failed.", true) return end
			local status, bought, spent = result[1], tonumber(result[2]) or 0, tonumber(result[3]) or 0
			if status == "ok" then
				RAH.Status("Bought " .. RAH.Number(bought) .. " for " .. RAH.Money(spent) .. ". It's in your mailbox.")
				PlaySound("LOOTWINDOWCOINSOUND")
			elseif status == "partial" then
				RAH.Status("Bought " .. RAH.Number(bought) .. " of " .. RAH.Number(q.quantity) .. " for " .. RAH.Money(spent) .. ".", true)
			elseif status == "price" then
				RAH.Status("Prices changed: that now costs " .. RAH.Money(tonumber(result[5]) or 0) .. ". Check and buy again.", true)
			elseif status == "short" then
				RAH.Status("Only " .. RAH.Number(tonumber(result[4]) or 0) .. " are available now.", true)
			elseif status == "money" then
				RAH.Status(ERR_NOT_ENOUGH_MONEY or "You don't have enough money.", true)
			else
				RAH.Status("Purchase failed.", true)
			end
			if state.detail == g then loadDetail() end
		end)
	end)
end)

-----------------------------------------
-- item view: individual auctions, bid or buy one

local itemView = CreateFrame("Frame", nil, detail)
itemView:SetPoint("TOPLEFT", detail, "TOPLEFT", 0, -52)
itemView:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT", 0, 0)

local function auctionName(a)
	local info = RAH.Item(a.link)
	if not info then return "|cff808080Loading...|r" end
	local _, _, _, hex = RAH.QualityColor(info.quality)
	return hex .. info.name .. "|r" .. (a.count > 1 and ("|cffffffff x" .. a.count .. "|r") or "")
end

local auctions = RAH.CreateList(itemView, {
	rows = 16,
	columns = {
		{ title = "Bid", width = 130, align = "RIGHT",
			text = function (a)
				local text = RAH.Money(a.bid)
				if bit.band(a.flags, RAH.AUCTION_HIGH_BIDDER) ~= 0 then return "|cff20ff20" .. text .. "|r" end
				if bit.band(a.flags, RAH.AUCTION_HAS_BID) == 0 then return "|cffa0a0a0" .. text .. "|r" end
				return text
			end,
			sort = function (a) return a.minBid end },
		{ title = "Buyout", width = 130, align = "RIGHT",
			text = function (a) return a.buyout > 0 and RAH.Money(a.buyout) or "|cff808080--|r" end,
			sort = function (a) return a.buyout > 0 and a.buyout or math.huge end },
		{ title = "Name", icon = function (a) local i = RAH.Item(a.link) return i and i.texture end,
			text = auctionName, sort = function (a) local i = RAH.Item(a.link) return i and i.name or "~" end },
		{ title = "Level", width = 50, align = "CENTER",
			text = function (a) local i = RAH.Item(a.link) return i and tostring(i.itemLevel) or "" end },
		{ title = "Time Left", width = 80, align = "RIGHT", text = function (a) return RAH.TimeLeft(a.timeLeft) end,
			sort = function (a) return a.timeLeft end },
		{ title = "", width = 40, align = "CENTER",
			text = function (a) return bit.band(a.flags, RAH.AUCTION_OWN) ~= 0 and "|cff4fc3f7You|r" or "" end },
	},
	link = function (a) return a.link end,
	isSelected = function (a) return state.selectedAuction == a end,
	onClick = function (a)
		if IsModifiedClick("CHATLINK") then
			local info = RAH.Item(a.link)
			if info then ChatEdit_InsertLink(info.link) end
			return
		elseif IsModifiedClick("DRESSUP") then
			DressUpItemLink(a.link)
			return
		end
		state.selectedAuction = a
		Buy.UpdateAuctionButtons()
	end,
	empty = "Nothing listed.",
})
auctions:SetPoint("TOPLEFT", itemView, "TOPLEFT", 8, 0)
auctions:SetPoint("BOTTOMRIGHT", itemView, "BOTTOMRIGHT", -8, 40)

local bidLabel = RAH.CreateLabel(itemView, "Bid", "GameFontNormal")
local bidInput = RAH.CreateMoneyInput(itemView)
bidInput:SetPoint("BOTTOMLEFT", itemView, "BOTTOMLEFT", 60, 12)
bidLabel:SetPoint("RIGHT", bidInput, "LEFT", -10, 0)

local bidButton = RAH.CreateButton(itemView, "Bid", 100, 24)
bidButton:SetPoint("LEFT", bidInput, "RIGHT", 16, 0)
local buyoutButton = RAH.CreateButton(itemView, "Buy Now", 120, 24)
buyoutButton:SetPoint("BOTTOMRIGHT", itemView, "BOTTOMRIGHT", -12, 10)

function Buy.UpdateAuctionButtons()
	local a = state.selectedAuction
	local own = a and bit.band(a.flags, RAH.AUCTION_OWN) ~= 0
	local canBid = a and not own and bit.band(a.flags, RAH.AUCTION_HIGH_BIDDER) == 0 and (a.buyout == 0 or a.minBid < a.buyout)
	local canBuy = a and not own and a.buyout > 0
	RAH.SetEnabled(bidButton, canBid and GetMoney() >= a.minBid)
	RAH.SetEnabled(buyoutButton, canBuy and GetMoney() >= a.buyout)
	if a then bidInput:SetCopper(a.minBid) end
	auctions:Refresh()
end

local function placeBid(a, price, verb)
	local info = RAH.Item(a.link)
	local text = string.format("%s %s for %s?", verb, info and info.link or "this item", RAH.Money(price))
	RAH.Confirm(text, function ()
		RAH.QuietChat(3)
		RAH.Request("P", { a.id, price }, function (result, err)
			local status = result and result[1]
			if status == "bought" then
				RAH.Status("Bought " .. (info and info.link or "the item") .. ". It's in your mailbox.")
				PlaySound("LOOTWINDOWCOINSOUND")
			elseif status == "bid" then
				RAH.Status("Bid placed. You'll get a mail if you're outbid.")
			elseif status == "gone" then
				RAH.Status(ERR_AUCTION_ITEM_NOT_FOUND or "That auction is gone.", true)
			else
				RAH.Status("That didn't go through.", true)
			end
			state.selectedAuction = nil
			loadDetail()
		end)
	end)
end

bidButton:SetScript("OnClick", function ()
	local a = state.selectedAuction
	if not a then return end
	local price = bidInput:GetCopper()
	if price < a.minBid then
		RAH.Status("The bid must be at least " .. RAH.Money(a.minBid) .. ".", true)
		return
	end
	if a.buyout > 0 and price >= a.buyout then
		placeBid(a, a.buyout, "Buy")
	else
		placeBid(a, price, "Bid on")
	end
end)
buyoutButton:SetScript("OnClick", function ()
	local a = state.selectedAuction
	if a then placeBid(a, a.buyout, "Buy") end
end)

-----------------------------------------
-- opening and loading an item

function loadDetail()
	local g = state.detail
	if not g then return end
	updateDetailHeader()
	local commodityItem = bit.band(g.flags, RAH.GROUP_COMMODITY) ~= 0
	local token = {}
	state.detailReq = token

	if commodityItem then
		RAH.Request("C", { g.entry }, function (result, err)
			if state.detailReq ~= token or not result then return end
			local list = {}
			for i, r in ipairs(result.rows) do
				table.insert(list, { price = r[1], units = r[2], own = r[3], order = i })
			end
			tiers:SetItems(list, true)
			updateQuote()
		end)
	else
		RAH.Request("I", { g.entry }, function (result, err)
			if state.detailReq ~= token or not result then return end
			local list, selectedId = {}, state.selectedAuction and state.selectedAuction.id
			state.selectedAuction = nil
			for i, r in ipairs(result.rows) do
				local a = {
					id = r[1], count = r[2], bid = r[3], minBid = r[4], buyout = r[5], timeLeft = r[6], flags = r[7],
					link = RAH.ItemString(g.entry, r[8], r[9]), order = i,
				}
				if a.id == selectedId then state.selectedAuction = a end
				table.insert(list, a)
			end
			auctions:SetItems(list, true)
			Buy.UpdateAuctionButtons()
		end)
	end
end

function Buy.OpenDetail(g)
	state.detail = g
	state.quote = nil
	state.selectedAuction = nil
	local commodityItem = bit.band(g.flags, RAH.GROUP_COMMODITY) ~= 0
	if commodityItem then
		commodity:Show(); itemView:Hide()
		tiers:SetItems({})
		qtyBox:SetText("1")
	else
		commodity:Hide(); itemView:Show()
		auctions:SetItems({})
		bidInput:SetCopper(0)
		Buy.UpdateAuctionButtons()
	end
	detail:Show()
	loadDetail()
end

function Buy.CloseDetail()
	state.detail = nil
	state.detailReq = nil
	detail:Hide()
end

refresh:SetScript("OnClick", function () loadDetail() end)

-----------------------------------------

RAH.On("ITEM_INFO", function ()
	if not panel:IsShown() then return end
	RAH.Debounce("buy-items", 0.2, function ()
		results:Refresh()
		if detail:IsShown() then
			updateDetailHeader()
			auctions:Refresh()
		end
	end)
end)

RAH.On("FAVORITES", function ()
	results:Refresh()
	updateDetailHeader()
	if state.lastQuery == "favorites" and not detail:IsShown() then Buy.ShowFavorites() end
end)

RAH.On("MONEY", function ()
	if detail:IsShown() then
		if state.selectedAuction then Buy.UpdateAuctionButtons() end
		if state.quote then updateQuote() end
	end
end)

-- A fresh visit starts on the favorites, like retail, or the prompt if there are none.
RAH.On("READY", function ()
	state.node = nil
	expanded = {}
	refreshCategories()
	Buy.CloseDetail()
	if next(RetailAHDB.favorites) then
		Buy.ShowFavorites()
	else
		showResults({}, false, "Search for items, or pick a category.")
		resultCount:SetText("")
	end
end)

RAH.On("CLOSED", function ()
	filters:Hide()
	state.searchReq = nil
	Buy.CloseDetail()
end)

panel:SetScript("OnShow", function ()
	refreshCategories()
	updateFilterButton()
	updatePlaceholder()
end)
panel:SetScript("OnHide", function () filters:Hide() end)
