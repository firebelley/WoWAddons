-- The purchase tracker: a window beside the auction house while the item's
-- Quick buy session is on - on its buy page (Silk Cloth...), or selling it, to
-- see what to list it at. Drag it anywhere (remembered).
--
-- Buying:
--   (portrait)        the item, and how many you've bought (toward Want).
--   So far            spent, sold, up, and how many are left (mail too).
--   Resale price      automatic (the cheapest listing) or your own, set with
--                     its two buttons; under it, the profit if all sell at it,
--                     the break-even price, how many to sell to break even and
--                     how many are then yours for free.
--   Next buy          the profit per item at your "Up to" price, and how many
--                     more to buy per 1g of it.
--   Recent            the last few purchases.
--
-- Selling (SellLines), with how much is paid back on the bar:
--   So far            spent, sold, up, and how many are left (mail too).
--   This listing      the amount on the sell page: what it brings in, and
--                     where that leaves you.
--   Break even        the lowest price for what's left; at the price, how
--                     many to sell and how many are then yours for free.
--   If all sell       the profit if everything left sells at the price.
--
-- Everything after the auction house's 5% cut. Hover a line for how it's
-- worked out.
local _, ns = ...

local WIDTH = 360
local PAD = 14
local TOP = -66    -- where the rows start, under the portrait
local ROW = 15
local COL = 88     -- width of a number column ("all")
local PCT = 58     -- width of the "return" column
local BUTTONS = 44 -- room for the Resale price row's two buttons
local RECENT = 2   -- purchases listed under Recent
local GREY = "|cff999999"
local CUSTOM = "|cff66bbff" -- your own resale price, wherever it's used
local LIST_MAX = 12 -- sessions named in the End all popup

local frame, rows, summary, bar, clearAll
local autoButton, customButton
local shownID -- the item the window shows
local elapsed = 0

local function Name(id)
	return (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) or ns.Data.Name(id, ns.Data.Get(id))
		or ("item " .. id)
end

local function Signed(copper)
	copper = math.floor(copper + 0.5)
	return (copper > 0 and "+" or copper < 0 and "-" or "") .. ns.Money(math.abs(copper))
end

local function Tip(...)
	local lines = { ... }
	return function()
		for i, line in ipairs(lines) do
			if i == 1 then GameTooltip:SetText(line, 1, 1, 1) else GameTooltip:AddLine(line, nil, nil, nil, true) end
		end
	end
end

-- The automatic resale price, where it comes from.
local function AutoSource(approx, selling)
	if approx then return "No listings loaded: " .. ns.Data.TrendDays() .. "-day average market price." end
	return selling and "The cheapest listing now." or "The cheapest listing left after Quick buy."
end

-- The Unit Price typed on the sell page, or nil if none.
local function TypedPrice()
	local sf = AuctionHouseFrame and AuctionHouseFrame.CommoditiesSellFrame
	if not (sf and sf.GetUnitPrice) then return nil end
	local ok, price = pcall(sf.GetUnitPrice, sf)
	return ok and type(price) == "number" and price > 0 and price or nil
end

-- The Quantity on the sell page, or nil if none.
local function TypedQuantity()
	local sf = AuctionHouseFrame and AuctionHouseFrame.CommoditiesSellFrame
	if not (sf and sf.GetQuantity) then return nil end
	local ok, qty = pcall(sf.GetQuantity, sf)
	return ok and type(qty) == "number" and qty > 0 and math.floor(qty) or nil
end

-- How many of the `have` in hand to sell at `net` each (after the cut) to
-- make back `short`, and how many are then yours for free (for crafting).
-- label: the first row's (default "Sell to break even").
local function BreakEvenRows(Add, short, net, have, label)
	label = label or "Sell to break even"
	if have <= 0 then return end
	local n = 0
	if short > 0 then
		n = math.floor(short / net) + 1
		while math.floor(net * n) <= short do n = n + 1 end
	end
	if n > have then
		Add(label, nil, GREY .. ("more than your %d"):format(have) .. "|r")
	else
		Add(label, nil, n > 0 and ("%d of %d"):format(n, have) or (GREY .. "paid back|r"))
		Add("Then free to keep", nil, tostring(have - n), nil, Tip("Then free to keep", "Yours for nothing once those sell."))
	end
end

-- The sell page's lines (see Lines): what you've put in and got back, what
-- the listing on the sell page would do, and where selling everything leaves
-- you. Priced at the sell page's Unit Price, else your own, else the cheapest
-- listing.
local function SellLines(id)
	local QB = ns.QuickBuy
	local cut = 1 - QB.AH_CUT
	local lines = {}
	local function Add(left, mid, right, kind, tip, pct) lines[#lines + 1] = { left, mid, right, kind, tip, pct } end

	local bought, spent, want = QB.Session(id)
	local seedSold, seedIncome, seedLost, seedUp = 0, 0, 0, 0
	if ns.Seed and ns.Seed.Stats then seedSold, seedIncome, seedLost, seedUp = ns.Seed.Stats(id) end
	local listSold, listIncome, listLost, listUp, upIncome = 0, 0, 0, 0, 0
	if ns.Listings then listSold, listIncome, listLost, listUp, upIncome = ns.Listings.Stats(id) end
	local soldN, income, lost = seedSold + listSold, seedIncome + listIncome, seedLost + listLost
	-- What's left to make back: what you paid and lost, less what sales brought in.
	local cover = spent + lost - income
	-- Bought, not sold or up: in your bags, or the mail if they didn't fit.
	local have = math.max(0, bought - soldN - listUp - seedUp)

	local typed = TypedPrice()
	local target = not typed and QB.Target(id) or nil
	local sell, approx = typed, false
	if not sell then
		if target then sell = target else sell, approx = QB.SellPrice(id, true) end
	end
	local qty = typed and TypedQuantity()

	if bought == 0 then
		local summaryText = want and ("Nothing bought yet - want %d"):format(want) or "Nothing bought yet"
		if seedSold > 0 or seedLost > 0 or seedUp > 0 then
			Add("Seeds", nil, nil, "header")
			if seedUp > 0 then Add("Up now", nil, tostring(seedUp)) end
			if seedSold > 0 then
				Add(("Sold %d"):format(seedSold), nil, Signed(seedIncome), nil, Tip("Sold", "After the 5% cut."))
			end
			if seedLost > 0 then
				Add("Deposits lost", nil, Signed(-seedLost), nil, Tip("Deposits lost", "On cancelled or expired seeds."))
			end
		end
		return lines, summaryText, nil
	end

	local paid = spent + lost
	local progress = paid > 0 and math.max(0, math.min(1, 1 - cover / paid)) or 1
	local summaryText = (want and ("Bought %d of %d"):format(bought, want) or ("Bought %d"):format(bought))
		.. (cover <= 0 and " - paid back" or (" - %d%% paid back"):format(math.floor(progress * 100)))

	-- So far
	Add("So far", nil, nil, "header", Tip("So far", "Since you pressed Start session."))
	Add(("Bought %d at %s"):format(bought, ns.Money(math.floor(spent / bought + 0.5))), nil, Signed(-spent))
	if soldN > 0 then
		Add(("Sold %d"):format(soldN), nil, Signed(income), nil, Tip("Sold", "After the 5% cut.",
			seedSold > 0 and listSold > 0 and ("Seeds %d, listings %d."):format(seedSold, listSold) or nil))
	end
	if lost > 0 then
		Add("Deposits lost", nil, Signed(-lost), nil, Tip("Deposits lost", "On cancelled or expired listings."))
	end
	if listUp > 0 then
		Add(("Up now %d"):format(listUp), nil, GREY .. Signed(upIncome) .. "|r", nil, Tip("Up now", "If they sell."))
	end
	if seedUp > 0 then Add(("Seeds up %d"):format(seedUp), nil, nil) end
	local count = C_Item and C_Item.GetItemCount and C_Item.GetItemCount(id) or (GetItemCount and GetItemCount(id))
	local away = count and math.max(0, have - count) or 0
	Add(("Left %d"):format(have), nil, away > 0 and (GREY .. away .. " not in bags|r") or nil, nil,
		away > 0 and Tip("Left", ("%d in your bags; the rest in the mail."):format(have - away)) or nil)

	-- This listing: the amount on the sell page.
	if qty then
		local thisIncome = math.floor(typed * cut * qty)
		local result = upIncome + thisIncome - cover
		Add(("This listing: %d at %s"):format(qty, ns.Money(typed)), nil, nil, "header")
		Add("Brings in", nil, Signed(thisIncome), nil, Tip("Brings in", "After the 5% cut."))
		Add("Then you're at", GREY .. ("%d left"):format(math.max(0, have - qty)) .. "|r", Signed(result), nil,
			Tip("Then you're at", listUp > 0 and "If this and what's up sell." or "If it sells."))
	end

	-- Breaking even: the lowest price for what's left, and at the price, how
	-- many to sell and how many are then yours for free. Then the profit if
	-- everything left sells at it (what's up at its own).
	local left = have + seedUp
	if left > 0 then
		local money = (approx and "~" or "") .. ns.Money(sell or 0)
		money = target and (CUSTOM .. money .. "|r") or money
		local short = cover - upIncome
		Add("Break even", nil, nil, "header", Tip("Break even", "Making back what you spent, with what's sold and up."))
		Add("Lowest price", nil, short > 0 and (ns.Money(QB.RelistPrice(short, left)) .. " each") or (GREY .. "any price|r"),
			nil, Tip("Lowest price", ("For the %d left, after the 5%% cut."):format(left)))
		if not sell then
			Add("No price to go by yet", nil, nil, "note")
		else
			BreakEvenRows(Add, short, sell * cut, have, "Sell at " .. money)
			local total = math.floor(sell * cut * left) - short
			Add(("If all %d sell at %s"):format(left + listUp, money), nil, nil, "header", Tip("Price",
				typed and "Your Unit Price on the sell page." or target and "Your own price." or AutoSource(approx, true)))
			Add("Profit", nil, Signed(total), nil, Tip("Profit", "After the 5% cut."), ns.Percent(total / spent * 100))
		end
	end
	return lines, summaryText, progress
end

-- The lines to show for itemID: { { left, mid, right, kind, tip, pct }, ... }, kind
-- being "header" (mid, right and pct its column names), "price", "note" or nil. selling: on the sell
-- page (SellLines). Also returns the summary under the item's name.
local function Lines(id, selling)
	if selling then return SellLines(id) end
	local QB = ns.QuickBuy
	local cut = 1 - QB.AH_CUT
	local lines = {}
	local function Add(left, mid, right, kind, tip, pct) lines[#lines + 1] = { left, mid, right, kind, tip, pct } end

	local bought, spent, want, max, log = QB.Session(id)
	-- The resale price: your own if you've set one, else the cheapest listing.
	local target = QB.Target(id)
	local live, liveApprox = QB.SellPrice(id, selling)
	local sell, approx = live, liveApprox
	if target then sell, approx = target, false end
	-- Not rounded: the cut is taken from the whole sale, not from each item.
	local net = sell and sell * cut
	-- Seeds (Seed.lua) and your listings (Listings.lua): sold, lost, still up.
	local seedSold, seedIncome, seedLost, seedUp = 0, 0, 0, 0
	if ns.Seed and ns.Seed.Stats then seedSold, seedIncome, seedLost, seedUp = ns.Seed.Stats(id) end
	local listSold, listIncome, listLost, listUp, upIncome = 0, 0, 0, 0, 0
	if ns.Listings then listSold, listIncome, listLost, listUp, upIncome = ns.Listings.Stats(id) end
	local soldN, income, lost = seedSold + listSold, seedIncome + listIncome, seedLost + listLost
	-- What's left to make back: what you paid and lost, less what sales brought in.
	local cover = spent + lost - income
	-- Bought, not sold or up: in your bags, or the mail if they didn't fit.
	local have = math.max(0, bought - soldN - listUp - seedUp)

	local summaryText = bought == 0 and (want and ("Nothing bought yet - want %d"):format(want) or "Nothing bought yet")
		or want and ("Bought %d of %d"):format(bought, want) or ("Bought %d"):format(bought)
	local progress = want and math.min(1, bought / want) or nil

	-- So far
	if bought > 0 then
		Add("So far", nil, nil, "header", Tip("So far", "Since you pressed Start session."))
		Add(("Bought %d at %s"):format(bought, ns.Money(math.floor(spent / bought + 0.5))), nil, Signed(-spent))
	end
	if soldN > 0 or seedUp > 0 or lost > 0 then
		if bought == 0 then Add("Seeds", nil, nil, "header") end
		if soldN > 0 then
			Add(("Sold %d"):format(soldN), nil, Signed(income), nil, Tip("Sold", "After the 5% cut.",
				seedSold > 0 and listSold > 0 and ("Seeds %d, listings %d."):format(seedSold, listSold) or nil))
		end
		if lost > 0 then
			Add("Deposits lost", nil, Signed(-lost), nil, Tip("Deposits lost", "On cancelled or expired listings."))
		end
		if seedUp > 0 then Add(("Seeds up %d"):format(seedUp), nil, nil) end
	end
	if listUp > 0 then
		Add(("Up now %d"):format(listUp), nil, GREY .. Signed(upIncome) .. "|r", nil, Tip("Up now", "If they sell."))
	end
	if bought > 0 then
		local count = C_Item and C_Item.GetItemCount and C_Item.GetItemCount(id) or (GetItemCount and GetItemCount(id))
		local away = count and math.max(0, have - count) or 0
		Add(("Left %d"):format(have), nil, away > 0 and (GREY .. away .. " not in bags|r") or nil, nil,
			away > 0 and Tip("Left", ("%d in your bags; the rest in the mail."):format(have - away)) or nil)
	end

	-- Resale price: automatic or your own (the row's two buttons).
	if target then
		Add("Resale price", CUSTOM .. "custom|r", CUSTOM .. ns.Money(target) .. "|r", "price",
			Tip("Resale price", "Your own price.", live and ("Automatic would be %s%s: %s"):format(liveApprox and "~" or "",
				ns.Money(live), AutoSource(liveApprox, selling):lower()) or "No listings loaded."))
		lines[#lines].mode = "custom"
	else
		Add("Resale price", nil, sell and ((approx and "~" or "") .. ns.Money(sell)) or (GREY .. "none yet|r"), "price",
			Tip("Resale price", sell and AutoSource(approx, selling) or "No listings or scans to go by yet.",
				"Set your own with the pencil."))
		lines[#lines].mode = "auto"
	end

	-- If everything left sells at it (what's up at its own price): the profit,
	-- the break-even price, and how many to sell to break even - the rest are
	-- yours for free (for crafting).
	local left = have + seedUp
	if bought > 0 and sell and left + listUp > 0 then
		local short = cover - upIncome
		local total = math.floor(net * left) - short
		Add(("Profit (all %d)"):format(left + listUp), nil, Signed(total), nil, Tip("Profit",
			"If all you bought sells: what's left at this price, what's up at its own; after the 5% cut."),
			ns.Percent(total / spent * 100))
		if left > 0 then
			Add("Break-even", nil, short > 0 and (ns.Money(QB.RelistPrice(short, left)) .. " each") or (GREY .. "any price|r"),
				nil, Tip("Break-even", ("The lowest price for the %d left to make back what you spent."):format(left)))
		end
		BreakEvenRows(Add, short, net, have)
	elseif bought > 0 and not sell then
		Add("No price to go by yet", nil, nil, "note")
	end

	-- Next buy, at "Up to": is it worth it.
	if not max then
		Add("Next buy", nil, nil, "header")
		Add("Set \"Up to\" to see", nil, nil, "note")
	else
		Add(("Next buy at %s"):format(ns.Money(max)), nil, nil, "header", Tip("Next buy", "At your \"Up to\" price."))
		if sell then
			local each = net - max
			Add("Profit each", nil, Signed(each), nil, Tip("Profit each",
				("Resold after the 5%% cut (%s), less your Up to."):format(ns.Money(net))), ns.Percent(each / max * 100))
			Add("Buy per 1g profit", nil, each > 0 and tostring(math.ceil(10000 / each)) or (GREY .. "no profit|r"))
		else
			Add("No price to go by yet", nil, nil, "note")
		end
	end

	-- Recent purchases
	if #log > 0 then
		Add("Recent", nil, nil, "header")
		for i = 1, math.min(RECENT, #log) do
			local entry = log[i]
			Add(("%d at %s"):format(entry[1], ns.Money(entry[2] / entry[1])), nil,
				GREY .. (date and date("%H:%M", entry[3]) or "") .. "|r")
		end
	end
	return lines, summaryText, progress
end

---------------------------------------------------------------------------
-- Your own resale price: a dialog with Blizzard's gold/silver/copper boxes.
---------------------------------------------------------------------------
local function MoneyInput(dialog)
	return dialog and (dialog.MoneyInputFrame or dialog.moneyInputFrame)
end

local function SaveTarget(dialog, id)
	local input = MoneyInput(dialog)
	if not (input and id and MoneyInputFrame_GetCopper) then return end
	ns.QuickBuy.SetTarget(id, MoneyInputFrame_GetCopper(input))
	elapsed = 1 -- redraw now
end

StaticPopupDialogs.FIREAUCTION_RESALE_PRICE = {
	text = "Your resale price for %s, each:",
	button1 = SAVE or "Save",
	button2 = CANCEL or "Cancel",
	hasMoneyInputFrame = 1,
	OnShow = function(dialog, id)
		local input = MoneyInput(dialog)
		if input and MoneyInputFrame_SetCopper then
			local price = ns.QuickBuy.Target(id) or ns.QuickBuy.SellPrice(id) or 0
			MoneyInputFrame_SetCopper(input, math.floor(price + 0.5))
		end
	end,
	OnAccept = function(dialog, id) SaveTarget(dialog, id) end,
	EditBoxOnEnterPressed = function(editBox, id)
		local dialog = editBox
		while dialog and dialog.which ~= "FIREAUCTION_RESALE_PRICE" do dialog = dialog:GetParent() end
		SaveTarget(dialog, id)
		if dialog then dialog:Hide() end
	end,
	OnHide = function(dialog)
		local input = MoneyInput(dialog)
		if input and MoneyInputFrame_ResetMoney then MoneyInputFrame_ResetMoney(input) end
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

local function EditTarget()
	if shownID then StaticPopup_Show("FIREAUCTION_RESALE_PRICE", Name(shownID), nil, shownID) end
end

local function UseAutomatic()
	if shownID then ns.QuickBuy.SetTarget(shownID, nil) end
	elapsed = 1
end

-- The Resale price row's two buttons: Automatic and Custom (the pencil). The
-- one in use is in full colour; the other is greyed out.
local function ModeButton(texture, onClick, tip)
	local b = CreateFrame("Button", nil, frame)
	b:SetSize(18, 18)
	b:SetFrameLevel((frame:GetFrameLevel() or 1) + 5) -- above the rows, which are made later
	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetAllPoints()
	b.icon:SetTexture(texture)
	b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	b:SetScript("OnClick", function() ns.SafeCall(onClick) end)
	ns.ClickSound(b)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		tip(self)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	b:Hide()
	return b
end

local function SetLit(b, on)
	b.active = on
	b.icon:SetDesaturated(not on)
	b.icon:SetAlpha(on and 1 or 0.5)
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------
local function ShowTip(self)
	if not self.tip then return end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	self.tip()
	GameTooltip:Show()
end

local function Row(i)
	local row = rows[i]
	if not row then
		row = CreateFrame("Frame", nil, frame)
		row:SetHeight(ROW)
		row.left = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		row.mid = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		row.right = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		row.pct = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		row.left:SetPoint("LEFT")
		row.left:SetJustifyH("LEFT")
		if row.left.SetWordWrap then row.left:SetWordWrap(false) end
		row.right:SetJustifyH("RIGHT")
		row.mid:SetJustifyH("RIGHT")
		row.pct:SetPoint("RIGHT")
		row.pct:SetJustifyH("RIGHT")
		row:SetScript("OnEnter", ShowTip)
		row:SetScript("OnLeave", function() GameTooltip:Hide() end)
		rows[i] = row
	end
	return row
end

-- The commodity on the sell page, if its session is on.
local function SellingItem()
	local sf = AuctionHouseFrame and AuctionHouseFrame.CommoditiesSellFrame
	if not (sf and sf:IsVisible() and sf.GetItem) then return nil end
	local ok, id = pcall(function()
		local loc = sf:GetItem()
		return loc and loc.IsValid and loc:IsValid() and C_Item.GetItemID(loc)
	end)
	if ok and id and ns.QuickBuy.Active(id) then return id end
	return nil
end

-- What to show: the item on the buy page, or the one you're selling (and
-- true) - while its session is on.
local function Current()
	local id = ns.QuickBuy and ns.QuickBuy.Item()
	if id then
		if ns.QuickBuy.Active(id) then return id, false end
		return nil
	end
	id = ns.QuickBuy and SellingItem()
	if id then return id, true end
	return nil
end

local function Update(id, selling)
	shownID = id
	ns.SideWindowTitle(frame, Name(id))
	local texture = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)
	ns.SideWindowIcon(frame, texture or "Interface\\Icons\\INV_Misc_QuestionMark")

	local lines, summaryText, progress = Lines(id, selling)
	summary:SetText(summaryText)
	bar:SetShown(progress ~= nil)
	if progress then bar:SetValue(progress) end

	local y = TOP
	local priceRow
	for i, line in ipairs(lines) do
		local row = Row(i)
		local left, mid, right, kind, tip, pct = line[1], line[2], line[3], line[4], line[5], line[6]
		if (kind == "header" or kind == "price") and i > 1 then y = y - 8 end
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", PAD, y)
		row:SetPoint("TOPRIGHT", -PAD, y)
		row.left:SetFontObject((kind == "header" or kind == "price") and "GameFontNormal"
			or kind == "note" and "GameFontDisableSmall" or "GameFontHighlightSmall")
		row.mid:SetFontObject(kind == "header" and "GameFontDisableSmall" or "GameFontHighlightSmall")
		row.right:SetFontObject(kind == "header" and "GameFontDisableSmall" or kind == "price" and "GameFontHighlight"
			or "GameFontHighlightSmall")
		row.pct:SetFontObject(kind == "header" and "GameFontDisableSmall" or "GameFontHighlightSmall")
		-- Number columns from the right: [return] all, then each. The Resale
		-- price row has its two buttons there instead.
		local shift = kind == "price" and BUTTONS or pct and PCT or 0
		row.right:ClearAllPoints()
		row.right:SetPoint("RIGHT", -shift, 0)
		row.mid:ClearAllPoints()
		row.mid:SetPoint("RIGHT", kind == "price" and row.right or row, kind == "price" and "LEFT" or "RIGHT",
			kind == "price" and -6 or (-shift - COL), 0)
		-- The name gets what the numbers leave.
		row.left:ClearAllPoints()
		row.left:SetPoint("LEFT")
		if mid then
			row.left:SetPoint("RIGHT", row.mid, "LEFT", -6, 0)
		elseif right then
			row.left:SetPoint("RIGHT", row.right, "LEFT", -6, 0)
		else
			row.left:SetPoint("RIGHT")
		end
		row.left:SetText(left or "")
		row.mid:SetText(mid or "")
		row.right:SetText(right or "")
		row.pct:SetText(pct or "")
		row.tip = tip
		if row.EnableMouse then row:EnableMouse(tip ~= nil) end
		row:Show()
		if kind == "price" then priceRow = { row = row, mode = line.mode } end
		y = y - ROW - ((kind == "header" or kind == "price") and 2 or 0)
	end
	for i = #lines + 1, #rows do rows[i]:Hide() end

	-- The Resale price row's buttons (not while the sell page's Unit Price is in charge).
	local buttons = priceRow and priceRow.mode ~= "typed"
	autoButton:SetShown(buttons)
	customButton:SetShown(buttons)
	if buttons then
		customButton:ClearAllPoints()
		customButton:SetPoint("RIGHT", priceRow.row, "RIGHT", 0, 0)
		autoButton:ClearAllPoints()
		autoButton:SetPoint("RIGHT", customButton, "LEFT", -6, 0)
		SetLit(autoButton, priceRow.mode == "auto")
		SetLit(customButton, priceRow.mode == "custom")
	end
	frame:SetHeight(-y + PAD)
end

---------------------------------------------------------------------------
-- End all sessions (Auctions tab)
---------------------------------------------------------------------------
-- "Silk Cloth: 26 for 2g 2s" for each session, for the End all popup.
local function SessionList()
	local lines = {}
	local list = ns.QuickBuy.Sessions()
	for i, s in ipairs(list) do
		if i > LIST_MAX then
			lines[#lines + 1] = ("and %d more"):format(#list - LIST_MAX)
			break
		end
		lines[#lines + 1] = ("%s: %d for %s"):format(Name(s.id), s.bought, ns.Money(s.spent))
	end
	return table.concat(lines, "\n")
end

StaticPopupDialogs.FIREAUCTION_CLEAR_SESSIONS = {
	text = "End all sessions?\n\n%s",
	button1 = YES,
	button2 = NO,
	OnAccept = function()
		local n = ns.QuickBuy.EndAll()
		ns.Print(n == 1 and "ended 1 session." or ("ended %d sessions."):format(n))
		elapsed = 1
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------
local function CreateWindow()
	-- Beside the auction house window, at its top, until you drag it.
	frame = ns.SideWindow("FireAuctionBuyInfo", WIDTH, TOP + 6, "buyInfoPoint", function(f)
		f:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 38, 0)
	end)
	local f = frame

	-- Beside the portrait, under the title: how many you've bought, and
	-- toward Want.
	summary = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	summary:SetPoint("TOPLEFT", 64, -32)
	summary:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
	summary:SetJustifyH("LEFT")
	bar = CreateFrame("StatusBar", nil, f)
	bar:SetHeight(8)
	bar:SetPoint("TOPLEFT", 64, -50)
	bar:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
	bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	bar:SetStatusBarColor(0.25, 0.75, 0.25)
	bar:SetMinMaxValues(0, 1)
	local bg = bar:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(1, 1, 1, 0.1)
	bar:Hide()

	autoButton = ModeButton("Interface\\Buttons\\UI-RefreshButton", UseAutomatic, function()
		GameTooltip:SetText("Automatic", 1, 1, 1)
		GameTooltip:AddLine("Go by the cheapest listing left after Quick buy.", nil, nil, nil, true)
	end)
	customButton = ModeButton("Interface\\Buttons\\UI-GuildButton-PublicNote-Up", EditTarget, function()
		local target = shownID and ns.QuickBuy.Target(shownID)
		GameTooltip:SetText("Custom", 1, 1, 1)
		GameTooltip:AddLine(target and ("Your price: %s. Click to change it."):format(ns.Money(target))
			or "Set your own resale price.", nil, nil, nil, true)
	end)

	f:Hide()
end

local function Create()
	if not AuctionHouseFrame then return end
	rows = {}
	CreateWindow()
	local f = frame

	-- End all sessions: on the Auctions tab only, along the bottom just
	-- right of your gold (which sits in the bottom-left corner) - while any
	-- session is open.
	local auctions = AuctionHouseFrame.AuctionsFrame or AuctionHouseFrame
	clearAll = CreateFrame("Button", nil, auctions, "UIPanelButtonTemplate")
	clearAll:SetSize(140, 22)
	local money = AuctionHouseFrame.MoneyFrameBorder
	if money then
		clearAll:SetPoint("LEFT", money, "RIGHT", 8, 0)
	else
		clearAll:SetPoint("BOTTOMLEFT", auctions, "BOTTOMLEFT", 3, -22)
	end
	clearAll:SetText("End all sessions")
	clearAll:SetScript("OnClick", function()
		if #ns.QuickBuy.Sessions() > 0 then StaticPopup_Show("FIREAUCTION_CLEAR_SESSIONS", SessionList()) end
	end)
	ns.ClickSound(clearAll)
	clearAll:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("End all sessions", 1, 1, 1)
		GameTooltip:AddLine("Asks first.", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	clearAll:SetScript("OnLeave", function() GameTooltip:Hide() end)
	clearAll:Hide()

	-- Shows and updates everything, a few times a second while the auction house is open.
	local driver = CreateFrame("Frame", nil, AuctionHouseFrame)
	driver:SetScript("OnUpdate", function(_, dt)
		elapsed = elapsed + dt
		if elapsed < 0.25 then return end
		elapsed = 0
		local id, selling = Current()
		clearAll:SetShown(ns.QuickBuy and #ns.QuickBuy.Sessions() > 0)
		f:SetShown(id ~= nil)
		if id then ns.SafeCall(Update, id, selling) end
	end)
	driver:SetScript("OnShow", function() elapsed = 1 end)
end

ns.On("AUCTION_HOUSE_SHOW", function()
	if not frame then Create() end
end)
