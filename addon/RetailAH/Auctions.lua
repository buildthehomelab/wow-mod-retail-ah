-- Auctions tab: the player's own listings (cancel them) and the auctions they hold the top bid
-- on (raise the bid or buy them out).

local RAH = RetailAH

local panel = RAH.AddTab("Auctions")

local state = { view = "auctions", selected = nil, req = nil }

local function toggle(text)
	local btn = RAH.CreateButton(panel, text, 110, 22)
	return btn
end

local showAuctions = toggle(AUCTIONS or "Auctions")
showAuctions:SetPoint("TOPLEFT", panel, "TOPLEFT", 2, -2)
local showBids = toggle(BIDS or "Bids")
showBids:SetPoint("LEFT", showAuctions, "RIGHT", 6, 0)

local summary = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
summary:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -4, -8)
summary:SetJustifyH("RIGHT")

local pane = RAH.CreateInset(panel)
pane:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -30)
pane:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 36)

local function nameText(a)
	local info = RAH.Item(a.link)
	if not info then return "|cff808080Loading...|r" end
	local _, _, _, hex = RAH.QualityColor(info.quality)
	return hex .. info.name .. "|r" .. (a.count > 1 and ("|cffffffff x" .. RAH.Number(a.count) .. "|r") or "")
end
local function nameIcon(a) local info = RAH.Item(a.link) return info and info.texture end
local function nameSort(a) local info = RAH.Item(a.link) return info and info.name or "~" end
local function isSelected(a) return state.selected == a end

local updateButtons

local ownList = RAH.CreateList(pane, {
	rows = 19,
	columns = {
		{ title = "Name", icon = nameIcon, text = nameText, sort = nameSort },
		{ title = "Bid", width = 130, align = "RIGHT",
			text = function (a)
				local text = RAH.Money(a.bid)
				return bit.band(a.flags, RAH.AUCTION_HAS_BID) ~= 0 and ("|cff20ff20" .. text .. "|r") or ("|cffa0a0a0" .. text .. "|r")
			end,
			sort = function (a) return a.bid end },
		{ title = "Buyout", width = 130, align = "RIGHT",
			text = function (a) return a.buyout > 0 and RAH.Money(a.buyout) or "|cff808080--|r" end,
			sort = function (a) return a.buyout end },
		{ title = "Time Left", width = 90, align = "RIGHT", text = function (a) return RAH.TimeLeft(a.timeLeft) end,
			sort = function (a) return a.timeLeft end },
		{ title = "Status", width = 90, align = "CENTER",
			text = function (a) return bit.band(a.flags, RAH.AUCTION_HAS_BID) ~= 0 and "|cff20ff20Has bid|r" or "" end },
	},
	defaultSort = 4,
	link = function (a) return a.link end,
	isSelected = isSelected,
	onClick = function (a) state.selected = a; updateButtons() end,
	empty = "You have no auctions up.",
})
ownList:SetPoint("TOPLEFT", pane, "TOPLEFT", 4, -4)
ownList:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -4, 4)

local bidList = RAH.CreateList(pane, {
	rows = 19,
	columns = {
		{ title = "Name", icon = nameIcon, text = nameText, sort = nameSort },
		{ title = "Your Bid", width = 130, align = "RIGHT", text = function (a) return "|cff20ff20" .. RAH.Money(a.bid) .. "|r" end,
			sort = function (a) return a.bid end },
		{ title = "Buyout", width = 130, align = "RIGHT",
			text = function (a) return a.buyout > 0 and RAH.Money(a.buyout) or "|cff808080--|r" end,
			sort = function (a) return a.buyout end },
		{ title = "Time Left", width = 90, align = "RIGHT", text = function (a) return RAH.TimeLeft(a.timeLeft) end,
			sort = function (a) return a.timeLeft end },
	},
	defaultSort = 4,
	link = function (a) return a.link end,
	isSelected = isSelected,
	onClick = function (a) state.selected = a; updateButtons() end,
	empty = "You aren't the top bidder on anything. When someone outbids you, the money comes back by mail.",
})
bidList:SetPoint("TOPLEFT", pane, "TOPLEFT", 4, -4)
bidList:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -4, 4)
bidList:Hide()

-- bottom row
local cancelButton = RAH.CreateButton(panel, "Cancel Auction", 140, 24)
cancelButton:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -2, 4)

local bidLabel = RAH.CreateLabel(panel, "Bid", "GameFontNormal")
local bidInput = RAH.CreateMoneyInput(panel)
bidInput:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 40, 8)
bidLabel:SetPoint("RIGHT", bidInput, "LEFT", -10, 0)
local bidButton = RAH.CreateButton(panel, "Bid", 100, 24)
bidButton:SetPoint("LEFT", bidInput, "RIGHT", 16, 0)
local buyoutButton = RAH.CreateButton(panel, "Buy Now", 120, 24)
buyoutButton:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -2, 4)

local load

function updateButtons()
	local a = state.selected
	if state.view == "auctions" then
		cancelButton:Show()
		bidLabel:Hide(); bidInput:Hide(); bidButton:Hide(); buyoutButton:Hide()
		RAH.SetEnabled(cancelButton, a ~= nil)
		ownList:Refresh()
	else
		cancelButton:Hide()
		bidLabel:Show(); bidInput:Show(); bidButton:Show(); buyoutButton:Show()
		RAH.SetEnabled(bidButton, a ~= nil and (a.buyout == 0 or a.minBid < a.buyout))
		RAH.SetEnabled(buyoutButton, a ~= nil and a.buyout > 0 and GetMoney() >= a.buyout - a.bid)
		if a then bidInput:SetCopper(a.minBid) end
		bidList:Refresh()
	end
	RAH.SetEnabled(showAuctions, state.view ~= "auctions")
	RAH.SetEnabled(showBids, state.view ~= "bids")
end

function load()
	if not RAH.serverReady then return end
	local token = {}
	state.req = token
	local selectedId = state.selected and state.selected.id
	state.selected = nil

	if state.view == "auctions" then
		RAH.Request("O", nil, function (result)
			if state.req ~= token or not result then return end
			local list, total = {}, 0
			for i, r in ipairs(result.rows) do
				local a = { id = r[1], entry = r[2], count = r[3], bid = r[4], buyout = r[5], timeLeft = r[6], flags = r[7],
					link = RAH.ItemString(r[2], r[8], r[9]), order = i }
				if a.id == selectedId then state.selected = a end
				total = total + a.buyout
				table.insert(list, a)
			end
			ownList:SetItems(list, true)
			summary:SetText(#list .. (#list == 1 and " auction" or " auctions") .. (total > 0 and (", " .. RAH.Money(total) .. " in buyouts") or ""))
			updateButtons()
		end)
	else
		RAH.Request("BL", nil, function (result)
			if state.req ~= token or not result then return end
			local list = {}
			for i, r in ipairs(result.rows) do
				local a = { id = r[1], entry = r[2], count = r[3], bid = r[4], minBid = r[5], buyout = r[6], timeLeft = r[7],
					link = RAH.ItemString(r[2], r[8], r[9]), order = i }
				if a.id == selectedId then state.selected = a end
				table.insert(list, a)
			end
			bidList:SetItems(list, true)
			summary:SetText(#list .. (#list == 1 and " bid" or " bids"))
			updateButtons()
		end)
	end
end

local function setView(view)
	state.view = view
	state.selected = nil
	if view == "auctions" then ownList:Show(); bidList:Hide() else ownList:Hide(); bidList:Show() end
	updateButtons()
	load()
end

showAuctions:SetScript("OnClick", function () setView("auctions") end)
showBids:SetScript("OnClick", function () setView("bids") end)

cancelButton:SetScript("OnClick", function ()
	local a = state.selected
	if not a then return end
	local info = RAH.Item(a.link)
	local text = "Cancel your auction of " .. (info and info.link or "this item") .. "?\nThe deposit is not refunded."
	if bit.band(a.flags, RAH.AUCTION_HAS_BID) ~= 0 then
		text = text .. "\nSomeone has bid on it: you pay the house cut (" .. RAH.Money(math.floor(a.bid * (RAH.cutPercent or 5) / 100)) .. ")."
	end
	RAH.Confirm(text, function ()
		RAH.QuietChat(3)
		RAH.Request("X", { a.id }, function (result)
			local status = result and result[1]
			if status == "ok" then
				RAH.Status("Auction cancelled. The item is in your mailbox.")
			elseif status == "gone" then
				RAH.Status("That auction has already sold or expired.", true)
			else
				RAH.Status("Couldn't cancel that auction.", true)
			end
			load()
		end)
	end)
end)

local function bid(a, price, verb)
	local info = RAH.Item(a.link)
	RAH.Confirm(string.format("%s %s for %s?", verb, info and info.link or "this item", RAH.Money(price)), function ()
		RAH.QuietChat(3)
		RAH.Request("P", { a.id, price }, function (result)
			local status = result and result[1]
			if status == "bought" then
				RAH.Status("Bought. It's in your mailbox.")
				PlaySound("LOOTWINDOWCOINSOUND")
			elseif status == "bid" then
				RAH.Status("Bid raised.")
			elseif status == "gone" then
				RAH.Status("That auction is gone.", true)
			else
				RAH.Status("That didn't go through.", true)
			end
			load()
		end)
	end)
end

bidButton:SetScript("OnClick", function ()
	local a = state.selected
	if not a then return end
	local price = bidInput:GetCopper()
	if price < a.minBid then
		RAH.Status("The bid must be at least " .. RAH.Money(a.minBid) .. ".", true)
	elseif a.buyout > 0 and price >= a.buyout then
		bid(a, a.buyout, "Buy")
	else
		bid(a, price, "Raise your bid on")
	end
end)
buyoutButton:SetScript("OnClick", function ()
	local a = state.selected
	if a and a.buyout > 0 then bid(a, a.buyout, "Buy") end
end)

RAH.On("ITEM_INFO", function ()
	if panel:IsShown() then
		RAH.Debounce("auctions-items", 0.2, function () ownList:Refresh(); bidList:Refresh() end)
	end
end)
RAH.On("POSTED", function () if panel:IsShown() then load() end end)
RAH.On("READY", function () if panel:IsShown() then load() end end)
RAH.On("MONEY", function () if panel:IsShown() and state.view == "bids" then updateButtons() end end)

panel:SetScript("OnShow", function ()
	updateButtons()
	load()
end)
