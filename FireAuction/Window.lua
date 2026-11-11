-- The price window (/fah, the key binding, or Prices on the auction house):
-- search your saved prices, pick an item, and see its price over time.
local _, ns = ...

local Window = {}
ns.Window = Window

local WIDTH, HEIGHT = 680, 430
local LIST_W = 260
local ROWS, ROW_H = 15, 20
local GRAPH_H = 170

local PRICE_COLOR = { 1, 0.82, 0 }
local TREND_COLOR = { 0.45, 0.65, 1 }

local frame, search, sortButton, countText, rows = nil, nil, nil, nil, {}
local titleText, houseButton, UpdateHouse
local detail = {}
local results, offset, selected = {}, 0, nil

local SORTS = {
	{ key = "name", label = "Name" },
	{ key = "price", label = "Price" },
	{ key = "rising", label = "Rising" },
	{ key = "falling", label = "Falling" },
}
local sortIndex = 1

-- Which auction house's prices the window shows: "faction" or "neutral" if
-- switched, else nil - the one you're at (your faction's when you aren't).
local view = nil
local function View()
	return view or ns.house or "faction"
end

local function ItemIcon(id)
	return (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id))
		or (GetItemIcon and GetItemIcon(id)) or 134400 -- question mark
end

---------------------------------------------------------------------------
-- Favorites: pinned to the top of the list in every sort (all characters).
---------------------------------------------------------------------------
local function IsFavorite(id)
	return ns.db.favorites[id] == true
end

local STAR_ATLAS_ON, STAR_ATLAS_OFF = "auctionhouse-icon-favorite", "auctionhouse-icon-favorite-off"
local hasStarAtlas = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(STAR_ATLAS_ON) ~= nil

-- on: filled star; off: an empty one (or a faded star without the atlas).
local function SetStar(texture, on)
	if hasStarAtlas then
		texture:SetAtlas(on and STAR_ATLAS_ON or STAR_ATLAS_OFF)
		texture:SetAlpha(1)
	else
		texture:SetTexture("Interface\\Common\\ReputationStar")
		texture:SetTexCoord(0, 0.5, 0, 0.5)
		texture:SetDesaturated(not on)
		texture:SetAlpha(on and 1 or 0.4)
	end
end

local function QualityColor(id)
	local q = C_Item and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(id)
	local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
	if c then return c.r, c.g, c.b end
	return 1, 1, 1
end

---------------------------------------------------------------------------
-- Results
---------------------------------------------------------------------------
local function BuildResults()
	wipe(results)
	local realm = ns.Realm(View())
	if not realm then return end
	local query = search and strtrim(search:GetText() or ""):lower() or ""
	local sort = SORTS[sortIndex].key
	for id, rec in pairs(realm.items) do
		local name = ns.Data.Name(id, rec)
		if not name and C_Item and C_Item.RequestLoadItemDataByID then
			pcall(C_Item.RequestLoadItemDataByID, id)
		end
		if query == "" or (name and name:lower():find(query, 1, true)) then
			local entry = { id = id, rec = rec, name = name or ("item " .. id), fav = IsFavorite(id) }
			if sort == "rising" or sort == "falling" then entry.pct = ns.Data.Trend(rec) end
			-- Rising/falling only lists items with a trend - except favorites, which always show.
			if (sort ~= "rising" and sort ~= "falling") or entry.pct or entry.fav then
				results[#results + 1] = entry
			end
		end
	end
	table.sort(results, function(a, b)
		if a.fav ~= b.fav then return a.fav end
		if sort == "price" then
			if a.rec.p ~= b.rec.p then return (a.rec.p or 0) > (b.rec.p or 0) end
		elseif sort == "rising" or sort == "falling" then
			if a.pct ~= b.pct then
				if not a.pct or not b.pct then return a.pct ~= nil end
				if sort == "rising" then return a.pct > b.pct end
				return a.pct < b.pct
			end
		end
		return a.name < b.name
	end)
end

local function UpdateRows()
	local maxOffset = math.max(0, #results - ROWS)
	offset = math.max(0, math.min(offset, maxOffset))
	for i = 1, ROWS do
		local row, entry = rows[i], results[offset + i]
		if entry then
			row.entry = entry
			row.icon:SetTexture(ItemIcon(entry.id))
			row.name:SetText(entry.name)
			row.name:SetTextColor(QualityColor(entry.id))
			row.star:SetShown(entry.fav)
			if entry.pct then
				row.value:SetText(ns.Percent(entry.pct))
			elseif (entry.rec.q or 0) > 0 then
				row.value:SetText(ns.Money(entry.rec.p))
			else
				row.value:SetText("|cff999999none listed|r")
			end
			row.selected:SetShown(entry.id == selected)
			row:Show()
		else
			row.entry = nil
			row:Hide()
		end
	end
	if #results == 0 then
		local realm = ns.Realm(View())
		local empty = not realm or next(realm.items) == nil
		countText:SetText(empty and "No prices yet - scan at the auction house." or "No matches.")
	elseif #results > ROWS then
		countText:SetText(("%d-%d of %d items (scroll for more)"):format(offset + 1, math.min(offset + ROWS, #results), #results))
	else
		countText:SetText(("%d items"):format(#results))
	end
end

---------------------------------------------------------------------------
-- Graph
---------------------------------------------------------------------------
local graph
local lines, dots, gridLabels = {}, {}, {}
local nLines, nDots = 0, 0

local function Line(r, g, b, a, thickness)
	nLines = nLines + 1
	local l = lines[nLines]
	if not l then
		l = graph:CreateLine(nil, "ARTWORK")
		lines[nLines] = l
	end
	l:SetThickness(thickness or 2)
	l:SetColorTexture(r, g, b, a or 1)
	l:Show()
	return l
end

local function Dot(x, y, r, g, b)
	nDots = nDots + 1
	local d = dots[nDots]
	if not d then
		d = graph:CreateTexture(nil, "OVERLAY")
		d:SetSize(5, 5)
		dots[nDots] = d
	end
	d:SetColorTexture(r, g, b, 1)
	d:ClearAllPoints()
	d:SetPoint("CENTER", graph, "BOTTOMLEFT", x, y)
	d:Show()
end

local function ClearGraph()
	for i = 1, #lines do lines[i]:Hide() end
	for i = 1, #dots do dots[i]:Hide() end
	nLines, nDots = 0, 0
	graph.points = nil
	graph.marker:Hide()
end

local function ShortDate(day)
	return date("%b %d", ns.Data.DayTime(day))
end

local function DrawGraph(rec)
	ClearGraph()
	local history = ns.Data.History(rec)
	if #history == 0 then
		graph.empty:Show()
		for _, l in ipairs(gridLabels) do l:SetText("") end
		return
	end
	graph.empty:Hide()

	local today = ns.Data.Today()
	local first = math.min(history[1][1], today)
	-- The trend covers the days it has prices for, and projects as far ahead.
	local _, projected, slope, now, trendDays = ns.Data.Trend(rec)
	local last = slope and (today + trendDays) or today
	if last == first then first = first - 1 end

	local low, high = math.huge, 0
	for _, h in ipairs(history) do
		low, high = math.min(low, h[2]), math.max(high, h[2])
	end
	if slope then
		local start = now - slope * trendDays
		low = math.min(low, start, projected)
		high = math.max(high, start, projected)
	end
	if high == low then high, low = high * 1.1 + 1, low * 0.9 end
	local pad = (high - low) * 0.08
	high, low = high + pad, math.max(0, low - pad)

	local w, h = graph:GetWidth(), graph:GetHeight()
	local function X(day) return (day - first) / (last - first) * w end
	local function Y(price) return (price - low) / (high - low) * h end

	-- Grid: three lines with prices, dates underneath.
	for i = 0, 2 do
		local price = low + (high - low) * i / 2
		local l = Line(1, 1, 1, 0.08, 1)
		l:SetStartPoint("BOTTOMLEFT", graph, 0, Y(price))
		l:SetEndPoint("BOTTOMLEFT", graph, w, Y(price))
		gridLabels[i + 1]:SetText(ns.Money(price))
		gridLabels[i + 1]:ClearAllPoints()
		gridLabels[i + 1]:SetPoint("BOTTOMRIGHT", graph, "BOTTOMLEFT", -4, Y(price) - 5)
	end
	graph.firstDate:SetText(ShortDate(first))
	graph.lastDate:SetText(slope and ("+%d days"):format(trendDays) or "Today")
	if slope then
		local todayLine = Line(1, 1, 1, 0.2, 1)
		todayLine:SetStartPoint("BOTTOMLEFT", graph, X(today), 0)
		todayLine:SetEndPoint("BOTTOMLEFT", graph, X(today), h)
		graph.todayLabel:ClearAllPoints()
		graph.todayLabel:SetPoint("TOP", graph, "BOTTOMLEFT", X(today), -4)
		graph.todayLabel:Show()
	else
		graph.todayLabel:Hide()
	end

	-- The trend: back over the trend period, and on into the projection.
	if slope then
		local l = Line(TREND_COLOR[1], TREND_COLOR[2], TREND_COLOR[3], 0.7, 2)
		l:SetStartPoint("BOTTOMLEFT", graph, X(today - trendDays), Y(now - slope * trendDays))
		l:SetEndPoint("BOTTOMLEFT", graph, X(today + trendDays), Y(projected))
	end

	-- The prices.
	local points = {}
	for i, p in ipairs(history) do
		local x, y = X(p[1]), Y(p[2])
		points[i] = { x = x, y = y, day = p[1], price = p[2] }
		if i > 1 then
			local l = Line(PRICE_COLOR[1], PRICE_COLOR[2], PRICE_COLOR[3], 1, 2)
			l:SetStartPoint("BOTTOMLEFT", graph, points[i - 1].x, points[i - 1].y)
			l:SetEndPoint("BOTTOMLEFT", graph, x, y)
		end
		Dot(x, y, PRICE_COLOR[1], PRICE_COLOR[2], PRICE_COLOR[3])
	end
	graph.points = points
end

-- Hovering the graph shows the nearest day's price.
local function GraphHover(self)
	local points = self.points
	if not points then return end
	local cx = GetCursorPosition() / self:GetEffectiveScale()
	local x = cx - self:GetLeft()
	local best
	for _, p in ipairs(points) do
		if not best or math.abs(p.x - x) < math.abs(best.x - x) then best = p end
	end
	if best and best ~= self.hovered then
		self.hovered = best
		self.marker:ClearAllPoints()
		self.marker:SetPoint("CENTER", self, "BOTTOMLEFT", best.x, best.y)
		self.marker:Show()
		GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
		GameTooltip:SetText(date("%A, %B %d", ns.Data.DayTime(best.day)), 1, 1, 1)
		GameTooltip:AddLine(ns.Money(best.price), 1, 1, 1)
		GameTooltip:Show()
	end
end

---------------------------------------------------------------------------
-- Listings: a panel beside the window with every auction from the latest
-- scan, opened with "See all listings".
---------------------------------------------------------------------------
local LIST_ROWS, LIST_ROW_H = 19, 18
local listPanel, listRows, listOffset, listData = nil, {}, 0, {}

local function ListingTooltip(row)
	local l = row.listing
	if not l then return end
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	if l.buyout > 0 then
		GameTooltip:SetText(("%d x %d"):format(l.count, l.stack), 1, 1, 1)
		GameTooltip:AddDoubleLine("Buyout per item", ns.Money(l.unit), 1, 0.82, 0, 1, 1, 1)
		GameTooltip:AddDoubleLine("Buyout per stack", ns.Money(l.buyout), 1, 0.82, 0, 1, 1, 1)
	else
		GameTooltip:SetText(("%d x %d (bid only)"):format(l.count, l.stack), 1, 1, 1)
		GameTooltip:AddDoubleLine("Bid per item", ns.Money(l.unit), 1, 0.82, 0, 1, 1, 1)
		GameTooltip:AddDoubleLine("Bid per stack", ns.Money(l.bid), 1, 0.82, 0, 1, 1, 1)
	end
	if l.count > 1 then
		GameTooltip:AddLine(("%d auctions just like this one"):format(l.count), 0.7, 0.7, 0.7)
	end
	GameTooltip:Show()
end

local function UpdateListRows()
	local maxOffset = math.max(0, #listData - LIST_ROWS)
	listOffset = math.max(0, math.min(listOffset, maxOffset))
	for i = 1, LIST_ROWS do
		local row, l = listRows[i], listData[listOffset + i]
		row.listing = l
		if l then
			if l.buyout > 0 then
				row.price:SetText(ns.Money(l.unit))
			else
				row.price:SetText("|cff999999bid|r " .. ns.Money(l.unit))
			end
			row.stack:SetText(l.count > 1 and ("%d |cff999999x%d|r"):format(l.stack, l.count) or tostring(l.stack))
			row:Show()
		else
			row:Hide()
		end
	end
end

local function UpdateListPanel()
	if not (listPanel and listPanel:IsShown()) then return end
	local rec = selected and ns.Data.Get(selected, View())
	listData = ns.Data.Listings(rec)
	listOffset = 0
	listPanel.title:SetText(rec and (ns.Data.Name(selected, rec) or ("item " .. selected)) or "Listings")
	if #listData == 0 then
		listPanel.footer:SetText(rec and "None listed in the latest scan." or "")
	else
		local auctions, items = 0, 0
		for _, l in ipairs(listData) do
			auctions, items = auctions + l.count, items + l.count * l.stack
		end
		listPanel.footer:SetText(("%d auctions, %d items - scanned %s"):format(auctions, items, ns.TimeAgo(rec.s)))
	end
	UpdateListRows()
end

local function BuildListPanel()
	local ok, p = pcall(CreateFrame, "Frame", "FireAuctionListings", frame, "BasicFrameTemplateWithInset")
	if not ok then
		p = CreateFrame("Frame", "FireAuctionListings", frame, "BackdropTemplate")
		p:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			tile = true, tileSize = 32, edgeSize = 32,
			insets = { left = 11, right = 12, top = 12, bottom = 11 },
		})
		local close = CreateFrame("Button", nil, p, "UIPanelCloseButton")
		close:SetPoint("TOPRIGHT", -4, -4)
	end
	p:SetSize(230, HEIGHT)
	p:SetPoint("TOPLEFT", frame, "TOPRIGHT", -2, 0)
	p:EnableMouse(true)
	p:Hide()

	local title = type(p.TitleText) == "table" and p.TitleText or nil
	if not title then
		title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		title:SetPoint("TOP", 0, -6)
	end
	title:SetWidth(170)
	title:SetWordWrap(false)
	p.title = title

	local function Header(text, x, width, justify)
		local h = p:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		h:SetPoint("TOPLEFT", x, -34)
		h:SetWidth(width)
		h:SetJustifyH(justify)
		h:SetText(text)
	end
	Header("Price each", 14, 120, "RIGHT")
	Header("Stack", 144, 66, "RIGHT")

	local area = CreateFrame("Frame", nil, p)
	area:SetPoint("TOPLEFT", 10, -50)
	area:SetSize(210, LIST_ROWS * LIST_ROW_H)
	area:EnableMouseWheel(true)
	area:SetScript("OnMouseWheel", function(_, delta)
		listOffset = listOffset - delta * 3
		UpdateListRows()
	end)
	for i = 1, LIST_ROWS do
		local row = CreateFrame("Frame", nil, area)
		row:SetSize(210, LIST_ROW_H)
		row:SetPoint("TOPLEFT", 0, -(i - 1) * LIST_ROW_H)
		row:EnableMouse(true)
		if i % 2 == 0 then
			local stripe = row:CreateTexture(nil, "BACKGROUND")
			stripe:SetAllPoints()
			stripe:SetColorTexture(1, 1, 1, 0.04)
		end
		local hl = row:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 0.82, 0, 0.12)
		row.price = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		row.price:SetPoint("LEFT", 4, 0)
		row.price:SetWidth(120)
		row.price:SetJustifyH("RIGHT")
		row.stack = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		row.stack:SetPoint("LEFT", 134, 0)
		row.stack:SetWidth(66)
		row.stack:SetJustifyH("RIGHT")
		row:SetScript("OnEnter", ListingTooltip)
		row:SetScript("OnLeave", function() GameTooltip:Hide() end)
		listRows[i] = row
	end
	p.footer = p:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	p.footer:SetPoint("BOTTOMLEFT", 14, 14)
	p.footer:SetPoint("BOTTOMRIGHT", -14, 14)
	p.footer:SetJustifyH("LEFT")

	p:SetScript("OnShow", function()
		ns.SafeCall(UpdateListPanel)
		if detail.more then detail.more:Update() end
	end)
	p:SetScript("OnHide", function()
		if detail.more then detail.more:Update() end
	end)
	listPanel = p
end

local function ToggleListPanel()
	if not listPanel then BuildListPanel() end
	listPanel:SetShown(not listPanel:IsShown())
end

---------------------------------------------------------------------------
-- Details of the selected item
---------------------------------------------------------------------------
local function UpdateDetail()
	local rec = selected and ns.Data.Get(selected, View())
	detail.star:Update()
	if not rec then
		detail.icon:Hide()
		detail.name:SetText("")
		detail.text:SetText(next(results) and "Pick an item on the left." or "")
		graph:Hide()
		detail.more:Hide()
		return
	end
	detail.icon:SetTexture(ItemIcon(selected))
	detail.icon:Show()
	detail.name:SetText(ns.Data.Name(selected, rec) or ("item " .. selected))
	detail.name:SetTextColor(QualityColor(selected))

	local info = {}
	if (rec.q or 0) > 0 then
		info[#info + 1] = ("Lowest buyout: %s  |cff999999(%d listed)|r"):format(ns.Money(rec.p), rec.q)
	else
		info[#info + 1] = ("Lowest buyout: |cff999999none listed (was|r %s|cff999999)|r"):format(ns.Money(rec.p))
	end
	info[#info + 1] = "|cff999999Seen " .. ns.TimeAgo(rec.s) .. "|r"
	local pct, projected, _, _, days = ns.Data.Trend(rec)
	if pct then
		local span = days == 1 and "day" or (days .. " days")
		info[#info + 1] = ("Last %s: %s   Projected in %s: %s"):format(span, ns.Percent(pct), span, ns.Money(projected))
	else
		info[#info + 1] = "|cff999999No trend yet - it needs prices from at least two days.|r"
	end
	local low, high
	for _, price in pairs(rec.d) do
		low, high = math.min(low or price, price), math.max(high or price, price)
	end
	if low then
		info[#info + 1] = ("Lowest / highest day: %s / %s"):format(ns.Money(low), ns.Money(high))
	end
	detail.text:SetText(table.concat(info, "\n"))
	detail.more:Show()
	detail.more:Update()
	ns.SafeCall(UpdateListPanel)
	graph:Show()
	DrawGraph(rec)
end

function Window.Select(itemID)
	selected = itemID
	UpdateRows()
	UpdateDetail()
end

function Window.ToggleFavorite(itemID)
	if not itemID then return end
	ns.db.favorites[itemID] = not IsFavorite(itemID) or nil
	ns.SafeCall(BuildResults)
	UpdateRows()
	if detail.star then detail.star:Update() end
end

---------------------------------------------------------------------------
-- Building the window
---------------------------------------------------------------------------
local function SavePoint()
	local point, _, rel, x, y = frame:GetPoint()
	ns.db.windowPoint = { point, rel, x, y }
end

local function Build()
	local ok, f = pcall(CreateFrame, "Frame", "FireAuctionFrame", UIParent, "BasicFrameTemplateWithInset")
	if not ok then
		f = CreateFrame("Frame", "FireAuctionFrame", UIParent, "BackdropTemplate")
		f:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			tile = true, tileSize = 32, edgeSize = 32,
			insets = { left = 11, right = 12, top = 12, bottom = 11 },
		})
		local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
		close:SetPoint("TOPRIGHT", -4, -4)
	end
	frame = f
	f:SetSize(WIDTH, HEIGHT)
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		SavePoint()
	end)
	local p = ns.db.windowPoint or { "CENTER", "CENTER", 0, 40 }
	f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
	f:Hide()
	table.insert(UISpecialFrames, "FireAuctionFrame")

	local title = type(f.TitleText) == "table" and f.TitleText or nil
	if not title then
		title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		title:SetPoint("TOP", 0, -6)
	end
	titleText = title

	-- Switch between your faction's auction house and the neutral one.
	houseButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	houseButton:SetSize(150, 22)
	houseButton:SetPoint("BOTTOMLEFT", 14, 12)
	houseButton:SetScript("OnClick", function(self)
		view = View() == "neutral" and "faction" or "neutral"
		Window.Refresh()
		if GameTooltip:IsOwned(self) then self:GetScript("OnEnter")(self) end
	end)
	houseButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Auction house", 1, 1, 1)
		GameTooltip:AddLine(("Showing prices from the %s auction house. Click for the %s one."):format(
			View() == "neutral" and "neutral" or ns.HouseName("faction"),
			View() == "neutral" and ns.HouseName("faction") or "neutral (Booty Bay, Gadgetzan, Everlook)"),
			nil, nil, nil, true)
		GameTooltip:AddLine("Each auction house has its own prices; scans are saved to the one you're at.",
			0.6, 0.6, 0.6, true)
		GameTooltip:Show()
	end)
	houseButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- Search and sort
	local okSearch, box = pcall(CreateFrame, "EditBox", nil, f, "SearchBoxTemplate")
	if not okSearch then box = CreateFrame("EditBox", nil, f, "InputBoxTemplate") end
	box:SetSize(LIST_W - 84, 20)
	box:SetPoint("TOPLEFT", 18, -32)
	box:SetAutoFocus(false)
	box:HookScript("OnTextChanged", function()
		offset = 0
		ns.SafeCall(BuildResults)
		UpdateRows()
	end)
	box:HookScript("OnEnterPressed", function(self)
		self:ClearFocus()
		if results[1] then Window.Select(results[1].id) end
	end)
	box:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Search", 1, 1, 1)
		GameTooltip:AddLine("Type part of a name, or shift-click an item while typing here.", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	box:HookScript("OnLeave", function() GameTooltip:Hide() end)
	search = box

	sortButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	sortButton:SetSize(74, 22)
	sortButton:SetPoint("LEFT", box, "RIGHT", 6, 0)
	sortButton:SetText(SORTS[sortIndex].label)
	sortButton:SetScript("OnClick", function(self)
		sortIndex = sortIndex % #SORTS + 1
		self:SetText(SORTS[sortIndex].label)
		offset = 0
		ns.SafeCall(BuildResults)
		UpdateRows()
	end)
	sortButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Sort by", 1, 1, 1)
		GameTooltip:AddLine("Name, price, or the biggest price rises / falls over the trend period.", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	sortButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- Result rows
	local list = CreateFrame("Frame", nil, f)
	list:SetPoint("TOPLEFT", 12, -58)
	list:SetSize(LIST_W, ROWS * ROW_H)
	list:EnableMouseWheel(true)
	list:SetScript("OnMouseWheel", function(_, delta)
		offset = offset - delta * 3
		UpdateRows()
	end)
	for i = 1, ROWS do
		local row = CreateFrame("Button", nil, list)
		row:SetSize(LIST_W, ROW_H)
		row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
		row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
		row.selected = row:CreateTexture(nil, "BACKGROUND")
		row.selected:SetAllPoints()
		row.selected:SetColorTexture(1, 0.82, 0, 0.18)
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(ROW_H - 4, ROW_H - 4)
		row.icon:SetPoint("LEFT", 4, 0)
		row.value = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		row.value:SetPoint("RIGHT", -4, 0)
		row.value:SetJustifyH("RIGHT")
		row.name = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
		row.name:SetPoint("RIGHT", row.value, "LEFT", -4, 0)
		row.name:SetJustifyH("LEFT")
		row.name:SetWordWrap(false)
		-- A small star on the icon's corner for favorites.
		row.star = row:CreateTexture(nil, "OVERLAY")
		row.star:SetSize(12, 12)
		row.star:SetPoint("CENTER", row.icon, "TOPLEFT", 1, -1)
		SetStar(row.star, true)
		row.star:Hide()
		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		row:SetScript("OnClick", function(self, button)
			if not self.entry then return end
			if button == "RightButton" then
				Window.ToggleFavorite(self.entry.id)
			else
				Window.Select(self.entry.id)
			end
		end)
		row:SetScript("OnEnter", function(self)
			if not self.entry then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetItemByID(self.entry.id)
			GameTooltip:AddLine(IsFavorite(self.entry.id) and "Right-click to unfavorite" or "Right-click to favorite (pin to the top)",
				0.6, 0.6, 0.6)
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", function() GameTooltip:Hide() end)
		rows[i] = row
	end
	countText = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	countText:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 4, -6)

	local divider = f:CreateTexture(nil, "ARTWORK")
	divider:SetColorTexture(1, 1, 1, 0.12)
	divider:SetWidth(1)
	divider:SetPoint("TOPLEFT", list, "TOPRIGHT", 8, 24)
	divider:SetPoint("BOTTOM", f, "BOTTOM", 0, 12)

	-- Details
	local right = CreateFrame("Frame", nil, f)
	right:SetPoint("TOPLEFT", list, "TOPRIGHT", 18, 24)
	right:SetPoint("BOTTOMRIGHT", -14, 12)
	detail.icon = right:CreateTexture(nil, "ARTWORK")
	detail.icon:SetSize(32, 32)
	detail.icon:SetPoint("TOPLEFT", 0, 0)
	-- Favorite star, top right of the details.
	local star = CreateFrame("Button", nil, right)
	star:SetSize(22, 22)
	star:SetPoint("RIGHT", right, "TOPRIGHT", -2, -16)
	star.tex = star:CreateTexture(nil, "ARTWORK")
	star.tex:SetAllPoints()
	local starHighlight = star:CreateTexture(nil, "HIGHLIGHT")
	starHighlight:SetAllPoints()
	SetStar(starHighlight, true)
	starHighlight:SetAlpha(0.35)
	function star:Update()
		self:SetShown(selected ~= nil and ns.Data.Get(selected, View()) ~= nil)
		SetStar(self.tex, selected and IsFavorite(selected))
	end
	star:SetScript("OnClick", function(self)
		Window.ToggleFavorite(selected)
		if GameTooltip:IsOwned(self) then self:GetScript("OnEnter")(self) end
	end)
	star:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		if selected and IsFavorite(selected) then
			GameTooltip:SetText("Favorite", 1, 1, 1)
			GameTooltip:AddLine("Pinned to the top of the list. Click to unpin.", nil, nil, nil, true)
		else
			GameTooltip:SetText("Favorite", 1, 1, 1)
			GameTooltip:AddLine("Click to pin this item to the top of the list. You can also right-click items in the list.",
				nil, nil, nil, true)
		end
		GameTooltip:Show()
	end)
	star:SetScript("OnLeave", function() GameTooltip:Hide() end)
	detail.star = star

	detail.name = right:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	detail.name:SetPoint("LEFT", detail.icon, "RIGHT", 8, 0)
	detail.name:SetPoint("RIGHT", star, "LEFT", -6, 0)
	detail.name:SetJustifyH("LEFT")
	detail.name:SetWordWrap(false)
	detail.text = right:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	detail.text:SetPoint("TOPLEFT", detail.icon, "BOTTOMLEFT", 0, -10)
	detail.text:SetPoint("RIGHT", 0, 0)
	detail.text:SetJustifyH("LEFT")
	detail.text:SetSpacing(4)

	-- Hovering the item's icon shows its tooltip; shift-click links it.
	local titleHover = CreateFrame("Button", nil, right)
	titleHover:SetAllPoints(detail.icon)
	titleHover:SetScript("OnEnter", function(self)
		if not selected then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetItemByID(selected)
		GameTooltip:Show()
	end)
	titleHover:SetScript("OnLeave", function() GameTooltip:Hide() end)
	titleHover:SetScript("OnClick", function()
		if not (selected and IsModifiedClick and IsModifiedClick()) then return end
		local link = select(2, (C_Item and C_Item.GetItemInfo or GetItemInfo)(selected))
		if link and HandleModifiedItemClick then HandleModifiedItemClick(link) end
	end)

	-- "See all listings": opens the listings panel beside the window.
	local more = CreateFrame("Button", nil, right, "UIPanelButtonTemplate")
	more:SetSize(170, 22)
	more:SetPoint("TOPLEFT", detail.text, "BOTTOMLEFT", 0, -10)
	more:SetScript("OnClick", function() ns.SafeCall(ToggleListPanel) end)
	function more:Update()
		local rec = selected and ns.Data.Get(selected, View())
		local n = 0
		for _, l in ipairs(ns.Data.Listings(rec)) do n = n + l.count end
		if listPanel and listPanel:IsShown() then
			self:SetText("Hide listings")
			self:Enable()
		elseif n > 0 then
			self:SetText(("See all %d listing%s"):format(n, n == 1 and "" or "s"))
			self:Enable()
		else
			self:SetText("No listings")
			self:Disable()
		end
	end
	detail.more = more

	-- Graph (room on the left for price labels, below for dates)
	graph = CreateFrame("Frame", nil, right)
	graph:SetPoint("BOTTOMLEFT", 64, 20)
	graph:SetPoint("BOTTOMRIGHT", -4, 20)
	graph:SetHeight(GRAPH_H)
	local bg = graph:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 0.35)
	for i = 1, 3 do
		gridLabels[i] = graph:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	end
	graph.firstDate = graph:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	graph.firstDate:SetPoint("TOPLEFT", graph, "BOTTOMLEFT", 0, -4)
	graph.lastDate = graph:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	graph.lastDate:SetPoint("TOPRIGHT", graph, "BOTTOMRIGHT", 0, -4)
	graph.todayLabel = graph:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	graph.todayLabel:SetText("Today")
	graph.empty = graph:CreateFontString(nil, "ARTWORK", "GameFontDisable")
	graph.empty:SetPoint("CENTER")
	graph.empty:SetText("No history yet.")
	graph.marker = graph:CreateTexture(nil, "OVERLAY", nil, 7)
	graph.marker:SetSize(9, 9)
	graph.marker:SetColorTexture(1, 1, 1, 1)
	graph.marker:Hide()
	graph:EnableMouse(true)
	graph:SetScript("OnEnter", function(self) self:SetScript("OnUpdate", GraphHover) end)
	graph:SetScript("OnLeave", function(self)
		self:SetScript("OnUpdate", nil)
		self.hovered = nil
		self.marker:Hide()
		GameTooltip:Hide()
	end)
	if not graph.CreateLine then
		-- Very old clients: no lines, just the dots.
		function graph.CreateLine()
			local t = graph:CreateTexture(nil, "ARTWORK")
			t.SetThickness, t.SetStartPoint, t.SetEndPoint = function() end, function() end, function() end
			t:Hide()
			return t
		end
	end

	-- Redraw when the window is resized by the scale or first shown.
	graph:SetScript("OnSizeChanged", function()
		if graph:IsVisible() then ns.SafeCall(UpdateDetail) end
	end)
	f:SetScript("OnShow", function()
		UpdateHouse()
		ns.SafeCall(BuildResults)
		UpdateRows()
		ns.SafeCall(UpdateDetail)
	end)
end

function UpdateHouse() -- (declared at the top)
	local name = ns.HouseName(View())
	titleText:SetText("FireAuction - " .. name .. " Prices")
	houseButton:SetText("Show " .. ns.HouseName(View() == "neutral" and "faction" or "neutral") .. " prices")
end

function Window.Refresh()
	if frame and frame:IsShown() then
		UpdateHouse()
		ns.SafeCall(BuildResults)
		UpdateRows()
		ns.SafeCall(UpdateDetail)
	end
end

-- Opening or leaving an auction house: show that one's prices again.
function Window.HouseChanged()
	view = nil
	Window.Refresh()
end

function Window.Toggle()
	if not frame then Build() end
	frame:SetShown(not frame:IsShown())
end

function Window.Show(itemID)
	if not frame then Build() end
	frame:Show()
	if itemID then Window.Select(itemID) end
end

-- /fah <name or item link>: search, and pick the item if there's one match.
function Window.Search(text, itemID)
	Window.Show()
	search:SetText(text or "")
	ns.SafeCall(BuildResults)
	UpdateRows()
	if itemID and ns.Data.Get(itemID, View()) then
		Window.Select(itemID)
	elseif #results == 1 then
		Window.Select(results[1].id)
	end
end

-- Shift-clicking an item while typing in the search box searches for it.
-- Forever sends item shift-clicks through ChatFrameUtil.InsertLink (older
-- clients through ChatEdit_InsertLink); all of them pass HandleModifiedItemClick.
-- Hook every one that exists - one click may reach several, so it's handled once.
local lastLink, lastTime
local function OnLinkClicked(link)
	if not (search and search:HasFocus() and type(link) == "string") then return end
	local id = tonumber(link:match("item:(%d+)"))
	if not id then return end
	local now = GetTime()
	if link == lastLink and now == lastTime then return end
	lastLink, lastTime = link, now
	local name = link:match("%[(.-)%]")
	if name then search:SetText(name) end
	Window.Select(id)
end

ns.On("PLAYER_LOGIN", function()
	if ChatFrameUtil and type(ChatFrameUtil.InsertLink) == "function" then
		hooksecurefunc(ChatFrameUtil, "InsertLink", function(link) ns.SafeCall(OnLinkClicked, link) end)
	end
	if type(ChatEdit_InsertLink) == "function" then
		hooksecurefunc("ChatEdit_InsertLink", function(link) ns.SafeCall(OnLinkClicked, link) end)
	end
	if type(HandleModifiedItemClick) == "function" then
		hooksecurefunc("HandleModifiedItemClick", function(link)
			if IsModifiedClick("CHATLINK") then ns.SafeCall(OnLinkClicked, link) end
		end)
	end
end)

-- Item names arrive from the server a moment after they're first asked for.
local namesPending = false
ns.On("GET_ITEM_INFO_RECEIVED", function()
	if namesPending or not (frame and frame:IsShown()) then return end
	namesPending = true
	C_Timer.After(0.5, function()
		namesPending = false
		Window.Refresh()
	end)
end)

-- For the key binding (Bindings.xml).
BINDING_HEADER_FIREAUCTION = "FireAuction"
BINDING_NAME_FIREAUCTION_TOGGLE = "Show/hide the price window"
function FireAuction_Toggle()
	Window.Toggle()
end
