-- Seeding: list a few of the item you're buying, from your bags, at a low
-- price, to draw out lower listings to buy. In its own window beside the
-- auction house - the second tab on its edge - while you're on a commodity's
-- buy page.
--
-- One click lists them (one listing, for the shortest time) and refreshes the
-- listings once, so you see what it draws out. Cancel takes your latest seed
-- of the item down again, also one click. Nothing is listed or cancelled by
-- itself.
local _, ns = ...

local WIDTH = 290
local PAD = 14
local TOP = -66          -- where the rows start, under the portrait
local DURATION = 1       -- the shortest listing time
local DISCOUNT = 0.5     -- the price starts this much under your Quick buy "Up to"
local QUOTE_TIMEOUT = 10 -- seconds to wait for the game to list it
local AFTER_POST = 0.2   -- seconds after listing before refreshing: the game finishes it first
local GREY = "|cff999999"

local frame, summary, have, amountBox, priceBoxes, hint, listButton, seedLine, cancelButton, status
local shownID          -- the item the window shows
local typedPrice = {}  -- [itemID] = the price you typed (this session)
local typedAmount = {} -- [itemID] = the amount you typed (this session)
local post             -- { itemID, qty, price, loc, at, confirming } a seed on its way
local seeds = {}       -- { { auctionID, itemID, qty, price, at = time() } } seeds you've listed, newest last
local why              -- why List is greyed out, for its tooltip
local message          -- last result, under the buttons
local elapsed = 0

local function ItemName(id)
	return (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) or ("item " .. id)
end

---------------------------------------------------------------------------
-- Price and amount
---------------------------------------------------------------------------
-- 1c under the cheapest listing that isn't yours; nil while none are loaded.
local function UnderCheapest(id)
	local AH = C_AuctionHouse
	for i = 1, AH.GetNumCommoditySearchResults(id) or 0 do
		local r = AH.GetCommoditySearchResultInfo(id, i)
		if not r then return nil end
		if r.quantity - (r.numOwnerItems or 0) > 0 then return math.max(1, r.unitPrice - 1) end
	end
	return nil
end

-- The price to list at, and where it comes from: what you typed, else 50%
-- under your Quick buy "Up to", else 1c under the cheapest listing.
local function Price(id)
	if typedPrice[id] then return typedPrice[id], "Your price." end
	local _, _, _, max = ns.QuickBuy.Session(id)
	if max and max > 0 then
		return math.max(1, math.floor(max * (1 - DISCOUNT))),
			("%d%% under your Up to (%s)."):format(DISCOUNT * 100, ns.Money(max))
	end
	local under = UnderCheapest(id)
	if under then return under, "1c under the cheapest listing." end
	return nil, "No listings loaded yet: type a price."
end

local function Amount(id) return typedAmount[id] or 1 end

-- One of the item in your bags (its location) and how many you have.
local function FindInBags(id)
	local C = C_Container
	if not (id and C and C.GetContainerNumSlots and C.GetContainerItemID and ItemLocation) then return nil, 0 end
	local found, count = nil, 0
	for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4 do
		for slot = 1, C.GetContainerNumSlots(bag) or 0 do
			if C.GetContainerItemID(bag, slot) == id then
				local info = C.GetContainerItemInfo and C.GetContainerItemInfo(bag, slot)
				count = count + (info and info.stackCount or 1)
				found = found or ItemLocation:CreateFromBagAndSlot(bag, slot)
			end
		end
	end
	return found, count
end

---------------------------------------------------------------------------
-- Your seeds
---------------------------------------------------------------------------
-- Your latest seed of the item that may still be up (they last the shortest time).
local function LiveSeed(id)
	local length = ns.DurationSeconds(DURATION)
	for i = #seeds, 1, -1 do
		local seed = seeds[i]
		if time() - seed.at > length then
			table.remove(seeds, i)
		elseif seed.itemID == id then
			return seed
		end
	end
	return nil
end

local function ForgetSeed(auctionID)
	for i = #seeds, 1, -1 do
		if seeds[i].auctionID == auctionID then return table.remove(seeds, i) end
	end
	return nil
end

local function RefreshSoon()
	if C_Timer then
		C_Timer.After(AFTER_POST, function() ns.QuickBuy.Refresh() end)
	else
		ns.QuickBuy.Refresh()
	end
end

---------------------------------------------------------------------------
-- Listing and cancelling (each one click)
---------------------------------------------------------------------------
local function List()
	local id = shownID
	if not id or post or why then return end
	local price, qty, loc = Price(id), Amount(id), FindInBags(id)
	if not (price and loc) then return end
	local _, count = FindInBags(id)
	post = { itemID = id, qty = qty, price = price, loc = loc, at = GetTime(), had = count }
	message = nil
	-- (It returns whether the game wants the price confirmed - see
	-- AUCTION_HOUSE_POST_WARNING - not whether it worked: the listing is
	-- confirmed by AUCTION_HOUSE_AUCTION_CREATED.)
	if not pcall(C_AuctionHouse.PostCommodity, loc, DURATION, qty, price) then
		post = nil
		message = "|cffff5050Not listed|r"
	end
	elapsed = 1
end

local function Cancel()
	local seed = shownID and LiveSeed(shownID)
	if not (seed and seed.auctionID) then return end
	message = nil
	pcall(C_AuctionHouse.CancelAuction, seed.auctionID)
	elapsed = 1
end

StaticPopupDialogs.FIREAUCTION_SEED_CONFIRM = {
	text = "List %s at %s each?\n\nThe auction house asks because that's far below its usual price.",
	button1 = ACCEPT or "Accept",
	button2 = CANCEL or "Cancel",
	OnAccept = function(_, p)
		if p and post == p then
			p.confirming = false
			p.at = GetTime()
			pcall(C_AuctionHouse.ConfirmPostCommodity, p.loc, DURATION, p.qty, p.price)
		end
	end,
	OnCancel = function(_, p)
		if p and post == p then post = nil end
	end,
	showAlert = true,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-- The price is far below usual: the game wants it confirmed. Blizzard's own
-- popup for that only confirms its Sell page's posts, so ours takes its place.
ns.On("AUCTION_HOUSE_POST_WARNING", function()
	local p = post
	if not p then return end
	p.confirming = true
	C_Timer.After(0, function()
		if StaticPopup_Hide then StaticPopup_Hide("AUCTION_HOUSE_POST_WARNING") end
		if post == p then
			local what = p.qty == 1 and ("1 " .. ItemName(p.itemID)) or (p.qty .. " " .. ItemName(p.itemID))
			StaticPopup_Show("FIREAUCTION_SEED_CONFIRM", what, ns.Money(p.price), p)
		end
	end)
end)

ns.On("AUCTION_HOUSE_POST_ERROR", function()
	if not post then return end
	post = nil
	message = "|cffff5050Not listed|r"
	elapsed = 1
end)

ns.On("AUCTION_HOUSE_AUCTION_CREATED", function(auctionID)
	local p = post
	if not (p and auctionID) then return end
	post = nil
	seeds[#seeds + 1] = { auctionID = auctionID, itemID = p.itemID, qty = p.qty, price = p.price, at = time() }
	message = ("Listed %d at %s"):format(p.qty, ns.Money(p.price))
	RefreshSoon()
	elapsed = 1
end)

-- In case the game doesn't say the auction was created: the items leaving
-- your bags mean it was. Wait a moment for the game's word (it carries the
-- auction's ID, needed for Cancel), then go by that.
local BAGS_GRACE = 1
ns.On("BAG_UPDATE_DELAYED", function()
	local p = post
	if not (p and not p.confirming and p.had) then return end
	local _, count = FindInBags(p.itemID)
	if count > p.had - p.qty then return end
	C_Timer.After(BAGS_GRACE, function()
		if post ~= p then return end -- the game said so after all
		post = nil
		-- Its ID (for Cancel) comes from your auctions list, read again shortly (Sales.lua).
		seeds[#seeds + 1] = { itemID = p.itemID, qty = p.qty, price = p.price, at = time() }
		message = ("Listed %d at %s"):format(p.qty, ns.Money(p.price))
		RefreshSoon()
		if ns.Sales and ns.Sales.QueryOwned then ns.Sales.QueryOwned(1) end
		elapsed = 1
	end)
end)

-- Your auctions list: the IDs of seeds the game didn't give one for - the
-- newest of your listings of that item, amount and price not already taken.
ns.On("OWNED_AUCTIONS_UPDATED", function()
	local AH = C_AuctionHouse
	if not (AH.GetNumOwnedAuctions and AH.GetOwnedAuctionInfo) then return end
	local taken = {}
	for _, seed in ipairs(seeds) do
		if seed.auctionID then taken[seed.auctionID] = true end
	end
	for _, seed in ipairs(seeds) do
		if not seed.auctionID then
			local best
			for i = 1, AH.GetNumOwnedAuctions() or 0 do
				local ok, a = pcall(AH.GetOwnedAuctionInfo, i)
				if ok and a and a.auctionID and not taken[a.auctionID] and a.status ~= 1
					and a.itemKey and a.itemKey.itemID == seed.itemID and a.quantity == seed.qty
					and a.buyoutAmount == seed.price and (not best or a.auctionID > best) then
					best = a.auctionID
				end
			end
			if best then
				seed.auctionID, taken[best] = best, true
				elapsed = 1
			end
		end
	end
end)

ns.On("AUCTION_CANCELED", function(auctionID)
	if not ForgetSeed(auctionID) then return end
	message = "Seed cancelled"
	RefreshSoon()
	elapsed = 1
end)

-- Sold or expired: no longer yours to cancel.
ns.On("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", function(_, _, auctionID)
	if auctionID then ForgetSeed(auctionID) end
end)

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------
local function SetCoinBoxes(boxes, copper)
	local g, s, c = "", "", ""
	if copper then
		g = copper >= 10000 and tostring(math.floor(copper / 10000)) or ""
		s, c = tostring(math.floor(copper / 100) % 100), tostring(copper % 100)
	end
	if boxes[1]:GetText() ~= g then boxes[1]:SetText(g) end
	if boxes[2]:GetText() ~= s then boxes[2]:SetText(s) end
	if boxes[3]:GetText() ~= c then boxes[3]:SetText(c) end
end

-- The copper in the price boxes, or nil if they're all empty.
local function ReadCoinBoxes(boxes)
	local g, sv, c = boxes[1]:GetText(), boxes[2]:GetText(), boxes[3]:GetText()
	if g == "" and sv == "" and c == "" then return nil end
	return math.floor(tonumber(g) or 0) * 10000 + math.min(99, math.floor(tonumber(sv) or 0)) * 100
		+ math.min(99, math.floor(tonumber(c) or 0))
end

local function Typing()
	if amountBox:HasFocus() then return true end
	for _, box in ipairs(priceBoxes) do
		if box:HasFocus() then return true end
	end
	return false
end

local function Update(id)
	if id ~= shownID then
		shownID, message = id, nil
	end
	ns.SideWindowTitle(frame, "Seed listing")
	local texture = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)
	ns.SideWindowIcon(frame, texture or "Interface\\Icons\\INV_Misc_QuestionMark")

	local loc, count = FindInBags(id)
	summary:SetText(ItemName(id))
	have:SetText(("You have %d in your bags"):format(count))

	local price, source = Price(id)
	local qty = Amount(id)
	if not Typing() then
		SetCoinBoxes(priceBoxes, price)
		if amountBox:GetText() ~= tostring(qty) then amountBox:SetText(tostring(qty)) end
	end
	hint:SetText(GREY .. source .. "|r")

	local ready = C_AuctionHouse.IsThrottledMessageSystemReady
	why = nil
	if post then
		why = "Listing..."
	elseif ns.QuickBuy.Busy() then
		why = "Buying..."
	elseif not loc then
		why = "You have none in your bags."
	elseif count < qty then
		why = ("You have only %d."):format(count)
	elseif not price then
		why = "Type a price first."
	elseif ns.QuickBuy.BlizzardDialogOpen() then
		why = "Close the Buy dialog first."
	elseif ready and not ready() then
		why = "Waiting for the auction house."
	end
	listButton:SetText(post and "Listing..." or price and ("List %d for %s"):format(qty, ns.Money(price * qty))
		or ("List %d"):format(qty))
	listButton:SetEnabled(why == nil)

	local seed = LiveSeed(id)
	if seed then
		local left = math.max(0, math.floor((seed.at + ns.DurationSeconds(DURATION) - time()) / 60))
		seedLine:SetText(("%d at %s each, %d min left"):format(seed.qty, ns.Money(seed.price), left))
	else
		seedLine:SetText(GREY .. "None up|r")
	end
	cancelButton:SetEnabled(seed ~= nil and seed.auctionID ~= nil and not post and not (ready and not ready()))
	status:SetText(message or "")
end

local function Label(text, font)
	local fs = frame:CreateFontString(nil, "ARTWORK", font or "GameFontNormal")
	fs:SetText(text)
	return fs
end

local function Box(width, letters, onDone)
	local box = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	box:SetSize(width, 20)
	box:SetAutoFocus(false)
	box:SetNumeric(true)
	box:SetMaxLetters(letters)
	box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	box:SetScript("OnTabPressed", function(self)
		if self.next then self.next:SetFocus() else self:ClearFocus() end
	end)
	box:SetScript("OnEditFocusLost", function()
		if shownID then ns.SafeCall(onDone) end
		elapsed = 1
	end)
	return box
end

local function Tooltip(widget, title, text)
	widget:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(title, 1, 1, 1)
		local lines = type(text) == "function" and { text() } or { text }
		for _, line in ipairs(lines) do GameTooltip:AddLine(line, nil, nil, nil, true) end
		GameTooltip:Show()
	end)
	widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function Create()
	if not (AuctionHouseFrame and ns.SideWindow) then return end
	-- Beside the auction house window, at its bottom, until you drag it.
	frame = ns.SideWindow("FireAuctionSeed", WIDTH, TOP + 6, "seedPoint", function(f)
		f:SetPoint("BOTTOMLEFT", AuctionHouseFrame, "BOTTOMRIGHT", 38, 0)
	end, "seedWindow")
	frame:SetHeight(-TOP + 192)

	-- Beside the portrait: the item, and how many you have.
	summary = Label("", "GameFontHighlight")
	summary:SetPoint("TOPLEFT", 64, -32)
	summary:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
	summary:SetJustifyH("LEFT")
	have = Label("", "GameFontHighlightSmall")
	have:SetPoint("TOPLEFT", summary, "BOTTOMLEFT", 0, -4)

	local y = TOP - 8
	local amountLabel = Label("Amount")
	amountLabel:SetPoint("TOPLEFT", PAD, y - 3)
	amountBox = Box(40, 4, function()
		local n = tonumber(amountBox:GetText())
		typedAmount[shownID] = n and n > 0 and math.floor(n) or nil
	end)
	amountBox:SetPoint("TOPLEFT", 80, y)
	Tooltip(amountBox, "Amount", "How many to list, as one listing. Empty: 1.")

	y = y - 28
	local priceLabel = Label("Price")
	priceLabel:SetPoint("TOPLEFT", PAD, y - 3)
	local function SavePrice() typedPrice[shownID] = ReadCoinBoxes(priceBoxes) end
	priceBoxes = { Box(34, 4, SavePrice), Box(22, 2, SavePrice), Box(22, 2, SavePrice) }
	priceBoxes[1]:SetPoint("TOPLEFT", 80, y)
	local last = priceBoxes[1]
	for i, coin in ipairs({ "Gold", "Silver", "Copper" }) do
		local icon = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		icon:SetPoint("LEFT", priceBoxes[i], "RIGHT", 2, 0)
		icon:SetText("|TInterface\\MoneyFrame\\UI-" .. coin .. "Icon:0|t")
		if priceBoxes[i + 1] then priceBoxes[i + 1]:SetPoint("LEFT", icon, "RIGHT", 8, 0) end
		last = icon
	end
	local each = Label("each", "GameFontHighlight")
	each:SetPoint("LEFT", last, "RIGHT", 4, 0)
	amountBox.next, priceBoxes[1].next, priceBoxes[2].next = priceBoxes[1], priceBoxes[2], priceBoxes[3]
	for _, box in ipairs(priceBoxes) do
		Tooltip(box, "Price", "What to list each one at. Starts " .. DISCOUNT * 100 .. "% under your Quick buy \"Up to\" (or 1c under "
			.. "the cheapest listing without one); empty the boxes to go back to that.")
	end

	y = y - 24
	hint = Label("", "GameFontHighlightSmall")
	hint:SetPoint("TOPLEFT", 80, y)

	y = y - 20
	listButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	listButton:SetHeight(24)
	listButton:SetPoint("TOPLEFT", PAD, y)
	listButton:SetPoint("TOPRIGHT", -PAD, y)
	listButton:SetMotionScriptsWhileDisabled(true)
	listButton:SetScript("OnClick", function() ns.SafeCall(List) end)
	Tooltip(listButton, "List", function()
		local id = shownID
		local qty, price = Amount(id), Price(id)
		local ok, deposit = pcall(C_AuctionHouse.CalculateCommodityDeposit, id, DURATION, qty)
		local text = ("List %d from your bags at %s each, for %s, then refresh the listings."):format(qty,
			price and ns.Money(price) or "?", AUCTION_DURATION_ONE or "the shortest time")
		local depositText = ok and deposit and ("Deposit: " .. ns.Money(deposit)) or nil
		local whyText = why and ("|cffff5050" .. why .. "|r") or nil
		return text, depositText, whyText
	end)

	y = y - 36
	local seedLabel = Label("Your seed")
	seedLabel:SetPoint("TOPLEFT", PAD, y)
	seedLine = Label("", "GameFontHighlightSmall")
	seedLine:SetPoint("TOPLEFT", PAD, y - 18)
	cancelButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	cancelButton:SetSize(80, 22)
	cancelButton:SetPoint("TOPRIGHT", -PAD, y + 2)
	cancelButton:SetText(CANCEL or "Cancel")
	cancelButton:SetMotionScriptsWhileDisabled(true)
	cancelButton:SetScript("OnClick", function() ns.SafeCall(Cancel) end)
	Tooltip(cancelButton, "Cancel seed", function()
		local seed = shownID and LiveSeed(shownID)
		if not seed then return "No seed of yours is up for this item." end
		if not seed.auctionID then return "Finding your seed in your auctions..." end
		local ok, cost = pcall(C_AuctionHouse.GetCancelCost, seed.auctionID)
		return ("Take down your %d at %s."):format(seed.qty, ns.Money(seed.price)),
			ok and cost and cost > 0 and ("Costs " .. ns.Money(cost) .. ".") or nil
	end)

	status = Label("", "GameFontHighlightSmall")
	status:SetPoint("TOPLEFT", PAD, y - 40)
	status:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
	status:SetJustifyH("LEFT")

	-- Its tab on the auction house window's edge (the second).
	frame.tab = ns.SideTab(2, "Interface\\Icons\\INV_Misc_Note_01", "Seed listing", "seedWindow",
		function() elapsed = 1 end)

	-- Shows and updates it a few times a second while the auction house is open.
	local driver = CreateFrame("Frame", nil, AuctionHouseFrame)
	driver:SetScript("OnUpdate", function(_, dt)
		if post and not post.confirming and GetTime() - post.at > QUOTE_TIMEOUT then
			post = nil
			message = "|cffff5050Not listed:|r no answer from the auction house"
		end
		elapsed = elapsed + dt
		if elapsed < 0.25 then return end
		elapsed = 0
		local id = ns.QuickBuy and ns.QuickBuy.Item()
		frame.tab:SetShown(id ~= nil)
		frame:SetShown(id ~= nil and ns.db.seedWindow)
		if id and ns.db.seedWindow then ns.SafeCall(Update, id) end
	end)
	driver:SetScript("OnShow", function() elapsed = 1 end)
end

ns.On("AUCTION_HOUSE_SHOW", function()
	if not frame then Create() end
end)
