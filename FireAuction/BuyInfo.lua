-- The purchase tracker: a window beside the auction house while the item's
-- Quick buy session is on - on its buy page (Silk Cloth...), or selling it, to
-- see what to list it at. Drag it anywhere (remembered).
--
--   (portrait)        the item, and how many you've bought (toward Want).
--   This session      what it cost on average and in all, and the price to
--                     relist at to break even.
--   Resale price      the price the "Resell" rows go by: automatic (the
--                     cheapest listing) or your own, set with its two buttons.
--   This listing      selling: the profit on the amount on the sell page.
--   Break-even        selling: what's sold and up, what you'd keep, and how
--                     many to list to break even (Listings.lua).
--   What it's worth   what you've bought makes resold, each and for all of
--                     it, and with your seeds counted.
--   Next buy          the same at your "Up to" price: is the next one worth it.
--   Recent            the last few purchases.
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
local RECENT = 4   -- purchases listed under Recent
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

-- The lines to show for itemID: { { left, mid, right, kind, tip, pct }, ... }, kind
-- being "header" (mid, right and pct its column names), "price", "note" or nil. selling: on the sell
-- page (no Next buy). Also returns the summary under the item's name.
local function Lines(id, selling)
	local QB = ns.QuickBuy
	local cut = 1 - QB.AH_CUT
	local lines = {}
	local function Add(left, mid, right, kind, tip, pct) lines[#lines + 1] = { left, mid, right, kind, tip, pct } end

	local bought, spent, want, max, log = QB.Session(id)
	-- The resale price: on the sell page, the Unit Price you've typed there;
	-- otherwise your own price if you've set one, else the cheapest listing.
	local typed = selling and TypedPrice()
	local target = not typed and QB.Target(id) or nil
	local live, liveApprox = QB.SellPrice(id, selling)
	local sell, approx = live, liveApprox
	if typed then sell, approx = typed, false elseif target then sell, approx = target, false end
	-- Not rounded: the cut is taken from the whole sale, not from each item.
	local net = sell and sell * cut
	local avg = bought > 0 and spent / bought or nil
	-- Seeding (Seed.lua): seeds that sold are gone from what's left to resell
	-- and brought in their price; cancelled or expired ones lost their deposit.
	local seedSold, seedIncome, seedLost, seedUp, seedGone = 0, 0, 0, 0, 0
	if ns.Seed and ns.Seed.Stats then seedSold, seedIncome, seedLost, seedUp, seedGone = ns.Seed.Stats(id) end
	local seededN = seedSold + seedUp + seedGone -- every seed item listed this session
	-- Your listings (Listings.lua): the same, and what's still up.
	local listSold, listIncome, listLost, listUp, upIncome = 0, 0, 0, 0, 0
	if ns.Listings then listSold, listIncome, listLost, listUp, upIncome = ns.Listings.Stats(id) end
	local left = math.max(0, bought - seedSold - listSold)
	local seeded = seedSold > 0 or seedLost > 0
	local listed = listSold > 0 or listLost > 0
	-- What's left to make back: what you paid and lost, less what sales brought in.
	local cover = spent + seedLost + listLost - seedIncome - listIncome
	-- What the rows that go by it are called.
	local resell = typed and "List at your price" or target and ("Resell " .. CUSTOM .. "(custom)|r") or "Resell"

	local summaryText = bought == 0 and (want and ("Nothing bought yet - want %d"):format(want) or "Nothing bought yet")
		or want and ("Bought %d of %d"):format(bought, want) or ("Bought %d"):format(bought)
	-- Selling: how much of the cost sales have made back, on the bar.
	local progress = want and math.min(1, bought / want) or nil
	if selling and bought > 0 then
		local paid = spent + seedLost + listLost
		progress = paid > 0 and math.max(0, math.min(1, 1 - cover / paid)) or 1
		summaryText = summaryText .. (cover <= 0 and " - paid back" or (" - %d%% paid back"):format(math.floor(progress * 100)))
	end

	-- This session
	if bought > 0 then
		Add("This session", nil, nil, "header", Tip("This session", "Everything bought since you pressed Start session."))
		Add("Average cost", nil, ns.Money(math.floor(avg + 0.5)) .. " each", nil, Tip("Average cost",
			("What you've paid per item: %s for %d."):format(ns.Money(spent), bought)))
		Add("Spent", nil, ns.Money(spent))
		if seededN > 0 then
			Add("Bought per seed", nil, ("%.1f"):format(bought / seededN), nil, Tip("Bought per seed",
				("%d bought for %d seeded."):format(bought, seededN)))
		end
		if left > 0 then
			Add("Break-even relist", nil, cover > 0 and (ns.Money(QB.RelistPrice(cover, left)) .. " each")
				or (GREY .. "any price|r"), nil, Tip("Break-even relist",
				((seeded or listed) and "The lowest price to list the %d left at and still make a profit after the 5%% cut, "
					.. "sales counted." or "The lowest price to list all %d at and still make a profit after the 5%% cut.")
					:format(left)))
		end
	end

	-- Resale price: automatic or your own (the row's two buttons), or the sell page's.
	if typed then
		Add("Resale price", GREY .. "sell page|r", ns.Money(typed), "price",
			Tip("Resale price", "Your Unit Price on the sell page."))
		lines[#lines].mode = "typed"
	elseif target then
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

	-- Seeds listed before buying any: what's up, sold and lost (with purchases,
	-- they're weighed against what you paid, under What it's worth).
	if bought == 0 and (seeded or seedUp > 0) then
		Add("Seeds", nil, nil, "header")
		if seedUp > 0 then Add("Still up", nil, tostring(seedUp)) end
		if seedSold > 0 then
			Add(("Sold %d"):format(seedSold), nil, ns.Money(seedIncome), nil, Tip("Sold", "After the 5% cut."))
		end
		if seedLost > 0 then
			Add("Deposits lost", nil, Signed(-seedLost), nil, Tip("Deposits lost", "On cancelled or expired seeds."))
		end
	end

	-- Selling: the amount on the sell page, at its Unit Price.
	local qty = selling and typed and TypedQuantity()
	if bought > 0 and qty then
		local each = typed * cut - avg
		Add("This listing", "each", "all " .. qty, "header", nil, "return")
		Add("Profit", Signed(each), Signed(each * qty), nil, Tip("This listing",
			("After the 5%% cut you get %s for %d; they cost you %s."):format(ns.Money(math.floor(typed * cut * qty)),
				qty, ns.Money(math.floor(avg * qty + 0.5)))), ns.Percent(each / avg * 100))
	end

	-- Selling: toward making back what you spent, keeping the rest. A ledger:
	-- spent, what's come in, what's up and this listing would bring in, overall.
	if selling and bought > 0 then
		local soldN, soldIncome = seedSold + listSold, seedIncome + listIncome
		local lostAll = seedLost + listLost
		local thisIncome = qty and math.floor(typed * cut * qty) or 0
		-- What's in your bags: counted, so it includes any you had before buying
		-- (seeds and listings from those come out of the bags, not what you bought).
		-- Without a count: what you bought, less what's sold or up.
		local count = C_Item and C_Item.GetItemCount and C_Item.GetItemCount(id) or (GetItemCount and GetItemCount(id))
		local inBags = count or math.max(0, left - listUp - seedUp)
		local keep = math.max(0, inBags - (qty or 0))
		local result = upIncome + thisIncome - cover
		Add("Break-even", nil, nil, "header", Tip("Break-even", "Making back what you spent, keeping the rest."))
		Add(("Spent (%d bought)"):format(bought), nil, Signed(-spent))
		if soldN > 0 then
			Add(("Sold %d"):format(soldN), nil, Signed(soldIncome), nil, Tip("Sold",
				"Your seeds and listings that sold, after the 5% cut."))
		end
		if lostAll > 0 then
			Add("Deposits lost", nil, Signed(-lostAll), nil, Tip("Deposits lost", "On cancelled or expired seeds and listings."))
		end
		if listUp > 0 then
			Add(("Still up %d"):format(listUp), nil, GREY .. Signed(upIncome) .. "|r", nil, Tip("Still up",
				"Your listings not sold yet, if they sell, after the 5% cut."))
		end
		if qty then
			Add(("This listing %d"):format(qty), nil, GREY .. Signed(thisIncome) .. "|r", nil, Tip("This listing",
				"If it sells, after the 5% cut."))
		end
		Add("Overall", nil, Signed(result), nil, Tip("Overall",
			(listUp > 0 or qty) and "If what's up and this listing sell." or "So far."))
		Add(("Keeping %d"):format(keep), nil, (result >= 0 or keep == 0) and "free"
			or (ns.Money(math.floor(-result / keep + 0.5)) .. " each"), nil, Tip("Keeping " .. keep,
			"What's left in your bags" .. (qty and " after this listing." or "."),
			result >= 0 and "Free: the rest pays for everything." or "What each costs you if the rest sells."))
		-- How many to sell at this price to make back what you spent, with what's up.
		local short = cover - upIncome
		if typed and short > 0 then
			local n = math.floor(short / (typed * cut)) + 1
			while math.floor(typed * cut * n) <= short do n = n + 1 end
			local after = ("Each sold after that: %s profit."):format(Signed(typed * cut))
			if qty and n <= qty then
				Add("Break even at", nil, ("%d of %d sold"):format(n, qty), nil, Tip("Break even at", after))
			else
				Add("To break even", nil, n <= inBags and ("list " .. n) or ("list " .. n .. GREY .. " (have " .. inBags .. ")|r"),
					nil, Tip("To break even", ("How many to sell at %s to make back what you spent."):format(ns.Money(typed)), after))
			end
		end
	end

	-- What it's worth: each way of using what you've bought.
	if bought > 0 then
		-- Reselling what's left (seeds that sold are gone), at what it cost you
		-- on average.
		Add("What it's worth", "each", "all " .. left, "header", Tip("What it's worth",
			"Profit on what you've bought, per item and in total."), "return")
		local each = sell and net - avg
		if each then
			Add(resell, Signed(each), Signed(each * left), nil, Tip("Resell at " .. ns.Money(sell),
				(left == bought and "After the 5%% cut you get %s for all %d; you paid %s."
					or "After the 5%% cut you get %s for the %d left; they cost you %s."):format(
					ns.Money(math.floor(net * left)), left, ns.Money(math.floor(avg * left + 0.5)))),
				ns.Percent(each / avg * 100))
		else
			Add("No price to go by yet", nil, nil, "note")
		end

		-- Seeds: what the ones that sold brought in against what they cost you,
		-- and deposits lost on the rest - then the profit with that counted.
		if seeded then
			local seedCost = avg * seedSold
			local result = seedIncome - seedCost - seedLost
			local seedEach = seedSold > 0 and (seedIncome / seedSold - avg) or nil
			local tip = {}
			if seedSold > 0 then
				tip[#tip + 1] = ("%d sold for %s after the 5%% cut; they cost you %s (%s each)."):format(seedSold,
					ns.Money(seedIncome), ns.Money(math.floor(seedCost + 0.5)), ns.Money(math.floor(avg + 0.5)))
			end
			if seedLost > 0 then
				tip[#tip + 1] = ("Deposits lost on cancelled or expired seeds: %s."):format(ns.Money(seedLost))
			end
			Add(("Seeds (%d sold)"):format(seedSold), seedEach and Signed(seedEach), Signed(result), nil,
				Tip("Seeds", unpack(tip)), seedEach and ns.Percent(seedEach / avg * 100))
		end
		-- Your listings: the same.
		if listed then
			local listResult = listIncome - avg * listSold - listLost
			local listEach = listSold > 0 and (listIncome / listSold - avg) or nil
			Add(("Listings (%d sold)"):format(listSold), listEach and Signed(listEach), Signed(listResult), nil,
				Tip("Listings", ("%d sold for %s after the 5%% cut; they cost you %s."):format(listSold,
					ns.Money(listIncome), ns.Money(math.floor(avg * listSold + 0.5))),
					listLost > 0 and ("Deposits lost on cancelled or expired listings: %s."):format(ns.Money(listLost)) or nil),
				listEach and ns.Percent(listEach / avg * 100))
		end
		if (seeded or listed) and each then
			local total = each * left + seedIncome - avg * seedSold - seedLost + listIncome - avg * listSold - listLost
			Add("Profit in all", nil, Signed(total), nil, Tip("Profit in all",
				("Reselling the %d left, plus what's sold."):format(left)), ns.Percent(total / spent * 100))
		end
		if seedUp > 0 then
			Add(("   %d in seeds still up - counted when they sell or end"):format(seedUp), nil, nil, "note")
		end
	end

	-- Next buy, at "Up to".
	if not selling then
		Add("Next buy", nil, nil, "header", Tip("Next buy", "Profit per item at your \"Up to\" price."))
		if not max then
			Add("Set \"Up to\" to see", nil, nil, "note")
		else
			Add("Up to", nil, ns.Money(max))
			if sell then
				local money = (approx and "~" or "") .. ns.Money(sell)
				Add(resell, nil, target and (CUSTOM .. money .. "|r") or money, nil,
					Tip("Resell", target and "Your own price." or AutoSource(approx, selling)))
				Add("Per unit", nil, Signed(net - max) .. " (" .. ns.Percent((net - max) / max * 100) .. ")", nil,
					Tip("Per unit", ("Resell after the 5%% cut (%s), less your Up to."):format(ns.Money(net))))
			else
				Add("No price to go by yet", nil, nil, "note")
			end
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
