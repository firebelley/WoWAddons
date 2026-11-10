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
local detail = {}
local results, offset, selected = {}, 0, nil

local SORTS = {
	{ key = "name", label = "Name" },
	{ key = "price", label = "Price" },
	{ key = "rising", label = "Rising" },
	{ key = "falling", label = "Falling" },
}
local sortIndex = 1

local function ItemIcon(id)
	return (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id))
		or (GetItemIcon and GetItemIcon(id)) or 134400 -- question mark
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
	local realm = ns.Realm()
	if not realm then return end
	local query = search and strtrim(search:GetText() or ""):lower() or ""
	local sort = SORTS[sortIndex].key
	for id, rec in pairs(realm.items) do
		local name = ns.Data.Name(id, rec)
		if not name and C_Item and C_Item.RequestLoadItemDataByID then
			pcall(C_Item.RequestLoadItemDataByID, id)
		end
		if query == "" or (name and name:lower():find(query, 1, true)) then
			local entry = { id = id, rec = rec, name = name or ("item " .. id) }
			if sort == "rising" or sort == "falling" then entry.pct = ns.Data.Trend(rec) end
			if (sort ~= "rising" and sort ~= "falling") or entry.pct then
				results[#results + 1] = entry
			end
		end
	end
	table.sort(results, function(a, b)
		if sort == "price" then
			if a.rec.p ~= b.rec.p then return (a.rec.p or 0) > (b.rec.p or 0) end
		elseif sort == "rising" then
			if a.pct ~= b.pct then return a.pct > b.pct end
		elseif sort == "falling" then
			if a.pct ~= b.pct then return a.pct < b.pct end
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
		local realm = ns.Realm()
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
	local trendDays = ns.Data.TrendDays()
	local _, projected, slope, now = ns.Data.Trend(rec)
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
-- Details of the selected item
---------------------------------------------------------------------------
local function UpdateDetail()
	local rec = selected and ns.Data.Get(selected)
	if not rec then
		detail.icon:Hide()
		detail.name:SetText("")
		detail.text:SetText(next(results) and "Pick an item on the left." or "")
		graph:Hide()
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
	local days = ns.Data.TrendDays()
	local pct, projected = ns.Data.Trend(rec)
	if pct then
		info[#info + 1] = ("Last %d days: %s   Projected in %d days: %s"):format(days, ns.Percent(pct), days, ns.Money(projected))
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
	graph:Show()
	DrawGraph(rec)
end

function Window.Select(itemID)
	selected = itemID
	UpdateRows()
	UpdateDetail()
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
	title:SetText("FireAuction - Prices")

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
		row:SetScript("OnClick", function(self)
			if self.entry then Window.Select(self.entry.id) end
		end)
		row:SetScript("OnEnter", function(self)
			if not self.entry then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetItemByID(self.entry.id)
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
	detail.name = right:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	detail.name:SetPoint("LEFT", detail.icon, "RIGHT", 8, 0)
	detail.name:SetPoint("RIGHT", 0, 0)
	detail.name:SetJustifyH("LEFT")
	detail.name:SetWordWrap(false)
	detail.text = right:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	detail.text:SetPoint("TOPLEFT", detail.icon, "BOTTOMLEFT", 0, -10)
	detail.text:SetPoint("RIGHT", 0, 0)
	detail.text:SetJustifyH("LEFT")
	detail.text:SetSpacing(4)

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
		ns.SafeCall(BuildResults)
		UpdateRows()
		ns.SafeCall(UpdateDetail)
	end)
end

function Window.Refresh()
	if frame and frame:IsShown() then
		ns.SafeCall(BuildResults)
		UpdateRows()
		ns.SafeCall(UpdateDetail)
	end
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
	if itemID and ns.Data.Get(itemID) then
		Window.Select(itemID)
	elseif #results == 1 then
		Window.Select(results[1].id)
	end
end

-- Shift-clicking an item while typing in the search box searches for it.
if ChatEdit_InsertLink then
	hooksecurefunc("ChatEdit_InsertLink", function(link)
		if not (search and search:HasFocus() and type(link) == "string") then return end
		local name = link:match("%[(.-)%]")
		local id = tonumber(link:match("item:(%d+)"))
		if name then search:SetText(name) end
		if id then Window.Select(id) end
	end)
end

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
