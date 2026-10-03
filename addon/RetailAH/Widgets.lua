-- RetailAH widgets: buttons, inputs, panes and scrolling lists, dressed in DragonUI's retail art
-- when DragonUI is loaded and in a dark retail-like style of their own otherwise.

local RAH = RetailAH

local nameCounter = 0
local function uniqueName(base)
	nameCounter = nameCounter + 1
	return "RetailAH" .. base .. nameCounter
end
RAH.UniqueName = uniqueName

-----------------------------------------
-- DragonUI, if it's there and new enough to carry the helpers we borrow

function RAH.Dragon()
	local D = _G.DragonUI
	if D and D._dir and D.atlasinfo and D.SafeSetAtlas and D.SkinRedButton and NineSliceUtils
			and D.CharacterPanel and D.CharacterPanel.ReskinTab then
		return D, D.CharacterPanel
	end
end

local function solid(host, layer, r, g, b, a, sublevel)
	local tex = host:CreateTexture(nil, layer, nil, sublevel)
	tex:SetTexture(r, g, b, a)
	return tex
end
RAH.Solid = solid

local function tiled(host, layer, sublevel, file)
	local tex = host:CreateTexture(nil, layer, nil, sublevel)
	tex:SetTexture(file, "REPEAT", "REPEAT")
	tex:SetHorizTile(true)
	tex:SetVertTile(true)
	return tex
end

-----------------------------------------
-- window chrome and panes

-- Without DragonUI every window is a stock Blizzard dialog frame: the dialog-box border and
-- background, with the gold header plate for the title (frame.headerPlate).
local DIALOG_BACKDROP = {
	bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
	edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
	tile = true, tileSize = 32, edgeSize = 32,
	insets = { left = 11, right = 12, top = 12, bottom = 11 },
}

-- The stock tooltip look, for panes and pop-up panels.
RAH.TOOLTIP_BACKDROP = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

-- The outer window: DragonUI's metal frame (the one without a portrait ring) on rock, or the
-- stock Blizzard dialog frame.
function RAH.DressWindow(frame)
	local D = RAH.Dragon()
	if D then
		local rock = tiled(frame, "BACKGROUND", -8, D._dir .. "UI\\ui-background-rock")
		rock:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -21)
		rock:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)

		local streaks = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
		if D:SafeSetAtlas(streaks, "_UI-Frame-TopTileStreaks") then
			streaks:SetHorizTile(true)
			streaks:SetHeight(43)
			streaks:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -21)
			streaks:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -21)
		else
			streaks:Hide()
		end

		-- On its own frame above the content, so no child panel draws over the metal.
		local chrome = CreateFrame("Frame", nil, frame)
		chrome:SetAllPoints(frame)
		chrome:SetFrameLevel(frame:GetFrameLevel() + 30)
		chrome:EnableMouse(false)
		NineSliceUtils.ApplyLayout(chrome, NineSliceUtils.GetLayout("NoPortraitFrameTemplate")
			or NineSliceUtils.GetLayout("PortraitFrameTemplate"))
		frame.chrome = chrome
		return true
	end

	frame:SetBackdrop(DIALOG_BACKDROP)
	local plate = frame:CreateTexture(nil, "ARTWORK")
	plate:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
	plate:SetSize(320, 64)
	plate:SetPoint("TOP", frame, "TOP", 0, 12)
	frame.headerPlate = plate
	frame.chrome = frame
	return false
end

-- A recessed pane: retail's InsetFrameTemplate with DragonUI, the stock tooltip border without.
function RAH.CreateInset(parent)
	local pane = CreateFrame("Frame", nil, parent)
	local D = RAH.Dragon()
	if D then
		local bg = tiled(pane, "BACKGROUND", -5, D._dir .. "UI\\ui-background-marble")
		bg:SetAllPoints(pane)
		NineSliceUtils.ApplyLayout(pane, NineSliceUtils.GetLayout("InsetFrameTemplate"))
	else
		pane:SetBackdrop(RAH.TOOLTIP_BACKDROP)
		pane:SetBackdropColor(0, 0, 0, 0.75)
		pane:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
	end
	return pane
end

-- A FauxScrollFrame's bar: DragonUI's thin one, or the stock one as it is.
function RAH.SkinScrollBar(scroll, scrollName)
	local bar = _G[scrollName .. "ScrollBar"]
	if not bar then return end
	local _, CP = RAH.Dragon()
	if CP and CP.ReskinScrollBar then
		pcall(CP.ReskinScrollBar, scroll, scroll, -7, 18, -7, true)
	end
end

-----------------------------------------
-- controls

function RAH.SetEnabled(control, enabled)
	if enabled then control:Enable() else control:Disable() end
end

function RAH.CreateButton(parent, text, width, height)
	local btn = CreateFrame("Button", uniqueName("Button"), parent, "UIPanelButtonTemplate")
	btn:SetSize(width or 100, height or 22)
	btn:SetText(text or "")
	local D = RAH.Dragon()
	if D then D.SkinRedButton(btn) end
	return btn
end

-- Retail's small icon button (favorites star, back arrow).
function RAH.CreateIconButton(parent, texture, size)
	local btn = CreateFrame("Button", nil, parent)
	btn:SetSize(size or 22, size or 22)
	btn.icon = btn:CreateTexture(nil, "ARTWORK")
	btn.icon:SetAllPoints(btn)
	btn.icon:SetTexture(texture)
	local hl = btn:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints(btn)
	hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
	hl:SetBlendMode("ADD")
	return btn
end

local function skinInput(eb)
	local D = RAH.Dragon()
	if not D then return end
	local regions = { eb:GetRegions() }
	for i = 1, #regions do
		local r = regions[i]
		if r:GetObjectType() == "Texture" then
			local path = r:GetTexture()
			if type(path) == "string" and path:lower():find("common%-input%-border") then
				r:SetTexture(0, 0, 0, 0.55)
			end
		end
	end
end

function RAH.CreateEditBox(parent, width, numeric)
	local eb = CreateFrame("EditBox", uniqueName("EditBox"), parent, "InputBoxTemplate")
	eb:SetSize(width or 120, 20)
	eb:SetAutoFocus(false)
	if numeric then eb:SetNumeric(true) end
	eb:SetScript("OnEscapePressed", function (self) self:ClearFocus() end)
	eb:SetScript("OnEnterPressed", function (self) self:ClearFocus() end)
	skinInput(eb)
	return eb
end

function RAH.CreateCheck(parent, label)
	local name = uniqueName("Check")
	local cb = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
	cb:SetSize(24, 24)
	local text = _G[name .. "Text"]
	text:SetText(label or "")
	text:SetFontObject(GameFontHighlightSmall)
	cb.label = text
	local _, CP = RAH.Dragon()
	if CP and CP.SkinCheckbox then CP.SkinCheckbox(cb) end
	return cb
end

-- Gold/silver/copper boxes (Blizzard's MoneyInputFrameTemplate, which needs a global name).
function RAH.CreateMoneyInput(parent, onChange)
	local name = uniqueName("Money")
	local frame = CreateFrame("Frame", name, parent, "MoneyInputFrameTemplate")
	frame.GetCopper = function (self) return MoneyInputFrame_GetCopper(self) end
	frame.SetCopper = function (self, copper) MoneyInputFrame_SetCopper(self, math.floor(copper or 0)) end
	if onChange then MoneyInputFrame_SetOnValueChangedFunc(frame, onChange) end
	for _, part in ipairs({ "Gold", "Silver", "Copper" }) do skinInput(_G[name .. part]) end
	return frame
end

function RAH.CreateMoneyText(parent, font)
	local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
	fs.SetMoney = function (self, copper) self:SetText(RAH.Money(copper)) end
	return fs
end

function RAH.CreateLabel(parent, text, font)
	local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormal")
	fs:SetText(text or "")
	return fs
end

-- A square item button with a quality border.
function RAH.CreateItemButton(parent, size)
	local btn = CreateFrame("Button", nil, parent)
	btn:SetSize(size or 37, size or 37)
	btn.icon = btn:CreateTexture(nil, "ARTWORK")
	btn.icon:SetAllPoints(btn)
	btn.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	btn.border = btn:CreateTexture(nil, "OVERLAY")
	btn.border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	btn.border:SetBlendMode("ADD")
	btn.border:SetPoint("CENTER", btn, "CENTER")
	btn.border:SetSize((size or 37) * 1.8, (size or 37) * 1.8)
	btn.border:Hide()
	btn.count = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	btn.count:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)
	local hl = btn:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints(btn)
	hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
	hl:SetBlendMode("ADD")

	btn.SetItem = function (self, texture, quality, count)
		self.icon:SetTexture(texture)
		if quality and quality >= 2 then
			local r, g, b = RAH.QualityColor(quality)
			self.border:SetVertexColor(r, g, b)
			self.border:Show()
		else
			self.border:Hide()
		end
		self.count:SetText(count and count > 1 and count or "")
	end
	return btn
end

-----------------------------------------
-- tabs along the bottom edge

function RAH.CreateTab(frame, index, text, onClick)
	local tab = CreateFrame("Button", frame:GetName() .. "Tab" .. index, frame, "CharacterFrameTabButtonTemplate")
	tab:SetID(index)
	tab:SetText(text)
	tab:SetScript("OnClick", function (self)
		PlaySound("igCharacterInfoTab")
		onClick(self:GetID())
	end)
	PanelTemplates_TabResize(tab, 0)
	local _, CP = RAH.Dragon()
	if CP then CP.ReskinTab(tab) end
	return tab
end

-----------------------------------------
-- scrolling list with sortable column headers
--
-- spec = {
--   rows = visible row count, rowHeight = 20 (default),
--   columns = { { title, width, align, text = fn(item) -> string, icon = fn(item) -> texture,
--                 sort = fn(item) -> comparable }, ... },   -- one column may leave width nil to fill
--   link = fn(item) -> item link for the tooltip, onClick = fn(item, button), onDoubleClick,
--   empty = "text when there's nothing", defaultSort = column index, defaultDesc = bool,
--   isSelected = fn(item) -> bool,
-- }

local HEADER_HEIGHT = 20

function RAH.CreateList(parent, spec)
	local rowHeight = spec.rowHeight or 20
	local list = CreateFrame("Frame", nil, parent)
	list.items = {}
	list.spec = spec
	list.sortColumn = spec.defaultSort
	list.sortDesc = spec.defaultDesc
	list:SetHeight(HEADER_HEIGHT + spec.rows * rowHeight + 4)

	local dragon = RAH.Dragon() and true or false

	-- header strip: with DragonUI dark with a thin gold rule, as the Auctionator skin does;
	-- otherwise each column gets the stock column tab (the auction and who lists' headers)
	local header = CreateFrame("Frame", nil, list)
	header:SetPoint("TOPLEFT", list, "TOPLEFT", 0, 0)
	header:SetPoint("TOPRIGHT", list, "TOPRIGHT", -18, 0)
	header:SetHeight(HEADER_HEIGHT)
	if dragon then
		solid(header, "BACKGROUND", 0, 0, 0, 0.45):SetAllPoints(header)
		local rule = solid(header, "BORDER", 1, 0.82, 0, 0.35)
		rule:SetHeight(1)
		rule:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT")
		rule:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT")
	end

	local scrollName = uniqueName("Scroll")
	local scroll = CreateFrame("ScrollFrame", scrollName, list, "FauxScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
	scroll:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", -22, 2)
	scroll:SetScript("OnVerticalScroll", function (self, offset)
		FauxScrollFrame_OnVerticalScroll(self, offset, rowHeight, function () list:Refresh() end)
	end)
	list.scroll = scroll
	RAH.SkinScrollBar(scroll, scrollName)

	-- lay the columns out once the list knows its width
	local headers, cells = {}, {}
	local function columnOffsets(total)
		local fixed, fill = 0, nil
		for i, col in ipairs(spec.columns) do
			if col.width then fixed = fixed + col.width else fill = i end
		end
		local offsets, x = {}, 0
		for i, col in ipairs(spec.columns) do
			local w = col.width or math.max(40, total - fixed)
			if not fill and i == #spec.columns then w = math.max(w, total - x) end
			offsets[i] = { x = x, w = w }
			x = x + w
		end
		return offsets
	end

	for i, col in ipairs(spec.columns) do
		local h = CreateFrame("Button", nil, header)
		h:SetHeight(HEADER_HEIGHT)
		h.text = h:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		h.text:SetPoint("LEFT", h, "LEFT", 6, 0)
		h.text:SetPoint("RIGHT", h, "RIGHT", -12, 0)
		h.text:SetJustifyH(col.align or "LEFT")
		h.text:SetText(col.title or "")
		h.arrow = h:CreateTexture(nil, "OVERLAY")
		h.arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
		h.arrow:SetSize(9, 8)
		h.arrow:SetPoint("RIGHT", h, "RIGHT", -2, 0)
		h.arrow:Hide()
		if dragon then
			h.arrow:SetVertexColor(1, 0.82, 0)
			local wash = h:CreateTexture(nil, "HIGHLIGHT")
			wash:SetAllPoints(h)
			wash:SetTexture(1, 1, 1, 0.08)
		else
			local function tab(l, r, w)
				local tex = h:CreateTexture(nil, "BACKGROUND")
				tex:SetTexture("Interface\\FriendsFrame\\WhoFrame-ColumnTabs")
				tex:SetTexCoord(l, r, 0, 0.75)
				tex:SetHeight(HEADER_HEIGHT)
				if w then tex:SetWidth(w) end
				return tex
			end
			local tl = tab(0, 0.078125, 5)
			tl:SetPoint("TOPLEFT", h, "TOPLEFT")
			local tr = tab(0.90625, 0.96875, 4)
			tr:SetPoint("TOPRIGHT", h, "TOPRIGHT")
			local tm = tab(0.078125, 0.90625)
			tm:SetPoint("TOPLEFT", tl, "TOPRIGHT")
			tm:SetPoint("TOPRIGHT", tr, "TOPLEFT")
			local hl = h:CreateTexture(nil, "HIGHLIGHT")
			hl:SetTexture("Interface\\PaperDollInfoFrame\\UI-Character-Tab-Highlight")
			hl:SetBlendMode("ADD")
			hl:SetPoint("TOPLEFT", h, "TOPLEFT", 2, 0)
			hl:SetPoint("BOTTOMRIGHT", h, "BOTTOMRIGHT", -2, 0)
		end
		if col.sort then
			h:SetScript("OnClick", function ()
				if list.sortColumn == i then
					list.sortDesc = not list.sortDesc
				else
					list.sortColumn, list.sortDesc = i, col.defaultDesc or false
				end
				list:Sort()
				list:Refresh()
			end)
		else
			h:EnableMouse(false)
		end
		headers[i] = h
	end

	local rows = {}
	for r = 1, spec.rows do
		local row = CreateFrame("Button", nil, list)
		row:SetHeight(rowHeight)
		row:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2 - (r - 1) * rowHeight)
		row:SetPoint("RIGHT", header, "RIGHT")
		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		local hl = row:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints(row)
		if dragon then
			if r % 2 == 0 then solid(row, "BACKGROUND", 1, 1, 1, 0.035):SetAllPoints(row) end
			row.selected = solid(row, "BORDER", 0.25, 0.55, 1, 0.28)
			hl:SetTexture(1, 1, 1, 0.08)
		else
			-- the stock auction list's row highlight, locked on for the selection
			row.selected = row:CreateTexture(nil, "BORDER")
			row.selected:SetTexture("Interface\\HelpFrame\\HelpFrameButton-Highlight")
			row.selected:SetTexCoord(0, 1, 0, 0.578125)
			row.selected:SetBlendMode("ADD")
			hl:SetTexture("Interface\\HelpFrame\\HelpFrameButton-Highlight")
			hl:SetTexCoord(0, 1, 0, 0.578125)
			hl:SetBlendMode("ADD")
		end
		row.selected:SetAllPoints(row)
		row.selected:Hide()

		row.cells = {}
		for i, col in ipairs(spec.columns) do
			local cell = {}
			if col.icon then
				cell.icon = row:CreateTexture(nil, "ARTWORK")
				cell.icon:SetSize(rowHeight - 4, rowHeight - 4)
				cell.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
			end
			cell.text = row:CreateFontString(nil, "OVERLAY", col.font or "GameFontHighlightSmall")
			cell.text:SetJustifyH(col.align or "LEFT")
			cell.text:SetHeight(rowHeight)
			row.cells[i] = cell
		end

		row:SetScript("OnClick", function (self, button)
			if self.item and spec.onClick then spec.onClick(self.item, button) end
			list:Refresh()
		end)
		row:SetScript("OnDoubleClick", function (self)
			if self.item and spec.onDoubleClick then spec.onDoubleClick(self.item) end
		end)
		row:SetScript("OnEnter", function (self)
			local link = self.item and spec.link and spec.link(self.item)
			if link then
				local item = self.item
				RAH.ItemTooltip(self, link, spec.tooltipExtra and function (tip) spec.tooltipExtra(item, tip) end)
			end
		end)
		row:SetScript("OnLeave", RAH.HideItemTooltip)
		rows[r] = row
	end

	list.empty = list:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	list.empty:SetPoint("TOP", header, "BOTTOM", 0, -40)
	list.empty:SetWidth(360)

	local laidOutWidth
	local function layout()
		local width = header:GetWidth()
		if not width or width <= 0 or width == laidOutWidth then return end
		laidOutWidth = width
		local offsets = columnOffsets(width)
		for i, o in ipairs(offsets) do
			local h = headers[i]
			h:ClearAllPoints()
			h:SetPoint("TOPLEFT", header, "TOPLEFT", o.x, 0)
			h:SetWidth(o.w)
			for _, row in ipairs(rows) do
				local cell = row.cells[i]
				local left = o.x + 6
				if cell.icon then
					cell.icon:ClearAllPoints()
					cell.icon:SetPoint("LEFT", row, "LEFT", left, 0)
					left = left + rowHeight
				end
				cell.text:ClearAllPoints()
				cell.text:SetPoint("LEFT", row, "LEFT", left, 0)
				cell.text:SetWidth(math.max(10, o.x + o.w - left - 6))
			end
		end
	end
	list:SetScript("OnSizeChanged", layout)
	list:SetScript("OnShow", function () layout(); list:Refresh() end)

	function list:SetItems(items, keepScroll)
		self.items = items or {}
		self:Sort()
		if not keepScroll then FauxScrollFrame_SetOffset(scroll, 0); scroll:SetVerticalScroll(0) end
		self:Refresh()
	end

	function list:Sort()
		local col = self.sortColumn and spec.columns[self.sortColumn]
		if not (col and col.sort) then return end
		local desc = self.sortDesc
		local keys = {}
		for _, item in ipairs(self.items) do keys[item] = col.sort(item) end
		table.sort(self.items, function (a, b)
			local ka, kb = keys[a], keys[b]
			if ka == kb then
				return (a.order or 0) < (b.order or 0)
			end
			if ka == nil then return false end
			if kb == nil then return true end
			if type(ka) ~= type(kb) then ka, kb = tostring(ka), tostring(kb) end
			if desc then return ka > kb end
			return ka < kb
		end)
	end

	function list:SetEmptyText(text)
		spec.empty = text
		self:Refresh()
	end

	function list:Refresh()
		layout()
		local items = self.items
		FauxScrollFrame_Update(scroll, #items, spec.rows, rowHeight)
		local offset = FauxScrollFrame_GetOffset(scroll)
		for r, row in ipairs(rows) do
			local item = items[offset + r]
			row.item = item
			if item then
				for i, col in ipairs(spec.columns) do
					local cell = row.cells[i]
					cell.text:SetText(col.text and col.text(item) or "")
					if cell.icon then
						local tex = col.icon(item)
						cell.icon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")
						cell.icon:Show()
					end
				end
				if spec.isSelected and spec.isSelected(item) then row.selected:Show() else row.selected:Hide() end
				row:Show()
			else
				row:Hide()
			end
		end
		for i, h in ipairs(headers) do
			if self.sortColumn == i then
				h.arrow:Show()
				if self.sortDesc then h.arrow:SetTexCoord(0, 0.5625, 1, 0) else h.arrow:SetTexCoord(0, 0.5625, 0, 1) end
			else
				h.arrow:Hide()
			end
		end
		if #items == 0 and spec.empty then
			self.empty:SetText(spec.empty)
			self.empty:Show()
		else
			self.empty:Hide()
		end
	end

	return list
end
