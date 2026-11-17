-- The Profit tab of the price window (Window.lua): what your Quick buy
-- sessions have made, over time (Ledger.lua). On the left all items together,
-- then each item; on the right its profit, and a graph of it by day with a
-- projection from your average profit per day.
--
-- Profit: what sales brought in (after the cut), less what you paid and the
-- deposits lost, plus what you still hold at the market price (after the cut).
local _, ns = ...

local Profit = {}
ns.Profit = Profit

local LIST_W = 260
local ROWS, ROW_H = 17, 20
local GRAPH_H = 170
local TOTAL_COLOR = { 1, 0.82, 0 }
local CASH_COLOR = { 0.45, 0.65, 1 }
local GREEN, RED = "|cff40ff40", "|cffff5050"

local view, rows, countText, updated, detail, graph = nil, {}, nil, nil, {}, nil
local entries, offset, selected = {}, 0, nil -- selected: an itemID, or nil for all items
local lines, dots, gridLabels = {}, {}, {}
local nLines, nDots = 0, 0

local function Signed(copper)
	copper = math.floor(copper + 0.5)
	if copper == 0 then return ns.Money(0) end
	return (copper > 0 and (GREEN .. "+") or (RED .. "-")) .. ns.Money(math.abs(copper)) .. "|r"
end

local function Name(id)
	return (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) or ns.Data.Name(id, ns.Data.Get(id))
		or ("item " .. id)
end

local function Icon(id)
	return (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)) or 134400
end

---------------------------------------------------------------------------
-- The list
---------------------------------------------------------------------------
local function BuildEntries()
	wipe(entries)
	local items = ns.Ledger.Items()
	if #items == 0 then return end
	local all = ns.Ledger.Series()
	entries[1] = { all = true, name = "All items", total = all and all[#all].total or 0 }
	for _, e in ipairs(items) do
		entries[#entries + 1] = { id = e.id, name = Name(e.id), total = e.total }
	end
end

local function UpdateRows()
	offset = math.max(0, math.min(offset, #entries - ROWS))
	for i = 1, ROWS do
		local row, e = rows[i], entries[offset + i]
		if e then
			row.entry = e
			row.icon:SetTexture(e.all and "Interface\\Icons\\INV_Misc_Coin_01" or Icon(e.id))
			row.name:SetText(e.name)
			row.value:SetText(Signed(e.total))
			row.selected:SetShown((e.all and selected == nil) or (e.id ~= nil and e.id == selected))
			row:Show()
		else
			row.entry = nil
			row:Hide()
		end
	end
	countText:SetText(#entries > 0 and ("%d item%s"):format(#entries - 1, #entries == 2 and "" or "s") or "")
	local at = ns.db.ownedReadAt
	updated:SetText(at and ("Sales updated " .. ns.TimeAgo(at)) or "Sales not updated yet")
end

---------------------------------------------------------------------------
-- The graph
---------------------------------------------------------------------------
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

local function Dot(x, y, color)
	nDots = nDots + 1
	local d = dots[nDots]
	if not d then
		d = graph:CreateTexture(nil, "OVERLAY")
		d:SetSize(5, 5)
		dots[nDots] = d
	end
	d:SetColorTexture(color[1], color[2], color[3], 1)
	d:ClearAllPoints()
	d:SetPoint("CENTER", graph, "BOTTOMLEFT", x, y)
	d:Show()
end

local function ClearGraph()
	for i = 1, #lines do lines[i]:Hide() end
	for i = 1, #dots do dots[i]:Hide() end
	nLines, nDots = 0, 0
	graph.points, graph.projection, graph.hovered = nil, nil, nil
	graph.marker:Hide()
	for _, l in ipairs(gridLabels) do l:SetText("") end
end

local function Segment(color, a, thickness, x1, y1, x2, y2)
	local l = Line(color[1], color[2], color[3], a, thickness)
	l:SetStartPoint("BOTTOMLEFT", graph, x1, y1)
	l:SetEndPoint("BOTTOMLEFT", graph, x2, y2)
end

local function DrawGraph(series, perDay, ahead)
	ClearGraph()
	local first, today = series[1].day, series[#series].day
	local now = series[#series].total
	local last = perDay and (today + ahead) or today
	if last == first then first = first - 1 end
	local projected = perDay and (now + perDay * ahead)

	local low, high = 0, 0
	for _, p in ipairs(series) do
		low, high = math.min(low, p.total, p.cash), math.max(high, p.total, p.cash)
	end
	if projected then low, high = math.min(low, projected), math.max(high, projected) end
	if high == low then high = low + 10000 end
	local pad = (high - low) * 0.08
	high, low = high + pad, low - pad

	local w, h = graph:GetWidth(), graph:GetHeight()
	local function X(day) return (day - first) / (last - first) * w end
	local function Y(copper) return (copper - low) / (high - low) * h end

	-- Grid: three lines with amounts, and nothing made yet (0) when it's in range.
	for i = 0, 2 do
		local v = low + (high - low) * i / 2
		Segment({ 1, 1, 1 }, 0.08, 1, 0, Y(v), w, Y(v))
		gridLabels[i + 1]:SetText(Signed(v))
		gridLabels[i + 1]:ClearAllPoints()
		gridLabels[i + 1]:SetPoint("BOTTOMRIGHT", graph, "BOTTOMLEFT", -4, Y(v) - 5)
	end
	if low < 0 and high > 0 then Segment({ 1, 1, 1 }, 0.3, 1, 0, Y(0), w, Y(0)) end
	graph.firstDate:SetText(date("%b %d", ns.Data.DayTime(first)))
	graph.lastDate:SetText(perDay and ("+%d days"):format(ahead) or "Today")
	if perDay then
		Segment({ 1, 1, 1 }, 0.2, 1, X(today), 0, X(today), h)
		graph.todayLabel:ClearAllPoints()
		graph.todayLabel:SetPoint("TOP", graph, "BOTTOMLEFT", X(today), -4)
		graph.todayLabel:Show()
	else
		graph.todayLabel:Hide()
	end

	-- Cash (sales less purchases and deposits), under the profit.
	local points = {}
	for i, p in ipairs(series) do
		local x = X(p.day)
		points[i] = { x = x, y = Y(p.total), p = p }
		if i > 1 then
			local q = series[i - 1]
			Segment(CASH_COLOR, 0.6, 1.5, X(q.day), Y(q.cash), x, Y(p.cash))
			Segment(TOTAL_COLOR, 1, 2, points[i - 1].x, points[i - 1].y, x, points[i].y)
		end
	end
	if #series == 1 then
		Dot(points[1].x, Y(series[1].cash), CASH_COLOR)
		Dot(points[1].x, points[1].y, TOTAL_COLOR)
	end
	graph.points = points

	-- The projection: dashed, from today on.
	if perDay then
		local steps = 12
		for i = 0, steps - 1, 2 do
			local d1, d2 = today + ahead * i / steps, today + ahead * (i + 1) / steps
			Segment(TOTAL_COLOR, 0.7, 2, X(d1), Y(now + perDay * (d1 - today)), X(d2), Y(now + perDay * (d2 - today)))
		end
		graph.projection = {
			today = today, last = last, now = now, perDay = perDay, X = X, Y = Y,
			Day = function(x) return first + x / w * (last - first) end,
		}
	end
end

-- Hovering: the nearest day's profit; past today, the projection.
local function GraphHover(self)
	local points = self.points
	if not points then return end
	local x = GetCursorPosition() / self:GetEffectiveScale() - self:GetLeft()
	local best
	for _, p in ipairs(points) do
		if not best or math.abs(p.x - x) < math.abs(best.x - x) then best = p end
	end
	local pr = self.projection
	if pr then
		local day = math.min(pr.last, math.floor(pr.Day(x) + 0.5))
		if day > pr.today and math.abs(pr.X(day) - x) < math.abs(best.x - x) then
			if self.hovered == day then return end
			self.hovered = day
			local v = pr.now + pr.perDay * (day - pr.today)
			self.marker:ClearAllPoints()
			self.marker:SetPoint("CENTER", self, "BOTTOMLEFT", pr.X(day), pr.Y(v))
			self.marker:Show()
			GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
			GameTooltip:SetText(date("%A, %B %d", ns.Data.DayTime(day)), 1, 1, 1)
			GameTooltip:AddLine("Projected: " .. Signed(v), TOTAL_COLOR[1], TOTAL_COLOR[2], TOTAL_COLOR[3])
			GameTooltip:Show()
			return
		end
	end
	if best and best ~= self.hovered then
		self.hovered = best
		self.marker:ClearAllPoints()
		self.marker:SetPoint("CENTER", self, "BOTTOMLEFT", best.x, best.y)
		self.marker:Show()
		local p = best.p
		GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
		GameTooltip:SetText(date("%A, %B %d", ns.Data.DayTime(p.day)), 1, 1, 1)
		GameTooltip:AddLine("Profit: " .. Signed(p.total), TOTAL_COLOR[1], TOTAL_COLOR[2], TOTAL_COLOR[3])
		GameTooltip:AddLine("Cash: " .. Signed(p.cash), CASH_COLOR[1], CASH_COLOR[2], CASH_COLOR[3])
		if p.held > 0 then
			GameTooltip:AddLine(("Holding %d, worth %s"):format(p.held, ns.Money(math.floor(p.value + 0.5))), 0.8, 0.8, 0.8)
		end
		GameTooltip:Show()
	end
end

---------------------------------------------------------------------------
-- The selected item (or all)
---------------------------------------------------------------------------
local function UpdateDetail()
	local series = ns.Ledger.Series(selected)
	if not series then
		detail.icon:Hide()
		detail.name:SetText("")
		detail.text:SetText("No sessions yet.\n\nPress Start session on Quick buy at the auction house, and what you "
			.. "buy and sell of that item shows here.")
		graph:Hide()
		return
	end
	detail.icon:SetTexture(selected and Icon(selected) or "Interface\\Icons\\INV_Misc_Coin_01")
	detail.icon:Show()
	detail.name:SetText(selected and Name(selected) or "All items")

	local nowP = series[#series]
	local spent, income, lost, bought, sold = ns.Ledger.Totals(selected)
	local ahead = ns.Data.TrendDays()
	local perDay, days = ns.Ledger.PerDay(series, ahead)
	local info = {}
	info[#info + 1] = "Profit: " .. Signed(nowP.total)
	info[#info + 1] = ("Bought %d for %s   Sold %d for %s"):format(bought, ns.Money(spent), sold, ns.Money(income))
	if lost > 0 then info[#info + 1] = "Deposits lost: " .. ns.Money(lost) end
	if nowP.held > 0 then
		info[#info + 1] = ("Holding %d, worth %s at market price"):format(nowP.held, ns.Money(math.floor(nowP.value + 0.5)))
	end
	if perDay then
		info[#info + 1] = ("Per day: %s (last %d day%s)   In %d days: %s"):format(Signed(perDay), days, days == 1 and "" or "s",
			ahead, Signed(nowP.total + perDay * ahead))
	else
		info[#info + 1] = "|cff999999Per day: after your first full day.|r"
	end
	detail.text:SetText(table.concat(info, "\n"))
	graph:Show()
	DrawGraph(series, perDay, ahead)
end

function Profit.Refresh()
	if not (view and view:IsVisible()) then return end
	ns.SafeCall(BuildEntries)
	UpdateRows()
	ns.SafeCall(UpdateDetail)
end

local function Select(id)
	selected = id
	UpdateRows()
	ns.SafeCall(UpdateDetail)
end

---------------------------------------------------------------------------
-- Building it, inside the price window
---------------------------------------------------------------------------
function Profit.Build(parent)
	view = CreateFrame("Frame", nil, parent)
	view:SetAllPoints()
	view:Hide()

	local list = CreateFrame("Frame", nil, view)
	list:SetPoint("TOPLEFT", 12, -32)
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
			if self.entry then Select(self.entry.id) end
		end)
		row:SetScript("OnEnter", function(self)
			if not (self.entry and self.entry.id) then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetItemByID(self.entry.id)
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", function() GameTooltip:Hide() end)
		rows[i] = row
	end
	countText = view:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	countText:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 4, -6)

	-- When sales were last read, and how they're read.
	updated = view:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	updated:SetPoint("BOTTOMLEFT", 16, 18)
	local help = CreateFrame("Button", nil, view)
	help:SetSize(14, 14)
	help:SetPoint("LEFT", updated, "RIGHT", 4, 0)
	local helpIcon = help:CreateTexture(nil, "ARTWORK")
	helpIcon:SetAllPoints()
	helpIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
	help:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	help:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Sales", 1, 1, 1)
		GameTooltip:AddLine("Updated when you visit the auction house.", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	help:SetScript("OnLeave", function() GameTooltip:Hide() end)

	local divider = view:CreateTexture(nil, "ARTWORK")
	divider:SetColorTexture(1, 1, 1, 0.12)
	divider:SetWidth(1)
	divider:SetPoint("TOPLEFT", list, "TOPRIGHT", 8, 0)
	divider:SetPoint("BOTTOM", view, "BOTTOM", 0, 12)

	local right = CreateFrame("Frame", nil, view)
	right:SetPoint("TOPLEFT", list, "TOPRIGHT", 18, 0)
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
		function graph.CreateLine()
			local t = graph:CreateTexture(nil, "ARTWORK")
			t.SetThickness, t.SetStartPoint, t.SetEndPoint = function() end, function() end, function() end
			t:Hide()
			return t
		end
	end
	graph:SetScript("OnSizeChanged", function()
		if graph:IsVisible() then ns.SafeCall(UpdateDetail) end
	end)

	-- Kept current while it's open (sales come in any time).
	local elapsed = 0
	view:SetScript("OnUpdate", function(_, dt)
		elapsed = elapsed + dt
		if elapsed < 5 then return end
		elapsed = 0
		if not graph.hovered then Profit.Refresh() end
	end)
	view:SetScript("OnShow", function()
		elapsed = 0
		Profit.Refresh()
	end)
	return view
end
