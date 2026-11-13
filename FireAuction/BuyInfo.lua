-- The purchase tracker: a window beside the auction house while you're on a
-- commodity's buy page (Silk Cloth...), next to Quick buy - or selling
-- something you've bought this session, to see what to list it at. Hidden by
-- default; a tab on the auction house window's edge opens it (remembered).
-- Drag it anywhere (remembered too).
--
--   (portrait)        the item, and how many you've bought (toward Want).
--   This session      what it cost on average and in all, and the price to
--                     relist at to break even.
--   Resale price      the price the "Resell" rows go by: automatic (the
--                     cheapest listing) or your own, set with its two buttons.
--   What it's worth   what you've bought makes each way - resold, or crafted
--                     with one of your saved recipes - each and for all of
--                     it, the best way marked.
--   Next buy          the same at your "Up to" price: is the next one worth it.
--   Recent            the last few purchases.
--
-- Everything after the auction house's 5% cut. Hover a line for how it's
-- worked out.
local _, ns = ...

local WIDTH = 330
local PAD = 14
local TOP = -66    -- where the rows start, under the portrait
local ROW = 15
local COL = 64     -- width of a number column ("all")
local PCT = 40     -- width of the "return" column
local BUTTONS = 44 -- room for the Resale price row's two buttons
local RECENT = 4   -- purchases listed under Recent
local GREY = "|cff999999"
local CUSTOM = "|cff66bbff" -- your own resale price, wherever it's used
local LIST_MAX = 12 -- sessions named in the Clear all popup

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

-- A recipe row's tooltip lines (the recipe's name is the title): "Sells for
-- 8s 70c (last seen). 4 Silk Cloth + 12c other reagents per craft." and
-- "Each Silk Cloth is worth 2s 6c after the cut."
local function CraftSource(u, itemName)
	local text = "Sells for " .. ns.Money(u.unit or 0)
		.. (u.source == "vendor" and " (vendor)" or not u.current and " (last seen)" or "") .. ". "
		.. u.qty .. " " .. itemName .. (u.other > 0 and (" + " .. ns.Money(u.other) .. " other reagents") or "")
		.. " per craft" .. (u.made > 1 and (", makes " .. u.made) or "") .. "."
	return text, ("Each %s is worth %s after the cut."):format(itemName, ns.Money(u.worth))
end

-- The lines to show for itemID: { { left, mid, right, kind, tip, pct }, ... }, kind
-- being "header", "price", "note", "cols", "bar" or nil. selling: on the sell
-- page (no Next buy). Also returns the summary under the item's name.
local function Lines(id, selling)
	local QB = ns.QuickBuy
	local cut = 1 - QB.AH_CUT
	local lines = {}
	local function Add(left, mid, right, kind, tip, pct) lines[#lines + 1] = { left, mid, right, kind, tip, pct } end

	local itemName = Name(id)
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
	-- What the rows that go by it are called.
	local resell = typed and "List at your price" or target and ("Resell " .. CUSTOM .. "(custom)|r") or "Resell"
	local uses = {}
	for _, u in ipairs(ns.Crafting and ns.Crafting.Uses and ns.Crafting.Uses(id) or {}) do
		if u.worth and #uses < 3 then uses[#uses + 1] = u end
	end

	local summaryText = bought == 0 and (want and ("Nothing bought yet - want %d"):format(want) or "Nothing bought yet")
		or want and ("Bought %d of %d"):format(bought, want) or ("Bought %d"):format(bought)

	-- This session
	if bought > 0 then
		Add("This session", nil, nil, "header", Tip("This session", "Everything bought since you last pressed Clear."))
		Add("Average cost", nil, ns.Money(math.floor(avg + 0.5)) .. " each", nil, Tip("Average cost",
			("What you've paid per item: %s for %d."):format(ns.Money(spent), bought)))
		Add("Spent", nil, ns.Money(spent))
		Add("Break-even relist", nil, ns.Money(QB.RelistPrice(spent, bought)) .. " each", nil,
			Tip("Break-even relist", ("The lowest price to list all %d at and still make a profit after the 5%% cut.")
				:format(bought)))
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

	-- What it's worth: each way of using what you've bought.
	if bought > 0 then
		Add("What it's worth", nil, nil, "header", Tip("What it's worth",
			"Profit on what you've bought, per item and in total."))
		Add(nil, "each", "all " .. bought, "cols", nil, "return")
		local options = {}
		if sell then
			options[#options + 1] = { name = resell, each = net - avg,
				tip = Tip("Resell at " .. ns.Money(sell),
					("After the 5%% cut you get %s for all %d; you paid %s."):format(
						ns.Money(math.floor(net * bought)), bought, ns.Money(spent))) }
		end
		for _, u in ipairs(uses) do
			local source, worth = CraftSource(u, itemName)
			local short = bought < u.qty and (GREY .. ("%d more for one craft|r"):format(u.qty - bought)) or nil
			options[#options + 1] = { name = Name(u.output), each = u.worth - avg, note = short,
				tip = Tip(Name(u.output), source, worth, ("You paid %s on average."):format(ns.Money(avg))) }
		end
		local best
		for _, o in ipairs(options) do
			if not best or o.each > best.each then best = o end
		end
		for _, o in ipairs(options) do
			local name = o.name
			if o == best and #options > 1 then name = name .. "  " .. GREY .. "best|r" end
			Add(name, Signed(o.each), Signed(o.each * bought), nil, o.tip, ns.Percent(o.each / avg * 100))
			if o.note then Add("   " .. o.note, nil, nil, "note") end
		end
		if #options == 0 then Add("No price to go by yet", nil, nil, "note") end
	end

	-- Next buy, at "Up to".
	if not selling then
		Add("Next buy", nil, max and ("up to " .. ns.Money(max)) or nil, "header",
			Tip("Next buy", "Profit per item at your \"Up to\" price."))
		if not max then
			Add("Set \"Up to\" to see", nil, nil, "note")
		else
			if sell then
				Add(resell, Signed(net - max), nil, nil,
					Tip("Resell at " .. ns.Money(sell), ("After the 5%% cut you get %s each."):format(ns.Money(net))),
					ns.Percent((net - max) / max * 100))
			end
			for _, u in ipairs(uses) do
				local source, worth = CraftSource(u, itemName)
				Add(Name(u.output), Signed(u.worth - max), nil, nil, Tip(Name(u.output), source, worth),
					ns.Percent((u.worth - max) / max * 100))
			end
			if not sell and #uses == 0 then Add("No price to go by yet", nil, nil, "note") end
		end
		if #uses == 0 then
			Add("No saved recipe uses it (open your profession", nil, nil, "note")
			Add("window to save them)", nil, nil, "note")
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
	return lines, summaryText, want and math.min(1, bought / want) or nil
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

-- The commodity on the sell page, if you've bought some of it this session.
local function SellingItem()
	local sf = AuctionHouseFrame and AuctionHouseFrame.CommoditiesSellFrame
	if not (sf and sf:IsVisible() and sf.GetItem) then return nil end
	local ok, id = pcall(function()
		local loc = sf:GetItem()
		return loc and loc.IsValid and loc:IsValid() and C_Item.GetItemID(loc)
	end)
	if ok and id and ns.QuickBuy.Session(id) > 0 then return id end
	return nil
end

-- What to show: the item on the buy page, or the one you're selling (and true).
local function Current()
	local id = ns.QuickBuy and ns.QuickBuy.Item()
	if id then return id, false end
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
			or (kind == "note" or kind == "cols") and "GameFontDisableSmall" or "GameFontHighlightSmall")
		row.mid:SetFontObject(kind == "cols" and "GameFontDisableSmall" or "GameFontHighlightSmall")
		row.right:SetFontObject(kind == "cols" and "GameFontDisableSmall" or kind == "price" and "GameFontHighlight"
			or "GameFontHighlightSmall")
		row.pct:SetFontObject(kind == "cols" and "GameFontDisableSmall" or "GameFontHighlightSmall")
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
-- Clear all sessions (Auctions tab)
---------------------------------------------------------------------------
-- "Silk Cloth: 26 for 2g 2s" for each session, for the Clear all popup.
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
	text = "Clear all purchase sessions?\n\n%s",
	button1 = YES,
	button2 = NO,
	OnAccept = function()
		local n = ns.QuickBuy.ClearAll()
		ns.Print(n == 1 and "cleared 1 session." or ("cleared %d sessions."):format(n))
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
	end, "buyInfo")
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

	-- Clear all sessions: on the Auctions tab only, along the bottom just
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
	clearAll:SetText("Clear all sessions")
	clearAll:SetScript("OnClick", function()
		if #ns.QuickBuy.Sessions() > 0 then StaticPopup_Show("FIREAUCTION_CLEAR_SESSIONS", SessionList()) end
	end)
	clearAll:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Clear all sessions", 1, 1, 1)
		GameTooltip:AddLine("Start every item's session over. Asks first.", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	clearAll:SetScript("OnLeave", function() GameTooltip:Hide() end)
	clearAll:Hide()

	-- Its tab on the auction house window's edge (the first).
	local tab = ns.SideTab(1, "Interface\\Icons\\INV_Misc_Coin_01", "Purchase tracker", "buyInfo",
		function() elapsed = 1 end)
	f.tab = tab

	-- Shows and updates everything, a few times a second while the auction house is open.
	local driver = CreateFrame("Frame", nil, AuctionHouseFrame)
	driver:SetScript("OnUpdate", function(_, dt)
		elapsed = elapsed + dt
		if elapsed < 0.25 then return end
		elapsed = 0
		local id, selling = Current()
		clearAll:SetShown(ns.QuickBuy and #ns.QuickBuy.Sessions() > 0)
		tab:SetShown(id ~= nil)
		f:SetShown(id ~= nil and ns.db.buyInfo)
		if id and ns.db.buyInfo then ns.SafeCall(Update, id, selling) end
	end)
	driver:SetScript("OnShow", function() elapsed = 1 end)
end

ns.On("AUCTION_HOUSE_SHOW", function()
	if not frame then Create() end
end)
