-- The RetailAH window: chrome, tabs along the bottom, the player's money, a status line and the
-- Classic button. Each tab file adds its panel with RAH.AddTab.

local RAH = RetailAH

local WIDTH, HEIGHT = 832, 540

local frame = CreateFrame("Frame", "RetailAHFrame", UIParent)
frame:SetSize(WIDTH, HEIGHT)
frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 16, -104)
frame:EnableMouse(true)
frame:SetToplevel(true)
frame:Hide()
UIPanelWindows["RetailAHFrame"] = { area = "doublewide", pushable = 0 }

local dragon = RAH.DressWindow(frame)

local title = frame.chrome:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOP", frame, "TOP", 0, -5)
title:SetText(AUCTION_HOUSE or "Auction House")

-- The auctioneer's face in the corner ring, as the stock window has it.
local portrait
if dragon then
	portrait = frame:CreateTexture(nil, "ARTWORK")
	portrait:SetPoint("TOPLEFT", frame, "TOPLEFT", -2, 4)
	portrait:SetSize(56, 56)
end

local close = CreateFrame("Button", "RetailAHFrameCloseButton", frame, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 2, 2)
do
	local _, CP = RAH.Dragon()
	if CP and CP.ModernizeCloseButton then
		CP.ModernizeCloseButton(close, frame.chrome, 1, 0)
		close:SetFrameLevel(frame.chrome:GetFrameLevel() + 5)
	end
end

-- Content area shared by every tab.
local content = CreateFrame("Frame", nil, frame)
content:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, dragon and -28 or -30)
content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 34)
RAH.content = content

-----------------------------------------
-- bottom bar: money, status, classic

local money = RAH.CreateMoneyText(frame, "GameFontHighlight")
money:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 18, 12)

local status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
status:SetPoint("BOTTOM", frame, "BOTTOM", 60, 13)
status:SetWidth(430)
status:SetJustifyH("CENTER")

local statusToken = 0
-- A line of feedback at the bottom of the window; errors in red.
function RAH.Status(text, isError)
	statusToken = statusToken + 1
	local mine = statusToken
	status:SetText(text or "")
	if isError then status:SetTextColor(1, 0.25, 0.25) else status:SetTextColor(1, 0.82, 0) end
	RAH.After(8, function () if mine == statusToken then status:SetText("") end end)
end

local classic = RAH.CreateButton(frame, "Classic", 80, 20)
classic:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 8)
classic:SetScript("OnClick", function () RAH.ShowClassic() end)
classic:SetScript("OnEnter", function (self)
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:AddLine("Classic auction window")
	GameTooltip:AddLine("Use the old window (and Auctionator) for this visit. |cffffd200/rah classic|r makes it the default.", 1, 1, 1, true)
	GameTooltip:Show()
end)
classic:SetScript("OnLeave", function () GameTooltip:Hide() end)

RAH.On("MONEY", function () money:SetMoney(GetMoney()) end)

-----------------------------------------
-- tabs

local panels, tabs = {}, {}

function RAH.SelectTab(index)
	PanelTemplates_SetTab(frame, index)
	for i, panel in ipairs(panels) do
		if i == index then panel:Show() else panel:Hide() end
	end
	RAH.currentTab = index
	RAH.Fire("TAB", index)
end

function RAH.AddTab(name)
	local index = #panels + 1
	local panel = CreateFrame("Frame", nil, content)
	panel:SetAllPoints(content)
	panel:Hide()
	panels[index] = panel

	local tab = RAH.CreateTab(frame, index, name, RAH.SelectTab)
	if index == 1 then
		tab:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 11, dragon and 2 or 4)
	else
		tab:SetPoint("TOPLEFT", tabs[index - 1], "TOPRIGHT", dragon and 1 or -15, 0)
	end
	tabs[index] = tab
	PanelTemplates_SetNumTabs(frame, index)
	return panel, index
end

-----------------------------------------

frame:SetScript("OnShow", function ()
	PlaySound("AuctionWindowOpen")
	if portrait then SetPortraitTexture(portrait, "npc") end
	money:SetMoney(GetMoney())
	status:SetText("")
	RAH.SelectTab(RAH.currentTab or 1)
	OpenAllBags(true)
end)

frame:SetScript("OnHide", function ()
	PlaySound("AuctionWindowClose")
	StaticPopup_Hide("RETAILAH_CONFIRM")
	-- Closing the window ends the visit, unless the player is switching to the classic window.
	if RAH.active and not RAH.IsSwitchingToClassic() then
		RAH.active = false
		CloseAuctionHouse()
	end
end)

-----------------------------------------
-- one confirmation dialog for every purchase, bid and cancel

StaticPopupDialogs["RETAILAH_CONFIRM"] = {
	text = "%s",
	button1 = ACCEPT,
	button2 = CANCEL,
	OnAccept = function (self, data) if data then data() end end,
	timeout = 0,
	exclusive = 1,
	hideOnEscape = 1,
}

function RAH.Confirm(text, onAccept)
	local dialog = StaticPopup_Show("RETAILAH_CONFIRM", text)
	if dialog then dialog.data = onAccept end
end
