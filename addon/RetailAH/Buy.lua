-- Buy tab: search bar, filters, categories, grouped results and the two item views retail has:
-- commodities (buy any quantity at the cheapest prices) and everything else (pick an auction).
-- With ReagentBankUI, its shopping list (what recipes are short of) is a view here too.

local RAH = RetailAH

local panel, tabIndex = RAH.AddTab("Buy")
local STAR = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1"
local STAR_INLINE = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:12:12:0:0|t "
-- Transmog pink, as retail uses for appearances.
local NEW_LOOK = "  |cffff80ffnew look|r"
local UNCOLLECTED_TIP = "You haven't collected this appearance"

local Buy = {}
RAH.Buy = Buy

local state = {
	name = "",
	node = nil,       -- selected category
	lastQuery = nil,  -- "search", "favorites" or "shopping"
	results = {},
	searchReq = nil,
	detail = nil,     -- the group being looked at
	detailReq = nil,
	quote = nil,      -- { quantity, found, total }
	selectedAuction = nil,
	tally = { count = 0, spent = 0 },  -- bought since this item was opened
	stacks = false,    -- a commodity shown as its separate stacks, to bid on one
	pickNext = false,  -- select the cheapest buyable listing when the list comes back
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

-- The shopping list, when ReagentBankUI is there to keep one.
local shopButton = RAH.CreateIconButton(panel, "Interface\\Icons\\INV_Misc_Note_01", 22)
shopButton:SetPoint("LEFT", favButton, "RIGHT", 6, 0)
shopButton.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
shopButton.count = shopButton:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
shopButton.count:SetPoint("BOTTOMRIGHT", shopButton, "BOTTOMRIGHT", 2, -2)
shopButton:SetScript("OnEnter", function (self)
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:AddLine("Shopping list")
	GameTooltip:AddLine("What your recipes are short of. Add to it from the profession window; it counts down as you buy.", 1, 1, 1, true)
	GameTooltip:Show()
end)
shopButton:SetScript("OnLeave", function () GameTooltip:Hide() end)
if not RAH.Shopping.Available() then shopButton:Hide() end

local searchBox = RAH.CreateEditBox(panel, RAH.Shopping.Available() and 302 or 330)
searchBox:SetPoint("LEFT", RAH.Shopping.Available() and shopButton or favButton, "RIGHT", 12, 0)
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
resultCount:SetWidth(210)
resultCount:SetHeight(14)

-----------------------------------------
-- filter panel

-- Two columns: the general filters on the left, stats on the right.
local filters = CreateFrame("Frame", nil, panel)
filters:SetSize(430, 284)
filters:SetPoint("TOPLEFT", filterButton, "BOTTOMLEFT", 0, -4)
filters:SetFrameStrata("DIALOG")
-- The stock tooltip look; DragonUI's dark panel when it's there.
filters:SetBackdrop(RAH.TOOLTIP_BACKDROP)
if RAH.Dragon() then
	filters:SetBackdropColor(0.05, 0.05, 0.06, 0.97)
	filters:SetBackdropBorderColor(0.6, 0.6, 0.65, 1)
else
	filters:SetBackdropColor(0, 0, 0, 0.95)
	filters:SetBackdropBorderColor(1, 1, 1, 1)
end
filters:EnableMouse(true)
filters:Hide()

local usableCheck = RAH.CreateCheck(filters, "Usable only")
usableCheck:SetPoint("TOPLEFT", filters, "TOPLEFT", 10, -10)
local exactCheck = RAH.CreateCheck(filters, "Exact match")
exactCheck:SetPoint("TOPLEFT", usableCheck, "BOTTOMLEFT", 0, 2)

local levelLabel = RAH.CreateLabel(filters, "Level Range", "GameFontNormalSmall")
local uncollectedCheck = RAH.CreateCheck(filters, "Uncollected appearances only")
uncollectedCheck:SetPoint("TOPLEFT", exactCheck, "BOTTOMLEFT", 0, 2)
uncollectedCheck.label:SetTextColor(1, 0.5, 1)
uncollectedCheck:SetScript("OnEnter", function (self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine("Uncollected appearances only")
	if RAH.appearances then
		GameTooltip:AddLine("Only gear whose look your account hasn't collected for transmog yet.", 1, 1, 1, true)
	else
		GameTooltip:AddLine("This realm doesn't track transmog collections.", 1, 0.3, 0.3, true)
	end
	GameTooltip:Show()
end)
uncollectedCheck:SetScript("OnLeave", function () GameTooltip:Hide() end)

levelLabel:SetPoint("TOPLEFT", uncollectedCheck, "BOTTOMLEFT", 4, -8)
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

-- stats: the item must have every one that's checked
local statsDivider = RAH.Solid(filters, "ARTWORK", 1, 1, 1, 0.12)
statsDivider:SetWidth(1)
statsDivider:SetPoint("TOPLEFT", filters, "TOPLEFT", 212, -12)
statsDivider:SetPoint("BOTTOMLEFT", filters, "BOTTOMLEFT", 212, 12)

local statsLabel = RAH.CreateLabel(filters, "Stats", "GameFontNormalSmall")
statsLabel:SetPoint("TOPLEFT", filters, "TOPLEFT", 226, -14)
local statsHint = RAH.CreateLabel(filters, "", "GameFontDisableSmall")
statsHint:SetPoint("LEFT", statsLabel, "RIGHT", 8, 0)

local statChecks = {}
for i, label in ipairs(RAH.STATS) do
	local cb = RAH.CreateCheck(filters, label)
	cb.bit = bit.lshift(1, i - 1)
	statChecks[i] = cb
end

-- A stat no gear of the player's progression era has (Resilience before TBC, say) isn't offered.
local function statOffered(cb)
	return not RAH.statsAvailable or bit.band(RAH.statsAvailable, cb.bit) ~= 0
end

-- Two columns of ten, top to bottom, closing up over the stats that aren't offered.
local function layoutStats()
	local shown, first, prev = 0, nil, nil
	for _, cb in ipairs(statChecks) do
		cb:ClearAllPoints()
		if statOffered(cb) then
			shown = shown + 1
			if shown == 1 then
				cb:SetPoint("TOPLEFT", statsLabel, "BOTTOMLEFT", -4, -2)
				first = cb
			elseif shown == 11 then
				cb:SetPoint("LEFT", first, "RIGHT", 80, 0)
			else
				cb:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, 4)
			end
			prev = cb
			cb:Show()
		else
			cb:Hide()
		end
	end
end
layoutStats()

local function statMask()
	if not RAH.statFilters then return 0 end
	local mask = RetailAHDB.filters.stats or 0
	if RAH.statsAvailable then mask = bit.band(mask, RAH.statsAvailable) end
	return mask
end

local resetFilters = RAH.CreateButton(filters, "Reset", 80, 20)
resetFilters:SetPoint("BOTTOMRIGHT", filters, "BOTTOMRIGHT", -10, 10)

local function saveFilters()
	local f = RetailAHDB.filters
	f.usable = usableCheck:GetChecked() and true or nil
	f.exact = exactCheck:GetChecked() and true or nil
	f.uncollected = uncollectedCheck:GetChecked() and true or nil
	f.minLevel = tonumber(minLevel:GetText())
	f.maxLevel = tonumber(maxLevel:GetText())
	f.qualities = {}
	for _, cb in ipairs(rarityChecks) do
		if cb:GetChecked() then f.qualities[cb.quality] = true end
	end
	-- Stats this era doesn't offer keep their saved state: the filters are shared by the
	-- account's characters, and a TBC one may have them ticked.
	local mask = 0
	for _, cb in ipairs(statChecks) do
		if statOffered(cb) then
			if cb:GetChecked() then mask = mask + cb.bit end
		elseif bit.band(f.stats or 0, cb.bit) ~= 0 then
			mask = mask + cb.bit
		end
	end
	f.stats = mask > 0 and mask or nil
end

local function loadFilters()
	local f = RetailAHDB.filters
	usableCheck:SetChecked(f.usable)
	exactCheck:SetChecked(f.exact)
	uncollectedCheck:SetChecked(f.uncollected and RAH.appearances)
	RAH.SetEnabled(uncollectedCheck, RAH.appearances)
	minLevel:SetText(f.minLevel and tostring(f.minLevel) or "")
	maxLevel:SetText(f.maxLevel and tostring(f.maxLevel) or "")
	-- The level gate: nothing past this shows anyway.
	levelLabel:SetText(RAH.levelCap and ("Level Range |cff808080(up to " .. RAH.levelCap .. ")|r") or "Level Range")
	for _, cb in ipairs(rarityChecks) do cb:SetChecked(f.qualities and f.qualities[cb.quality]) end
	layoutStats()
	for _, cb in ipairs(statChecks) do
		cb:SetChecked(RAH.statFilters and statOffered(cb) and bit.band(f.stats or 0, cb.bit) ~= 0)
		RAH.SetEnabled(cb, RAH.statFilters)
	end
	if RAH.statFilters then
		statsHint:SetText("must have all checked")
		statsHint:SetTextColor(0.5, 0.5, 0.5)
	else
		statsHint:SetText("needs a server update")
		statsHint:SetTextColor(1, 0.3, 0.3)
	end
end

local function filtersActive()
	local f = RetailAHDB.filters
	if f.usable or f.exact or f.minLevel or f.maxLevel or (f.uncollected and RAH.appearances) or statMask() > 0 then
		return true
	end
	return f.qualities and next(f.qualities) ~= nil
end

local function updateFilterButton()
	filterButton:SetText(filtersActive() and "|cff00ff00Filters|r" or "Filters")
end

for _, list in ipairs({ { usableCheck, exactCheck, uncollectedCheck }, rarityChecks, statChecks }) do
	for _, cb in ipairs(list) do
		cb:SetScript("OnClick", function () saveFilters(); updateFilterButton() end)
	end
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
RAH.SkinScrollBar(categoryScroll, categoryScrollName)

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
		-- The right cap carries the +; categories without children end on the plain middle.
		local r = piece("options_listexpand_right", 28 * CATEGORY_ROW / 26)
		r:SetPoint("RIGHT", btn, "RIGHT")
		local m = piece("_options_listexpand_middle")
		m:SetPoint("TOPLEFT", l, "TOPRIGHT")
		btn.bar = { l, m, r }
		btn.SetExpander = function (self, hasChildren, open)
			m:ClearAllPoints()
			m:SetPoint("TOPLEFT", l, "TOPRIGHT")
			if hasChildren then
				D:SafeSetAtlas(r, open and "options_listexpand_right_expanded" or "options_listexpand_right")
				r:Show()
				m:SetPoint("BOTTOMRIGHT", r, "BOTTOMLEFT")
			else
				r:Hide()
				m:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT")
			end
		end
	else
		-- The stock auction window's category button: its filter bar (faded for subcategories,
		-- as Blizzard's is), the tab highlight, and a +/- sign for categories that open.
		local bar = btn:CreateTexture(nil, "BACKGROUND")
		bar:SetTexture("Interface\\AuctionFrame\\UI-AuctionFrame-FilterBg")
		bar:SetTexCoord(0, 0.53125, 0, 0.625)
		bar:SetAllPoints(btn)
		btn.bar = { bar }
		local sign = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		sign:SetPoint("RIGHT", btn, "RIGHT", -6, 0)
		btn.SetExpander = function (self, hasChildren, open)
			sign:SetText(hasChildren and (open and "-" or "+") or "")
		end
	end
	local hl = btn:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints(btn)
	if D then
		btn.selected = RAH.Solid(btn, "BORDER", 0.25, 0.55, 1, 0.3)
		hl:SetTexture(1, 1, 1, 0.1)
	else
		btn.selected = btn:CreateTexture(nil, "BORDER")
		btn.selected:SetTexture("Interface\\PaperDollInfoFrame\\UI-Character-Tab-Highlight")
		btn.selected:SetBlendMode("ADD")
		hl:SetTexture("Interface\\PaperDollInfoFrame\\UI-Character-Tab-Highlight")
		hl:SetBlendMode("ADD")
	end
	btn.selected:SetAllPoints(btn)
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
			btn:SetExpander(n.children ~= nil, expanded[n])
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

local function isUncollected(g)
	return bit.band(g.flags or 0, RAH.GROUP_UNCOLLECTED) ~= 0
end

local function itemName(g)
	local info = RAH.Item(g.link)
	if not info then return "|cff808080Loading...|r" end
	local _, _, _, hex = RAH.QualityColor(info.quality)
	return (RAH.IsFavorite(g.entry) and STAR_INLINE or "") .. hex .. info.name .. "|r" .. (isUncollected(g) and NEW_LOOK or "")
end

local function itemIcon(entry)
	return RAH.ItemIcon(entry)
end

local function sortName(item)
	local info = RAH.Item(item)
	return info and info.name or "~"
end

local function sortLevel(item)
	local info = RAH.Item(item)
	return info and info.itemLevel or 0
end

local function sortReqLevel(item)
	local info = RAH.Item(item)
	return info and info.reqLevel or 0
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
			text = function (g) return itemName(g) end,
			sort = function (g) return sortName(g.link) end },
		{ title = "iLvl", width = 52, align = "CENTER", defaultDesc = true,
			text = function (g) local l = sortLevel(g.link); return l > 0 and tostring(l) or "" end,
			sort = function (g) return sortLevel(g.link) end },
		-- The level needed to use it; blank when anyone can.
		{ title = "Req", width = 46, align = "CENTER", defaultDesc = true,
			text = function (g) local l = sortReqLevel(g.link); return l > 1 and tostring(l) or "" end,
			sort = function (g) return sortReqLevel(g.link) end },
		{ title = "Available", width = 100, align = "RIGHT", defaultDesc = true,
			text = function (g)
				local n = bit.band(g.flags, RAH.GROUP_COMMODITY) ~= 0 and g.units or g.auctions
				return RAH.Number(n)
			end,
			sort = function (g) return bit.band(g.flags, RAH.GROUP_COMMODITY) ~= 0 and g.units or g.auctions end },
	},
	defaultSort = 1,
	link = function (g) return g.link end,
	onClick = function (g, button)
		if button == "RightButton" then
			RAH.SetFavorite(g.entry, not RAH.IsFavorite(g.entry))
		elseif IsControlKeyDown() and IsShiftKeyDown() and RAH.Shopping.Available() then
			RAH.Shopping.Edit(g.entry)
		elseif IsModifiedClick("CHATLINK") then
			local info = RAH.Item(g.link)
			if info then ChatEdit_InsertLink(info.link) end
		elseif IsModifiedClick("DRESSUP") then
			local info = RAH.Item(g.link)
			if info then DressUpItemLink(info.link) end
		elseif g.auctions > 0 then
			Buy.OpenDetail(g)
		end
	end,
	tooltipExtra = function (g, tip)
		if isUncollected(g) then tip:AddLine(UNCOLLECTED_TIP, 1, 0.5, 1) end
		tip:AddLine(" ")
		tip:AddLine("Right-click to " .. (RAH.IsFavorite(g.entry) and "remove from" or "add to") .. " favorites", 0.5, 0.8, 1)
		if RAH.Shopping.Available() then
			tip:AddLine("Ctrl+Shift-click to put it on your shopping list", 0.5, 0.8, 1)
		end
	end,
	empty = "Search for items, or pick a category.",
})
results:SetPoint("TOPLEFT", resultsPane, "TOPLEFT", 4, -4)
results:SetPoint("BOTTOMRIGHT", resultsPane, "BOTTOMRIGHT", -4, 4)

-- Answers from this visit, by query, so a search seen before shows at once while the fresh
-- answer is on its way.
local resultCache = {}

-- What a search found but the progression gates hid: "<by level>,<next level>,<by era>,<next era>".
local function parseLocked(meta)
	if not meta or meta == "" then return nil end
	local byLevel, nextLevel, byEra, nextEra = meta:match("^(%d+),(%d+),(%d+),(%d+)$")
	byLevel, byEra = tonumber(byLevel) or 0, tonumber(byEra) or 0
	if byLevel + byEra == 0 then return nil end
	return { byLevel = byLevel, nextLevel = tonumber(nextLevel), byEra = byEra, nextEra = tonumber(nextEra) }
end

-- "12 unlock as you level (next at 23), 4 after Blackwing Lair"
local function lockedText(locked)
	local parts = {}
	if locked.byLevel > 0 then
		table.insert(parts, locked.byLevel .. " unlock as you level (next at " .. locked.nextLevel .. ")")
	end
	if locked.byEra > 0 then
		table.insert(parts, locked.byEra .. " unlock " .. (RAH.ERA_UNLOCKS[locked.nextEra] or "later in your progression"))
	end
	return table.concat(parts, ", ")
end

-- Hovering the result count explains the locked items.
local lockedHover = CreateFrame("Frame", nil, panel)
lockedHover:SetAllPoints(resultCount)
lockedHover:EnableMouse(true)
lockedHover:Hide()
lockedHover:SetScript("OnEnter", function (self)
	GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
	GameTooltip:AddLine("Locked items")
	GameTooltip:AddLine("This search matched items above your level or progression; they stay hidden "
		.. "until you reach them. Items you own always show.", 1, 1, 1, true)
	GameTooltip:AddLine(lockedText(self.locked), 1, 0.82, 0, true)
	GameTooltip:Show()
end)
lockedHover:SetScript("OnLeave", function () GameTooltip:Hide() end)

-- stats: the stat mask the rows were searched with, so opening one lists only the copies that
-- have those stats.
-- locked: parseLocked's answer, or nil.
-- A row of a search, favorites or shopping answer.
local function toGroup(r, order, stats)
	-- r[6], r[7]: the suffix of a group that search split by suffix ("of the Monkey").
	return {
		entry = r[1], price = r[2], units = r[3], auctions = r[4], flags = r[5], order = order, stats = stats,
		randomProperty = r[6] or 0, link = RAH.ItemString(r[1], r[6], r[7]),
	}
end

local function showResults(rows, truncated, emptyText, keepScroll, stats, locked)
	state.results = {}
	for i, r in ipairs(rows) do
		table.insert(state.results, toGroup(r, i, stats))
	end
	if not emptyText and locked and #rows == 0 then
		emptyText = "Nothing you can see yet: " .. lockedText(locked) .. "."
	end
	results:SetEmptyText(emptyText or "No items found.")
	lockedHover.locked = locked
	if locked then lockedHover:Show() else lockedHover:Hide() end
	results:SetItems(state.results, keepScroll)
	local entries = {}
	for i, g in ipairs(state.results) do entries[i] = g.link end
	RAH.Prefetch(entries)
	if truncated then
		-- Short: it shares the row with the search box. Narrowing the search shows the rest.
		resultCount:SetText("|cffff8000Showing the first " .. #rows .. " items|r")
	elseif state.lastQuery == "favorites" then
		resultCount:SetText(#rows .. " favorites")
	else
		local text = #rows == 1 and "1 item" or (#rows .. " items")
		if state.node then
			text = text .. " in |cffffd200" .. state.node.name .. "|r"
		end
		if locked then
			text = text .. " |cff808080+" .. (locked.byLevel + locked.byEra) .. " locked|r"
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
	Buy.ShowList()
	local f = RetailAHDB.filters
	local flags = (f.usable and 1 or 0) + (f.exact and 2 or 0) + ((f.uncollected and RAH.appearances) and 4 or 0)
	local mask = 0
	if f.qualities then
		for q in pairs(f.qualities) do mask = mask + bit.lshift(1, q) end
	end
	local n = state.node
	local name = searchBox:GetText():gsub("^%s+", ""):gsub("%s+$", "")
	-- The stat mask rides on the flags field, so the name stays the last field.
	local stats = statMask()

	local fields = {
		stats > 0 and (flags .. "," .. stats) or flags, f.minLevel or 0, f.maxLevel or 0, mask,
		n and n.class or -1, n and n.subclass or -1, n and n.invtype or -1, name,
	}
	local key = table.concat(fields, ":")
	local cached = resultCache[key]
	if cached then
		showResults(cached.rows, cached.truncated, nil, nil, stats, cached.locked)
	else
		resultCount:SetText("Searching...")
	end

	-- Answers to a superseded search are dropped.
	RAH.CancelQueuedSearches()
	local token = {}
	state.searchReq = token
	RAH.Request("S", fields, function (result, err)
		if state.searchReq ~= token then return end
		if err then
			if not cached then resultCount:SetText("") end
			RAH.Status(err == "far" and "You're too far from the auctioneer." or "Search failed; try again.", true)
			return
		end
		local truncated = result.meta[2] == "1"
		local locked = parseLocked(result.meta[3])
		resultCache[key] = { rows = result.rows, truncated = truncated, locked = locked }
		showResults(result.rows, truncated, nil, cached ~= nil, stats, locked)
	end)
end

function Buy.ShowFavorites()
	if not RAH.serverReady then return end
	Buy.CloseDetail()
	state.lastQuery = "favorites"
	Buy.ShowList()
	state.node = nil
	refreshCategories()
	local favs = RAH.Favorites()
	if #favs == 0 then
		state.searchReq = nil
		showResults({}, false, "No favorites yet. Right-click a result, or click the star on an item, to add one.")
		return
	end

	-- The server takes up to 30 per request.
	RAH.CancelQueuedSearches()
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
-- shopping list: every item on it with what's left to buy, in place of the results

local SHOP_FOOTER = 30

local function isCommodity(g)
	return bit.band(g.flags or 0, RAH.GROUP_COMMODITY) ~= 0
end

local shopping = RAH.CreateList(resultsPane, {
	rows = 19,
	columns = {
		{ title = "Price", width = 140, align = "RIGHT", defaultDesc = false,
			text = function (g) return g.auctions > 0 and RAH.Money(g.price) or "|cff808080--|r" end,
			sort = function (g) return g.auctions > 0 and g.price or math.huge end },
		{ title = "Name", icon = function (g) return itemIcon(g.entry) end,
			text = function (g) return itemName(g) end,
			sort = function (g) return sortName(g.link) end },
		{ title = "To Buy", width = 70, align = "RIGHT", defaultDesc = true,
			text = function (g) return RAH.Number(g.need) end,
			sort = function (g) return g.need end },
		{ title = "Bought", width = 70, align = "RIGHT", defaultDesc = true,
			text = function (g) return g.bought > 0 and ("|cff20ff20" .. RAH.Number(g.bought) .. "|r") or "" end,
			sort = function (g) return g.bought end },
		-- Red when the house can't cover what's left.
		{ title = "Available", width = 100, align = "RIGHT", defaultDesc = true,
			text = function (g)
				local n = isCommodity(g) and g.units or g.auctions
				return (n < g.need and "|cffff2020" or "") .. RAH.Number(n) .. (n < g.need and "|r" or "")
			end,
			sort = function (g) return isCommodity(g) and g.units or g.auctions end },
	},
	defaultSort = 2,
	link = function (g) return g.link end,
	onClick = function (g, button)
		if button == "RightButton" then
			if IsShiftKeyDown() then RAH.Shopping.Remove(g.entry) else RAH.Shopping.Edit(g.entry) end
		elseif IsModifiedClick("CHATLINK") then
			local info = RAH.Item(g.link)
			if info then ChatEdit_InsertLink(info.link) end
		elseif g.auctions > 0 then
			Buy.OpenDetail(g)
		else
			RAH.Status("None are listed right now.", true)
		end
	end,
	tooltipExtra = function (g, tip)
		tip:AddLine(" ")
		tip:AddLine("Click to buy what's left", 0.5, 0.8, 1)
		tip:AddLine("Right-click to change the amount, Shift-right-click to take it off the list", 0.5, 0.8, 1)
	end,
	empty = "Your shopping list is empty.",
})
shopping:SetPoint("TOPLEFT", resultsPane, "TOPLEFT", 4, -4)
shopping:SetPoint("BOTTOMRIGHT", resultsPane, "BOTTOMRIGHT", -4, 4 + SHOP_FOOTER)
shopping:Hide()

local shopFooter = CreateFrame("Frame", nil, resultsPane)
shopFooter:SetPoint("BOTTOMLEFT", resultsPane, "BOTTOMLEFT", 10, 6)
shopFooter:SetPoint("BOTTOMRIGHT", resultsPane, "BOTTOMRIGHT", -10, 6)
shopFooter:SetHeight(SHOP_FOOTER - 6)
shopFooter:Hide()

local shopClear = RAH.CreateButton(shopFooter, "Clear List", 100, 22)
shopClear:SetPoint("RIGHT", shopFooter, "RIGHT", 0, 0)
shopClear:SetScript("OnClick", function ()
	RAH.Confirm("Take everything off your shopping list?", function () RAH.Shopping.Clear() end)
end)

local shopSummary = shopFooter:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
shopSummary:SetPoint("LEFT", shopFooter, "LEFT", 0, 0)
shopSummary:SetPoint("RIGHT", shopClear, "LEFT", -10, 0)
shopSummary:SetJustifyH("LEFT")

local function updateShopButton()
	if not RAH.Shopping.Available() then return end
	local n = #RAH.Shopping.Items()
	shopButton.count:SetText(n > 0 and n or "")
	shopButton.icon:SetDesaturated(n == 0)
	shopButton.icon:SetAlpha(n > 0 and 1 or 0.6)
end

-- rows: the favorites lookup's answer for the entries in `items` (RAH.Shopping.Items()).
local function showShopping(items, rows, keepScroll)
	local byEntry = {}
	for i, r in ipairs(rows) do byEntry[r[1]] = toGroup(r, i) end
	local list, entries, units, cost = {}, {}, 0, 0
	for i, item in ipairs(items) do
		-- An item the server doesn't answer for (hidden from this character) still shows, unlisted.
		local g = byEntry[item.entry] or toGroup({ item.entry, 0, 0, 0, 0 }, #rows + i)
		g.need, g.bought = item.need, item.bought
		table.insert(list, g)
		table.insert(entries, g.link)
		units = units + item.need
		-- A rough total: the cheapest price for all of it, where there's a price per unit.
		if isCommodity(g) and g.auctions > 0 then cost = cost + g.price * item.need end
	end
	shopping:SetEmptyText("Your shopping list is empty.\n\nIn the profession window, pick a recipe and an amount, "
		.. "then Add to Shopping List.")
	shopping:SetItems(list, keepScroll)
	RAH.Prefetch(entries)
	resultCount:SetText(#list == 0 and "" or (#list == 1 and "1 item to buy" or (#list .. " items to buy")))
	lockedHover:Hide()
	local text = #list == 0 and "" or (RAH.Number(units) .. " left to buy")
	if cost > 0 then text = text .. "  |cffa0a0a0from about|r " .. RAH.Money(cost) end
	shopSummary:SetText(text)
	RAH.SetEnabled(shopClear, #list > 0)
	updateShopButton()
end

function Buy.ShowShopping(keepScroll)
	if not (RAH.serverReady and RAH.Shopping.Available()) then return end
	Buy.CloseDetail()
	filters:Hide()
	state.lastQuery = "shopping"
	Buy.ShowList()
	state.node = nil
	refreshCategories()
	local items = RAH.Shopping.Items()
	RAH.CancelQueuedSearches()
	local token = {}
	state.searchReq = token
	if #items == 0 then
		showShopping(items, {}, keepScroll)
		return
	end

	-- The server takes up to 30 per request.
	if not keepScroll then resultCount:SetText("Loading your shopping list...") end
	local rows, pendingChunks = {}, 0
	for i = 1, #items, 30 do
		local chunk = {}
		for j = i, math.min(i + 29, #items) do table.insert(chunk, items[j].entry) end
		pendingChunks = pendingChunks + 1
		RAH.Request("F", { table.concat(chunk, ",") }, function (result, err)
			if state.searchReq ~= token then return end
			if result then
				for _, r in ipairs(result.rows) do table.insert(rows, r) end
			end
			pendingChunks = pendingChunks - 1
			if pendingChunks == 0 then showShopping(items, rows, keepScroll) end
		end)
	end
end

shopButton:SetScript("OnClick", function () Buy.ShowShopping() end)

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
back:SetScript("OnClick", function ()
	Buy.CloseDetail()
	-- Something was probably bought: what's left and the prices have changed.
	if state.lastQuery == "shopping" then Buy.ShowShopping(true) end
end)

local detailIcon = RAH.CreateItemButton(detail, 34)
detailIcon:SetPoint("LEFT", back, "RIGHT", 12, -6)
detailIcon:SetScript("OnEnter", function (self)
	if state.detail then
		RAH.ItemTooltip(self, state.detail.link, function (tip)
			if isUncollected(state.detail) then tip:AddLine(UNCOLLECTED_TIP, 1, 0.5, 1) end
		end)
	end
end)
detailIcon:SetScript("OnLeave", RAH.HideItemTooltip)

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

-- Commodities are bought by quantity, like retail. This switches to the stacks themselves,
-- for bidding on one (bots and the old window list stacks with a starting bid).
local stacksToggle = RAH.CreateButton(detail, "Bid on Stacks", 110, 22)
stacksToggle:SetPoint("RIGHT", refresh, "LEFT", -6, 0)
stacksToggle:SetScript("OnEnter", function (self)
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	if state.stacks then
		GameTooltip:AddLine("Buy by quantity")
		GameTooltip:AddLine("Back to buying any amount at the cheapest prices.", 1, 1, 1, true)
	else
		GameTooltip:AddLine("Bid on stacks")
		GameTooltip:AddLine("List every stack on its own, with its bid and buyout, to bid on one or buy a whole stack.", 1, 1, 1, true)
	end
	GameTooltip:Show()
end)
stacksToggle:SetScript("OnLeave", function () GameTooltip:Hide() end)

-- What has been bought since the item was opened, so buying in a row keeps count.
local tallyLabel = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
tallyLabel:SetPoint("TOPRIGHT", refresh, "BOTTOMRIGHT", 0, -6)
tallyLabel:SetJustifyH("RIGHT")

local function updateTally()
	local t = state.tally
	local parts = {}
	local need = state.detail and RAH.Shopping.Need(state.detail.entry) or 0
	if need > 0 then table.insert(parts, "Shopping list: |cffffffff" .. RAH.Number(need) .. "|r to buy") end
	if t.count > 0 then
		table.insert(parts, "Purchased: |cffffffff" .. RAH.Number(t.count) .. "|r for " .. RAH.Money(t.spent))
	end
	tallyLabel:SetText(table.concat(parts, "    "))
end

local function addToTally(count, spent)
	state.tally.count = state.tally.count + count
	state.tally.spent = state.tally.spent + spent
	updateTally()
end

local function updateDetailHeader()
	local g = state.detail
	if not g then return end
	local info = RAH.Item(g.link)
	if info then
		local _, _, _, hex = RAH.QualityColor(info.quality)
		detailName:SetWidth(0)
		detailName:SetText(hex .. info.name .. "|r" .. (isUncollected(g) and NEW_LOOK or ""))
		-- Long names stop short of the buttons on the right.
		if detailName:GetStringWidth() > 250 then detailName:SetWidth(250) end
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

-- Counts a purchase off the shopping list. An item still on it afterwards gets what's left as
-- the next quantity.
local function boughtForList(g, count)
	if count <= 0 or RAH.Shopping.Need(g.entry) <= 0 then return end
	RAH.Shopping.Bought(g.entry, count)
	local left = RAH.Shopping.Need(g.entry)
	if left > 0 and state.detail == g then qtyBox:SetText(tostring(left)) end
end

buyNow:SetScript("OnClick", function ()
	local g, q = state.detail, state.quote
	if not (g and q and q.found >= q.quantity) then return end
	local info = RAH.Item(g.entry)
	local text = string.format("Buy %s x %s for %s?", info and info.link or ("item " .. g.entry), RAH.Number(q.quantity), RAH.Money(q.total))
	local function go()
		RAH.SetEnabled(buyNow, false)
		RAH.QuietChat(4)
		RAH.Request("B", { g.entry, q.quantity, q.total }, function (result, err)
			if err or not result then RAH.Status("Purchase failed.", true) return end
			local status, bought, spent = result[1], tonumber(result[2]) or 0, tonumber(result[3]) or 0
			if status == "ok" then
				RAH.Status("Bought " .. RAH.Number(bought) .. " for " .. RAH.Money(spent) .. ". It's in your mailbox.")
				PlaySound("LOOTWINDOWCOINSOUND")
				boughtForList(g, bought)
				addToTally(bought, spent)
			elseif status == "partial" then
				boughtForList(g, bought)
				addToTally(bought, spent)
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
	end
	if IsShiftKeyDown() then go() else RAH.Confirm(text, go) end
end)
buyNow:SetScript("OnEnter", function (self)
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:AddLine("Buy at the cheapest prices")
	GameTooltip:AddLine("The quantity stays afterwards, so you can buy the same amount again. Shift-click to buy without the confirmation.", 1, 1, 1, true)
	GameTooltip:Show()
end)
buyNow:SetScript("OnLeave", function () GameTooltip:Hide() end)

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
buyoutButton:SetScript("OnEnter", function (self)
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:AddLine("Buy the selected listing")
	GameTooltip:AddLine("The next cheapest one is picked for you afterwards. Shift-click to buy without the confirmation.", 1, 1, 1, true)
	GameTooltip:Show()
end)
buyoutButton:SetScript("OnLeave", function () GameTooltip:Hide() end)

-- The price Buy Now will pay, beside it.
local buyoutPrice = itemView:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
buyoutPrice:SetPoint("RIGHT", buyoutButton, "LEFT", -10, 0)
buyoutPrice:SetJustifyH("RIGHT")

local function canBuyOut(a)
	return bit.band(a.flags, RAH.AUCTION_OWN) == 0 and a.buyout > 0
end

-- Cheapest listing the player can buy out, per unit.
local function cheapestBuyable(list)
	local best
	for _, a in ipairs(list) do
		if canBuyOut(a) and (not best or a.buyout / a.count < best.buyout / best.count) then best = a end
	end
	return best
end

function Buy.UpdateAuctionButtons()
	local a = state.selectedAuction
	local own = a and bit.band(a.flags, RAH.AUCTION_OWN) ~= 0
	local canBid = a and not own and bit.band(a.flags, RAH.AUCTION_HIGH_BIDDER) == 0 and (a.buyout == 0 or a.minBid < a.buyout)
	local canBuy = a and not own and a.buyout > 0
	RAH.SetEnabled(bidButton, canBid and GetMoney() >= a.minBid)
	RAH.SetEnabled(buyoutButton, canBuy and GetMoney() >= a.buyout)
	if a then bidInput:SetCopper(a.minBid) end
	if canBuy then
		local text = RAH.Money(a.buyout)
		if a.count > 1 then text = "|cffffffff" .. a.count .. " x|r " .. text end
		if GetMoney() < a.buyout then text = "|cffff2020" .. text .. "|r" end
		buyoutPrice:SetText(text)
	else
		buyoutPrice:SetText("")
	end
	auctions:Refresh()
end

local function placeBid(a, price, verb, skipConfirm)
	local info = RAH.Item(a.link)
	local g = state.detail
	local text = string.format("%s %s for %s?", verb, info and info.link or "this item", RAH.Money(price))
	local function go()
		RAH.SetEnabled(buyoutButton, false)
		RAH.QuietChat(3)
		RAH.Request("P", { a.id, price }, function (result, err)
			local status = result and result[1]
			if status == "bought" then
				RAH.Status("Bought " .. (info and info.link or "the item") .. ". It's in your mailbox.")
				PlaySound("LOOTWINDOWCOINSOUND")
				if g then boughtForList(g, a.count) end
				addToTally(a.count, price)
				state.pickNext = true
			elseif status == "bid" then
				RAH.Status("Bid placed. You'll get a mail if you're outbid.")
			elseif status == "gone" then
				RAH.Status(ERR_AUCTION_ITEM_NOT_FOUND or "That auction is gone.", true)
			else
				RAH.Status("That didn't go through.", true)
			end
			if status == "gone" then state.pickNext = true end
			state.selectedAuction = nil
			loadDetail()
		end)
	end
	if skipConfirm then go() else RAH.Confirm(text, go) end
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
	if a then placeBid(a, a.buyout, "Buy", IsShiftKeyDown()) end
end)

-----------------------------------------
-- opening and loading an item

local function byQuantity(g)
	return bit.band(g.flags, RAH.GROUP_COMMODITY) ~= 0 and not state.stacks
end

-- Shows the quantity view or the listings view, and the toggle only for commodities.
local function showDetailMode(g)
	if byQuantity(g) then
		commodity:Show(); itemView:Hide()
	else
		itemView:Show(); commodity:Hide()
		Buy.UpdateAuctionButtons()
	end
	if bit.band(g.flags, RAH.GROUP_COMMODITY) ~= 0 then
		stacksToggle:SetText(state.stacks and "Buy by Quantity" or "Bid on Stacks")
		stacksToggle:Show()
	else
		stacksToggle:Hide()
	end
end

function loadDetail()
	local g = state.detail
	if not g then return end
	updateDetailHeader()
	local token = {}
	state.detailReq = token

	if byQuantity(g) then
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
		-- A group search split by suffix lists only that suffix's copies.
		local args = { g.entry }
		if bit.band(g.flags, RAH.GROUP_SUFFIX) ~= 0 then
			args = { g.entry, g.stats or 0, g.randomProperty }
		elseif (g.stats or 0) > 0 then
			args = { g.entry, g.stats }
		end
		RAH.Request("I", args, function (result, err)
			if state.detailReq ~= token or not result then return end
			-- The look may have been collected since the search (bought and equipped one).
			local look = tonumber(result.meta[2])
			if look then
				g.flags = look == 2 and bit.bor(g.flags, RAH.GROUP_UNCOLLECTED) or bit.band(g.flags, bit.bnot(RAH.GROUP_UNCOLLECTED))
				updateDetailHeader()
			end
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
			if state.pickNext then
				state.pickNext = false
				state.selectedAuction = cheapestBuyable(list)
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
	state.tally = { count = 0, spent = 0 }
	state.pickNext = true
	state.stacks = false
	updateTally()
	tiers:SetItems({})
	-- An item on the shopping list starts at what's left to buy.
	local need = RAH.Shopping.Need(g.entry)
	qtyBox:SetText(tostring(need > 0 and need or 1))
	auctions:SetItems({})
	bidInput:SetCopper(0)
	showDetailMode(g)
	detail:Show()
	Buy.ShowList()
	loadDetail()
end

function Buy.CloseDetail()
	state.detail = nil
	state.detailReq = nil
	detail:Hide()
	Buy.ShowList()
end

-- What fills the pane: the shopping list or the results. Neither under the item view: without
-- DragonUI's opaque panes they'd show through.
function Buy.ShowList()
	local open = not detail:IsShown()
	local shop = state.lastQuery == "shopping"
	if open and shop then shopping:Show(); shopFooter:Show() else shopping:Hide(); shopFooter:Hide() end
	if open and not shop then results:Show() else results:Hide() end
end

-- Opens one item by its entry (ReagentBankUI's own shopping list rows do this).
function Buy.OpenEntry(entry)
	if not RAH.serverReady then return false end
	RAH.SelectTab(tabIndex)
	RAH.Request("F", { tostring(entry) }, function (result)
		local r = result and result.rows[1]
		if not r then return end
		local g = toGroup(r, 1)
		if g.auctions > 0 then Buy.OpenDetail(g) else RAH.Status("None are listed right now.", true) end
	end)
	return true
end

stacksToggle:SetScript("OnClick", function ()
	local g = state.detail
	if not g then return end
	state.stacks = not state.stacks
	state.selectedAuction = nil
	state.pickNext = true
	auctions:SetItems({})
	showDetailMode(g)
	loadDetail()
	if GameTooltip:IsOwned(stacksToggle) then stacksToggle:GetScript("OnEnter")(stacksToggle) end
end)

refresh:SetScript("OnClick", function () loadDetail() end)

-----------------------------------------

RAH.On("ITEM_INFO", function ()
	if not panel:IsShown() then return end
	RAH.Debounce("buy-items", 0.05, function ()
		results:Refresh()
		shopping:Refresh()
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

-- The list changed (bought, removed, cleared, or added to from the profession window).
RAH.On("SHOPPING", function ()
	RAH.Debounce("buy-shopping", 0.05, function ()
		updateShopButton()
		if detail:IsShown() then
			updateTally()
		elseif state.lastQuery == "shopping" and RAH.active then
			Buy.ShowShopping(true)
		end
	end)
end)

-- A fresh visit starts on the shopping list when there's something on it (that's what the
-- visit is for), else on the favorites, like retail, or the prompt if there are none.
RAH.On("READY", function ()
	state.node = nil
	expanded = {}
	refreshCategories()
	state.lastQuery = nil
	Buy.CloseDetail()
	updateShopButton()
	if #RAH.Shopping.Items() > 0 then
		Buy.ShowShopping()
	elseif next(RetailAHDB.favorites) then
		Buy.ShowFavorites()
	else
		showResults({}, false, "Search for items, or pick a category.")
		resultCount:SetText("")
	end
end)

RAH.On("CLOSED", function ()
	resultCache = {}
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
