-- Quick buy, under the Buy button when you're looking at a commodity (Silk
-- Cloth...): "Want [100]  Up to [1]s [75]c" and one button that buys what's
-- listed at or under that price, up to what you still want - one click, no
-- confirmation popup. The numbers - what reselling or crafting it makes, what
-- you've spent - are in the panel to the right (BuyInfo.lua).
--
-- Every purchase is your own click: the game only lets a purchase start from
-- one. Nothing is bought, searched or retried by itself - it works off the
-- listings on screen, refreshed by you (a refresh button sits next to it) and
-- once after each purchase, like Blizzard's own Buy popup. The game quotes the
-- final price before buying; if it's more than the button said (someone got
-- the cheap ones first), the purchase is cancelled instead.
--
-- The session - how many you've bought, what they cost, and a log - is kept
-- per item until you press Clear (through /reload and logouts). Purchases
-- through Blizzard's own Buy popup count too.
local _, ns = ...

local QuickBuy = {}
ns.QuickBuy = QuickBuy

local QUOTE_TIMEOUT = 10 -- seconds to wait for the game's price quote / purchase
local AH_CUT = 0.05

local panel, button, clear, status, wantBox, coinBoxes
local itemID          -- the commodity on screen
local plan            -- { quantity, total } the button would buy right now
local pending         -- { itemID, quantity, total, stage = "quote"/"buying", at }
local summarized = {} -- [itemID] = how many were bought at the last summary
local boughtNow = {}  -- [itemID] = true: bought some since the auction house opened
local outside         -- { itemID, quantity, total } a purchase through Blizzard's Buy popup
local LOG_SIZE = 20   -- purchases kept in the session log
local message         -- last result, shown under the button until the next change
-- Lost to someone else: the cheap ones went before the quote, or between the
-- quote and the purchase.
local TAKEN = "|cffff5050Not available|r (someone else bought them)"

-- The lowest price each that sells `count` of them for more than `total`,
-- after the auction house's cut.
local function RelistPrice(total, count)
	local price = math.floor(total / ((1 - AH_CUT) * count)) + 1
	while math.floor(price * count * (1 - AH_CUT)) <= total do price = price + 1 end
	return price
end

local function Settings(id)
	ns.db.quickBuy[id] = ns.db.quickBuy[id] or {}
	return ns.db.quickBuy[id]
end

-- The session lives with the item's settings (saved):
--   bought, spent = how many, and what they cost in all
--   log = { { quantity, total, time() }, ... } newest first
local function Record(id, quantity, total)
	local s = Settings(id)
	s.bought = (s.bought or 0) + quantity
	s.spent = (s.spent or 0) + total
	s.log = s.log or {}
	table.insert(s.log, 1, { quantity, total, time() })
	while #s.log > LOG_SIZE do table.remove(s.log) end
	boughtNow[id] = true
end

local function ClearSession(id)
	local s = Settings(id)
	s.bought, s.spent, s.log = nil, nil, nil
	summarized[id] = nil
end

local function ItemName(id)
	return (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) or ("item " .. id)
end

-- What it usually sells for here: the average of the trend period's daily
-- prices (market prices, from your scans), or the latest scan's.
local function UsualPrice(id)
	local rec = ns.Data.Get(id)
	if not rec then return nil end
	local from, sum, n = ns.Data.Today() - ns.Data.TrendDays(), 0, 0
	for day, price in pairs(rec.d or {}) do
		if day > from then sum, n = sum + price, n + 1 end
	end
	if n > 0 then return math.floor(sum / n + 0.5) end
	return ns.Data.Market(rec)
end

-- What the button would take from each listing on screen, cheapest first:
-- { { price, quantity, take }, ... } - at or under maxPrice, up to quantity,
-- not your own; with "Cheapest listing only" on, only at the lowest of those
-- prices. nil when the listings aren't loaded yet.
local function Walk(id, maxPrice, quantity)
	local AH = C_AuctionHouse
	local rows, count, level = {}, 0, nil
	for i = 1, AH.GetNumCommoditySearchResults(id) or 0 do
		local r = AH.GetCommoditySearchResultInfo(id, i)
		if not r then return nil end
		local take = 0
		if maxPrice and r.unitPrice <= maxPrice and count < quantity and not (level and r.unitPrice > level) then
			take = math.max(0, math.min(r.quantity - (r.numOwnerItems or 0), quantity - count))
			if take > 0 and ns.db.quickBuyCheapest then level = level or r.unitPrice end
		end
		count = count + take
		rows[#rows + 1] = { price = r.unitPrice, quantity = r.quantity, take = take }
	end
	return rows
end

-- What you'd relist at: the cheapest listing left on screen after what the
-- button would buy - yours count, you'd list next to them. nil when the
-- listings aren't loaded.
local function ListedSellPrice(id, maxPrice, quantity)
	for _, row in ipairs(Walk(id, maxPrice, quantity) or {}) do
		if row.take < row.quantity then return row.price end
	end
	return nil
end

local function Remaining(id)
	local want = Settings(id).want
	if not want then return math.huge end
	return math.max(0, want - (Settings(id).bought or 0))
end

-- What the button would buy right now: how many, and what they cost in all.
local function Available(id, maxPrice, quantity)
	local count, total = 0, 0
	for _, row in ipairs(Walk(id, maxPrice, quantity) or {}) do
		count = count + row.take
		total = total + row.take * row.price
	end
	return count, total
end

-- "Silk Cloth: bought 100 for 1g 75s (1s 75c each). Relist above 1s 84c
-- each to make a profit." Once per batch of purchases.
local function Summary(id)
	local s = Settings(id)
	local count = s.bought or 0
	if count <= 0 or summarized[id] == count then return end
	summarized[id] = count
	local total = s.spent or 0
	ns.Print(("|cffffd100%s:|r bought %d for %s (%s each). Break-even: %s each."):format(ItemName(id), count, ns.Money(total), ns.Money(math.floor(total / count + 0.5)),
		ns.Money(RelistPrice(total, count))))
end

local function BlizzardDialogOpen()
	local dialog = AuctionHouseFrame and AuctionHouseFrame.BuyDialog
	return dialog and dialog:IsShown()
end

local function SetCoins(max)
	max = max or 0
	local g = max >= 10000 and tostring(math.floor(max / 10000)) or ""
	local s, c = tostring(math.floor(max / 100) % 100), tostring(max % 100)
	-- Only on a change, so a box you're typing in isn't rewritten.
	if coinBoxes[1]:GetText() ~= g then coinBoxes[1]:SetText(g) end
	if coinBoxes[2]:GetText() ~= s then coinBoxes[2]:SetText(s) end
	if coinBoxes[3]:GetText() ~= c then coinBoxes[3]:SetText(c) end
end

-- The button's text, from what's listed now.
local function Update()
	if not (panel and panel:IsShown() and itemID) then return end
	local s = Settings(itemID)
	local max = s.max
	plan = nil
	local text, enabled = nil, false
	if pending then
		text = pending.stage == "quote" and "Checking the price..." or "Buying..."
	elseif not max or max <= 0 then
		text = "Set the most to pay"
	elseif Remaining(itemID) <= 0 then
		text = ("Got all %d"):format(s.want)
	else
		local count, total = Available(itemID, max, Remaining(itemID))
		if count <= 0 then
			text = "None listed"
		elseif total > GetMoney() then
			text = "Not enough money (" .. ns.Money(total) .. ")"
		elseif BlizzardDialogOpen() then
			text = ("Buy %d for %s"):format(count, ns.Money(total))
		else
			plan = { quantity = count, total = total }
			text = ("Buy %d for %s"):format(count, ns.Money(total))
			enabled = true
		end
	end
	button:SetText(text)
	button:SetEnabled(enabled)
	clear:SetEnabled(not pending and (s.bought or 0) > 0)

	local line = message
	local count = s.bought or 0
	if not line and count > 0 then
		line = s.want and ("Bought %d of %d"):format(count, s.want) or ("Bought %d"):format(count)
	end
	status:SetText(line or "")
end

local function Refresh()
	local frame = AuctionHouseFrame
	if not (frame and frame.RefreshSearchResults and AuctionHouseSearchContext and itemID) then return end
	pcall(frame.RefreshSearchResults, frame, AuctionHouseSearchContext.BuyCommodities,
		C_AuctionHouse.MakeItemKey(itemID))
end

local function Finish(text)
	pending = nil
	message = text
	Refresh()
	Update()
end

local function Buy()
	if pending or not plan or not itemID then return end
	pending = { itemID = itemID, quantity = plan.quantity, total = plan.total, stage = "quote", at = GetTime() }
	message = nil
	C_AuctionHouse.StartCommoditiesPurchase(itemID, plan.quantity)
	Update()
end

ns.On("COMMODITY_PRICE_UPDATED", function(unitPrice, totalPrice)
	if not pending and outside then outside.total = totalPrice end
	if not (pending and pending.stage == "quote") then return end
	if totalPrice > pending.total then
		C_AuctionHouse.CancelCommoditiesPurchase()
		return Finish(TAKEN)
	end
	pending.stage, pending.at, pending.total = "buying", GetTime(), totalPrice
	C_AuctionHouse.ConfirmCommoditiesPurchase(pending.itemID, pending.quantity)
	Update()
end)

ns.On("COMMODITY_PRICE_UNAVAILABLE", function()
	if not pending then return end
	C_AuctionHouse.CancelCommoditiesPurchase()
	Finish(TAKEN)
end)

ns.On("COMMODITY_PURCHASE_SUCCEEDED", function()
	if not pending and outside and outside.total then
		-- Bought through Blizzard's Buy popup: counts toward the session too.
		Record(outside.itemID, outside.quantity, outside.total)
		outside = nil
		return Update()
	end
	if not (pending and pending.stage == "buying") then return end
	local id, quantity, total = pending.itemID, pending.quantity, pending.total
	Record(id, quantity, total)
	if PlaySound and SOUNDKIT then PlaySound(SOUNDKIT.LOOT_WINDOW_COIN_SOUND) end
	local want = Settings(id).want
	local left = want and math.max(0, want - Settings(id).bought)
	ns.Print(("bought %d %s for %s%s"):format(quantity, ItemName(id), ns.Money(total),
		left and (left > 0 and (" (%d more to go)"):format(left) or " - that's all you wanted") or ""))
	if left == 0 then Summary(id) end
	Finish(nil)
end)

ns.On("COMMODITY_PURCHASE_FAILED", function()
	if not pending then
		outside = nil
		return
	end
	Finish(TAKEN)
end)

-- Purchases through Blizzard's Buy popup: what it starts (and confirms) and
-- the price the game quotes for it. (Quick buy's own are `pending`.)
if C_AuctionHouse and C_AuctionHouse.StartCommoditiesPurchase then
	hooksecurefunc(C_AuctionHouse, "StartCommoditiesPurchase", function(id, quantity)
		if not pending then outside = { itemID = id, quantity = quantity } end
	end)
	hooksecurefunc(C_AuctionHouse, "ConfirmCommoditiesPurchase", function(id, quantity)
		if not pending and outside and outside.itemID == id and quantity then outside.quantity = quantity end
	end)
	hooksecurefunc(C_AuctionHouse, "CancelCommoditiesPurchase", function()
		if not pending then outside = nil end
	end)
end

---------------------------------------------------------------------------
-- For the panel on the right (BuyInfo.lua)
---------------------------------------------------------------------------
QuickBuy.RelistPrice = RelistPrice
QuickBuy.AH_CUT = AH_CUT

-- The commodity on the buy page (nil elsewhere).
function QuickBuy.Item()
	return panel and panel:IsVisible() and itemID or nil
end

-- The session's purchases of it and your settings: bought, spent, want, max,
-- and the log ({ { quantity, total, time }, ... } newest first).
function QuickBuy.Session(id)
	local s = Settings(id)
	return s.bought or 0, s.spent or 0, s.want, s.max, s.log or {}
end

-- What you'd relist at: the cheapest listing left after what Quick buy would
-- buy, or the usual price (and true) without listings.
function QuickBuy.SellPrice(id)
	local s = Settings(id)
	local sell = ListedSellPrice(id, s.max, Remaining(id))
	if sell then return sell, false end
	sell = UsualPrice(id)
	if sell and sell > 0 then return sell, true end
	return nil
end

---------------------------------------------------------------------------
-- The panel
---------------------------------------------------------------------------
local function ReadInputs()
	if not itemID then return end
	local s = Settings(itemID)
	local want = tonumber(wantBox:GetText())
	want = want and want > 0 and math.floor(want) or nil
	s.want = want -- what you've bought still counts toward a new goal (Clear starts over)
	local g = tonumber(coinBoxes[1]:GetText()) or 0
	local sv = math.min(99, tonumber(coinBoxes[2]:GetText()) or 0)
	local c = math.min(99, tonumber(coinBoxes[3]:GetText()) or 0)
	local max = math.floor(g) * 10000 + math.floor(sv) * 100 + math.floor(c)
	s.max = max > 0 and max or nil
	message = nil
	Update()
end

-- Show the saved settings for the item on screen; the first time, the most
-- to pay starts at what it's worth crafted (if one of your recipes uses it).
local function ShowItem(id)
	if pending then return end
	itemID = id
	message = nil
	if not id then return end
	local s = Settings(id)
	s.profit = nil -- from an earlier version
	if s.max == nil and ns.Crafting and ns.Crafting.CraftWorth then
		local ok, best = pcall(ns.Crafting.CraftWorth, id)
		if ok and best then s.max = best.price end
	end
	wantBox:SetText(s.want and tostring(s.want) or "")
	SetCoins(s.max)
	Update()
end

local function Box(parent, width, letters)
	local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	box:SetSize(width, 20)
	box:SetAutoFocus(false)
	box:SetNumeric(true)
	box:SetMaxLetters(letters)
	box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	box:SetScript("OnTabPressed", function(self)
		if self.next then self.next:SetFocus() else self:ClearFocus() end
	end)
	box:SetScript("OnEditFocusLost", function() ns.SafeCall(ReadInputs) end)
	return box
end

local function Label(parent, text, font)
	local fs = parent:CreateFontString(nil, "ARTWORK", font or "GameFontNormal")
	fs:SetText(text)
	return fs
end

local function Coin(parent, box, icon)
	local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	fs:SetPoint("LEFT", box, "RIGHT", 2, 0)
	fs:SetText("|TInterface\\MoneyFrame\\UI-" .. icon .. "Icon:0|t")
	return fs
end

local function Create()
	local buyFrame = AuctionHouseFrame and AuctionHouseFrame.CommoditiesBuyFrame
	local display = buyFrame and buyFrame.BuyDisplay
	if not display then return end

	panel = CreateFrame("Frame", "FireAuctionQuickBuy", buyFrame)
	panel:SetPoint("BOTTOMLEFT", display, "BOTTOMLEFT", 16, 14)
	panel:SetPoint("BOTTOMRIGHT", display, "BOTTOMRIGHT", -16, 14)
	panel:SetHeight(96)

	local title = Label(panel, "Quick buy")
	title:SetPoint("TOPLEFT", 0, 0)

	local wantLabel = Label(panel, "Want", "GameFontHighlight")
	wantLabel:SetPoint("TOPLEFT", 0, -24)
	wantBox = Box(panel, 44, 5)
	wantBox:SetPoint("LEFT", wantLabel, "RIGHT", 10, 0)

	local maxLabel = Label(panel, "Up to", "GameFontHighlight")
	maxLabel:SetPoint("LEFT", wantBox, "RIGHT", 14, 0)
	coinBoxes = { Box(panel, 34, 4), Box(panel, 22, 2), Box(panel, 22, 2) }
	coinBoxes[1]:SetPoint("LEFT", maxLabel, "RIGHT", 10, 0)
	local g = Coin(panel, coinBoxes[1], "Gold")
	coinBoxes[2]:SetPoint("LEFT", g, "RIGHT", 8, 0)
	local sv = Coin(panel, coinBoxes[2], "Silver")
	coinBoxes[3]:SetPoint("LEFT", sv, "RIGHT", 8, 0)
	local c = Coin(panel, coinBoxes[3], "Copper")
	local each = Label(panel, "each", "GameFontHighlight")
	each:SetPoint("LEFT", c, "RIGHT", 4, 0)
	wantBox.next, coinBoxes[1].next, coinBoxes[2].next, coinBoxes[3].next = coinBoxes[1], coinBoxes[2], coinBoxes[3], nil

	-- "Cheapest listing only": each click buys just the lowest price within
	-- "Up to" - fewer listings to lose to someone else.
	local cheapLabel = Label(panel, "Cheapest listing only", "GameFontHighlightSmall")
	cheapLabel:SetPoint("TOPRIGHT", 0, -1)
	local cheap = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	cheap:SetSize(22, 22)
	cheap:SetPoint("RIGHT", cheapLabel, "LEFT", -1, 0)
	cheap:SetChecked(ns.db.quickBuyCheapest)
	cheap:SetScript("OnClick", function(self)
		ns.db.quickBuyCheapest = self:GetChecked() and true or false
		message = nil
		ns.SafeCall(Update)
	end)
	cheap:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Cheapest listing only", 1, 1, 1)
		GameTooltip:AddLine("Buy only the lowest price within \"Up to\". Smaller buys are less likely to be taken by "
			.. "someone else.", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	cheap:SetScript("OnLeave", function() GameTooltip:Hide() end)

	local tips = {
		[wantBox] = { "Want", "How many to buy in total. Leave empty for no limit." },
		[coinBoxes[1]] = { "Up to", "The most to pay for one." },
	}
	tips[coinBoxes[2]], tips[coinBoxes[3]] = tips[coinBoxes[1]], tips[coinBoxes[1]]
	for box, tip in pairs(tips) do
		box:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:SetText(tip[1], 1, 1, 1)
			GameTooltip:AddLine(type(tip[2]) == "function" and tip[2]() or tip[2], nil, nil, nil, true)
			GameTooltip:Show()
		end)
		box:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end

	-- Refresh the listings (the same as the list's own refresh button), right
	-- next to Buy so you can go back and forth without moving the mouse far.
	local refresh = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	refresh:SetSize(28, 24)
	refresh:SetPoint("TOPRIGHT", 0, -50)
	local arrow = refresh:CreateTexture(nil, "ARTWORK")
	arrow:SetSize(14, 14)
	arrow:SetPoint("CENTER")
	arrow:SetTexture("Interface\\Buttons\\UI-RefreshButton")
	refresh:SetScript("OnClick", function()
		message = nil
		Refresh()
	end)
	refresh:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Refresh", 1, 1, 1)
		GameTooltip:Show()
	end)
	refresh:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- Clear: start the count (and what it cost) over, after a last summary.
	clear = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	clear:SetSize(50, 24)
	clear:SetPoint("TOPLEFT", 0, -50)
	clear:SetText("Clear")
	clear:SetMotionScriptsWhileDisabled(true)
	clear:SetScript("OnClick", function()
		if pending or not itemID then return end
		ns.SafeCall(Summary, itemID)
		ClearSession(itemID)
		message = nil
		ns.SafeCall(Update)
	end)
	clear:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Clear", 1, 1, 1)
		GameTooltip:AddLine("Start the session over. A summary is printed first.", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	clear:SetScript("OnLeave", function() GameTooltip:Hide() end)

	button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	button:SetHeight(24)
	button:SetPoint("TOPLEFT", clear, "TOPRIGHT", 4, 0)
	button:SetPoint("TOPRIGHT", refresh, "TOPLEFT", -4, 0)
	button:SetScript("OnClick", function() ns.SafeCall(Buy) end)
	button:SetMotionScriptsWhileDisabled(true)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Quick buy", 1, 1, 1)
		GameTooltip:AddLine("Buys at or under your price, cheapest first, with no confirmation. Nothing is bought "
			.. "if the price went up.", nil, nil, nil, true)
		if BlizzardDialogOpen() then GameTooltip:AddLine("Close the Buy dialog first.", 1, 0.3, 0.3, true) end
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)

	status = Label(panel, "", "GameFontHighlightSmall")
	status:SetPoint("TOPLEFT", button, "BOTTOMLEFT", 0, -6)
	status:SetPoint("TOPRIGHT", button, "BOTTOMRIGHT", 0, -6)
	status:SetJustifyH("LEFT")

	-- Follow the item on screen; keep the button current as listings change.
	hooksecurefunc(buyFrame, "SetItemIDAndPrice", function(_, id) ns.SafeCall(ShowItem, id) end)
	local elapsed = 0
	panel:SetScript("OnUpdate", function(_, dt)
		elapsed = elapsed + dt
		if pending and GetTime() - pending.at > QUOTE_TIMEOUT then
			pcall(C_AuctionHouse.CancelCommoditiesPurchase)
			Finish("|cffff5050Not bought:|r no answer from the auction house")
		end
		if elapsed >= 0.25 then
			elapsed = 0
			ns.SafeCall(Update)
		end
	end)
	panel:SetScript("OnShow", function() ns.SafeCall(ShowItem, buyFrame.GetItemID and buyFrame:GetItemID()) end)
	ShowItem(buyFrame.GetItemID and buyFrame:GetItemID())
end

ns.On("AUCTION_HOUSE_SHOW", function()
	if not panel and C_AuctionHouse and C_AuctionHouse.StartCommoditiesPurchase then Create() end
end)

ns.On("AUCTION_HOUSE_CLOSED", function()
	if pending then
		pcall(C_AuctionHouse.CancelCommoditiesPurchase)
		pending = nil
	end
	-- What you bought this visit and haven't had a summary for yet.
	for id in pairs(boughtNow) do ns.SafeCall(Summary, id) end
	wipe(boughtNow)
	outside = nil
end)
