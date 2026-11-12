-- A panel on the right of the auction house while you're on a commodity's
-- buy page (Silk Cloth...), next to Quick buy. Hidden by default; a tab on
-- the window's edge opens it (remembered).
--
--   This session      how many you've bought (toward Want), what it cost, and
--                     the price to relist at to break even.
--   What it's worth   what you've bought makes each way - resold, or crafted
--                     with one of your saved recipes - each and for all of
--                     it, the best way marked.
--   Next buy          the same at your "Up to" price: is the next one worth it.
--   Recent            the last few purchases.
--
-- Everything after the auction house's 5% cut. Hover a line for how it's
-- worked out.
local _, ns = ...

local WIDTH = 320
local PAD = 12
local ROW = 15
local COL = 64     -- width of a number column ("all")
local PCT = 40     -- width of the "return" column
local RECENT = 4   -- purchases listed under Recent
local GREY = "|cff999999"

local frame, rows, title, bar
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

-- Where the resell price comes from, for tooltips.
local function SellSource(approx)
	if approx then
		return "No listings loaded, so it's the usual price: the average of your scans' market price over the last "
			.. ns.Data.TrendDays() .. " days."
	end
	return "The cheapest listing left after Quick buy buys what it can - what you'd list against."
end

-- The crafted item's price, for tooltips: "Bolt of Silk Cloth sells for 8s 70c".
local function CraftSource(u, itemName)
	local text = Name(u.output) .. " sells for " .. ns.Money(u.unit or 0)
		.. (u.source == "vendor" and " (to a vendor)" or not u.current and " (last seen; not listed in your latest scan)"
			or "") .. ". One craft takes " .. u.qty .. " " .. itemName
		.. (u.other > 0 and (" and " .. ns.Money(u.other) .. " of other reagents") or "")
		.. (u.made > 1 and (" and makes " .. u.made) or "") .. "."
	return text, ("After the 5%% cut, each %s brings in %s that way."):format(itemName, ns.Money(u.worth))
end

-- The lines to show for itemID: { { left, mid, right, kind, tip, pct }, ... }, kind
-- being "header", "note", "cols", "bar" or nil.
local function Lines(id)
	local QB = ns.QuickBuy
	local cut = 1 - QB.AH_CUT
	local lines = {}
	local function Add(left, mid, right, kind, tip, pct) lines[#lines + 1] = { left, mid, right, kind, tip, pct } end

	local itemName = Name(id)
	local bought, spent, want, max, log = QB.Session(id)
	local sell, approx = QB.SellPrice(id)
	local net = sell and math.floor(sell * cut)
	local avg = bought > 0 and spent / bought or nil
	local sellText = sell and ((approx and "~" or "") .. ns.Money(sell))
	local uses = {}
	for _, u in ipairs(ns.Crafting and ns.Crafting.Uses and ns.Crafting.Uses(id) or {}) do
		if u.worth and #uses < 3 then uses[#uses + 1] = u end
	end

	-- This session
	Add("This session", nil, want and ("%d / %d"):format(bought, want) or (bought > 0 and tostring(bought) or nil),
		"header", Tip("This session", "Everything you've bought of it (Quick buy or Blizzard's Buy button) since "
			.. "you last pressed Clear."))
	if want then
		Add(nil, nil, nil, "bar")
		lines[#lines].value = math.min(1, bought / want)
	end
	if bought == 0 then
		Add("Nothing bought yet", nil, nil, "note")
	else
		Add("Spent", nil, ns.Money(spent) .. GREY .. "  (" .. ns.Money(avg) .. " each)|r")
		Add("Break-even relist", nil, ns.Money(QB.RelistPrice(spent, bought)) .. " each", nil,
			Tip("Break-even relist", ("The lowest price to list all %d at and still make a profit after the 5%% cut.")
				:format(bought)))
	end

	-- What it's worth: each way of using what you've bought.
	if bought > 0 then
		Add("What it's worth", nil, nil, "header", Tip("What it's worth", "The profit on what you've bought, "
			.. "each way you could use it: per item, and for all of it. Hover a line for how it's worked out."))
		Add(nil, "each", "all " .. bought, "cols", nil, "return")
		local options = {}
		if sell then
			options[#options + 1] = { name = "Resell at " .. sellText, each = net - avg,
				tip = Tip("Resell at " .. sellText, SellSource(approx),
					("After the 5%% cut you get %s each; you paid %s on average."):format(ns.Money(net), ns.Money(avg))) }
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
		if #options == 0 then Add("No price to go by yet - scan first", nil, nil, "note") end
	end

	-- Next buy, at "Up to".
	Add("Next buy", nil, max and ("up to " .. ns.Money(max)) or nil, "header",
		Tip("Next buy", "What one bought at your \"Up to\" price makes each way."))
	if not max then
		Add("Set \"Up to\" to see", nil, nil, "note")
	else
		if sell then
			Add("Resell at " .. sellText, Signed(net - max), nil, nil,
				Tip("Resell at " .. sellText, SellSource(approx),
					("After the 5%% cut you get %s each."):format(ns.Money(net))), ns.Percent((net - max) / max * 100))
		end
		for _, u in ipairs(uses) do
			local source, worth = CraftSource(u, itemName)
			Add(Name(u.output), Signed(u.worth - max), nil, nil, Tip(Name(u.output), source, worth),
				ns.Percent((u.worth - max) / max * 100))
		end
		if not sell and #uses == 0 then Add("No price to go by yet - scan first", nil, nil, "note") end
	end
	if #uses == 0 then
		Add("No saved recipe uses it (open your profession", nil, nil, "note")
		Add("window to save them)", nil, nil, "note")
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
	return lines
end

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

local function Update()
	local id = ns.QuickBuy and ns.QuickBuy.Item()
	if not id then
		frame:SetAlpha(0)
		return
	end
	frame:SetAlpha(1)
	title:SetText(Name(id))
	local texture = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)
	frame.icon:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")

	local y = -PAD - 26
	local lines = Lines(id)
	bar:Hide()
	for i, line in ipairs(lines) do
		local row = Row(i)
		local left, mid, right, kind, tip, pct = line[1], line[2], line[3], line[4], line[5], line[6]
		if kind == "header" and i > 1 then y = y - 8 end
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", PAD, y)
		row:SetPoint("TOPRIGHT", -PAD, y)
		row.left:SetFontObject(kind == "header" and "GameFontNormal" or (kind == "note" or kind == "cols")
			and "GameFontDisableSmall" or "GameFontHighlightSmall")
		row.mid:SetFontObject(kind == "cols" and "GameFontDisableSmall" or "GameFontHighlightSmall")
		row.right:SetFontObject(kind == "cols" and "GameFontDisableSmall" or "GameFontHighlightSmall")
		row.pct:SetFontObject(kind == "cols" and "GameFontDisableSmall" or "GameFontHighlightSmall")
		-- Number columns from the right: [return] all, then each.
		local shift = pct and PCT or 0
		row.right:ClearAllPoints()
		row.right:SetPoint("RIGHT", -shift, 0)
		row.mid:ClearAllPoints()
		row.mid:SetPoint("RIGHT", -shift - COL, 0)
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
		if kind == "bar" then
			row:Hide()
			bar:ClearAllPoints()
			bar:SetPoint("TOPLEFT", PAD, y - 1)
			bar:SetPoint("TOPRIGHT", -PAD, y - 1)
			bar:SetValue(line.value or 0)
			bar:Show()
			y = y - 12
		else
			y = y - ROW - (kind == "header" and 2 or 0)
		end
	end
	for i = #lines + 1, #rows do rows[i]:Hide() end
	frame:SetHeight(-y + PAD - 2)
end

local function Create()
	local buyFrame = AuctionHouseFrame and AuctionHouseFrame.CommoditiesBuyFrame
	if not buyFrame then return end
	rows = {}
	-- On the buy page, so it comes and goes with it; pinned outside the
	-- auction house window's right edge, beside its tab (below). Hidden until
	-- you open it.
	local ok, f = pcall(CreateFrame, "Frame", "FireAuctionBuyInfo", buyFrame, "BackdropTemplate")
	if not ok then f = CreateFrame("Frame", "FireAuctionBuyInfo", buyFrame) end
	frame = f
	f:SetWidth(WIDTH)
	f:SetHeight(100)
	f:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 40, -24)
	if f.SetBackdrop then
		f:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 16,
			insets = { left = 4, right = 4, top = 4, bottom = 4 },
		})
		f:SetBackdropColor(0.06, 0.06, 0.06, 0.92)
		f:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
	end

	f.icon = f:CreateTexture(nil, "ARTWORK")
	f.icon:SetSize(20, 20)
	f.icon:SetPoint("TOPLEFT", PAD, -PAD + 2)
	title = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	title:SetPoint("LEFT", f.icon, "RIGHT", 6, 0)
	title:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
	title:SetJustifyH("LEFT")

	-- Progress toward Want.
	bar = CreateFrame("StatusBar", nil, f)
	bar:SetHeight(8)
	bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	bar:SetStatusBarColor(0.25, 0.75, 0.25)
	bar:SetMinMaxValues(0, 1)
	local bg = bar:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(1, 1, 1, 0.1)
	bar:Hide()

	f:SetScript("OnUpdate", function(_, dt)
		elapsed = elapsed + dt
		if elapsed < 0.25 then return end
		elapsed = 0
		ns.SafeCall(Update)
	end)
	f:SetScript("OnShow", function() elapsed = 1 end)
	f:SetShown(ns.db.buyInfo)

	-- The side tab that opens and closes it (like the spellbook's tabs), on
	-- the auction house window's right edge while you're on a buy page.
	local tab = CreateFrame("CheckButton", nil, buyFrame)
	tab:SetSize(32, 32)
	tab:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 0, -36)
	local back = tab:CreateTexture(nil, "BACKGROUND")
	back:SetSize(64, 64)
	back:SetPoint("TOPLEFT", -3, 11)
	back:SetTexture("Interface\\SpellBook\\SpellBook-SkillLineTab")
	tab:SetNormalTexture("Interface\\Icons\\INV_Misc_Coin_01")
	tab:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	tab:SetCheckedTexture("Interface\\Buttons\\CheckButtonHilight", "ADD")
	tab:SetChecked(ns.db.buyInfo)
	tab:SetScript("OnClick", function(self)
		ns.db.buyInfo = not ns.db.buyInfo
		self:SetChecked(ns.db.buyInfo)
		f:SetShown(ns.db.buyInfo)
		if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB then PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB) end
	end)
	tab:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Purchase tracker", 1, 1, 1)
		GameTooltip:AddLine("What you've bought this session, what it cost, and what it's worth resold or "
			.. "crafted. Click to " .. (ns.db.buyInfo and "hide" or "show") .. " it.", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	tab:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

ns.On("AUCTION_HOUSE_SHOW", function()
	if not frame then Create() end
end)
