-- The Profit tab of the price window (Window.lua): what your Quick buy
-- sessions have made, over time (Ledger.lua). On the left all items together,
-- then each item; on the right its profit, and a graph of it by day with a
-- projection from your average profit per day. With all items, your gold
-- (Gold.lua) too, to compare. Lines (each turned on or off by its key) show
-- the change since the start of the range; Daily shows each day's change as
-- bars, Daily % as a share of your gold the day before.
--
-- Profit: what sales brought in (after the cut), less what you paid and the
-- deposits lost, plus what you still hold at what it cost you - so it moves
-- only when something sells.
local _, ns = ...

local Profit = {}
ns.Profit = Profit

local LIST_W = 260
local ROWS, ROW_H = 17, 20
local GRAPH_H = 170
local TOTAL_COLOR = { 1, 0.82, 0 }
local CASH_COLOR = { 0.45, 0.65, 1 }
local GOLD_COLOR = { 0.4, 0.85, 0.45 }
local GREEN, RED = "|cff40ff40", "|cffff5050"

-- The lines, drawn in this order (the first on top).
local SERIES = {
	{ key = "total", label = "Profit", color = TOTAL_COLOR, tip = "What sold, less what it cost you" },
	{ key = "cash", label = "Cash", color = CASH_COLOR, tip = "Sales, less purchases and lost deposits" },
	{ key = "gold", label = "Gold", color = GOLD_COLOR, tip = "Gold on all your characters" },
}
local MODES = {
	{ "total", "Total", "Change since the start of the range" },
	{ "daily", "Daily", "Each day's change" },
	{ "pct", "Daily %", "Each day's change, as a share of your gold the day before" },
}
local RANGES = { { 7, "7d", "Last 7 days" }, { 30, "30d", "Last 30 days" }, { 0, "All", "Since your first session" } }
local ZERO = { total = 0, cash = 0, held = 0, value = 0 }

local view, rows, countText, updated, detail, graph = nil, {}, nil, nil, {}, nil
local entries, offset, selected = {}, 0, nil -- selected: an itemID, or nil for all items
local lines, dots, bars, gridLabels = {}, {}, {}, {}
local nLines, nDots, nBars = 0, 0, 0
local legend, modeButtons, rangeButtons = {}, {}, {}

-- How the graph is shown: mode, range (days, 0 for all), hide[key].
local function Options()
	local o = ns.db.profitGraph
	if type(o) ~= "table" then
		o = {}
		ns.db.profitGraph = o
	end
	o.mode = o.mode or "total"
	o.range = o.range or 0
	o.hide = o.hide or {}
	return o
end

-- Gold is for all items together.
local function Available(s)
	return s.key ~= "gold" or (selected == nil and ns.Gold.First() ~= nil)
end

local function Shown()
	local o, out = Options(), {}
	for _, s in ipairs(SERIES) do
		if Available(s) and not o.hide[s.key] then out[#out + 1] = s end
	end
	if #out == 0 then out[1] = SERIES[1] end
	return out
end

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

local function Bar(x, width, y1, y2, color)
	nBars = nBars + 1
	local t = bars[nBars]
	if not t then
		t = graph:CreateTexture(nil, "ARTWORK")
		bars[nBars] = t
	end
	t:SetColorTexture(color[1], color[2], color[3], 0.9)
	t:ClearAllPoints()
	t:SetPoint("BOTTOMLEFT", graph, "BOTTOMLEFT", x, math.min(y1, y2))
	t:SetSize(math.max(1, width), math.max(1, math.abs(y2 - y1)))
	t:Show()
end

local function ClearGraph()
	for i = 1, #lines do lines[i]:Hide() end
	for i = 1, #dots do dots[i]:Hide() end
	for i = 1, #bars do bars[i]:Hide() end
	nLines, nDots, nBars = 0, 0, 0
	graph.points, graph.projection, graph.hovered = nil, nil, nil
	graph.marker:Hide()
	graph.column:Hide()
	for _, l in ipairs(gridLabels) do l:SetText("") end
end

local function Segment(color, a, thickness, x1, y1, x2, y2)
	local l = Line(color[1], color[2], color[3], a, thickness)
	l:SetStartPoint("BOTTOMLEFT", graph, x1, y1)
	l:SetEndPoint("BOTTOMLEFT", graph, x2, y2)
end

local function Percent(v)
	local text = ("%+.1f%%"):format(v)
	if v > 0.05 then return GREEN .. text .. "|r" elseif v < -0.05 then return RED .. text .. "|r" end
	return text
end

-- The days to draw, from the day before the range (what it's measured from)
-- to today: { day, total, cash, gold, p } - p the ledger's day (profit and
-- cash so far, what's held), gold nil where not known.
local function Days(series)
	local o, today = Options(), ns.Data.Today()
	local pFirst = series[1].day
	local first = pFirst
	if o.range > 0 then
		first = today - o.range + 1
	elseif Available(SERIES[3]) and not o.hide.gold then
		first = math.min(first, ns.Gold.First())
	end
	local byDay = {}
	for _, p in ipairs(series) do byDay[p.day] = p end
	local gold = ns.Gold.Series(first - 1, today)
	local out = {}
	for day = first - 1, today do
		local p = byDay[day] or ZERO
		out[#out + 1] = { day = day, total = p.total, cash = p.cash, gold = gold[day], p = p }
	end
	return out
end

-- A day's change: copper, and as a share of the gold the day before (nil
-- when not known).
local function Change(days, i, key)
	local r, prev = days[i], days[i - 1]
	if not (prev and r[key] and prev[key]) then return nil end
	local d = r[key] - prev[key]
	return d, prev.gold and prev.gold > 0 and d / prev.gold * 100 or nil
end

local function DrawGraph(days, perDay, ahead)
	ClearGraph()
	local o, shown = Options(), Shown()
	local daily, pct = o.mode ~= "total", o.mode == "pct"
	local n = #days

	-- What's plotted: each line from 0 at the start, or each day's change.
	local vals, base, baseAt = {}, {}, {}
	for _, s in ipairs(shown) do
		local v = {}
		vals[s.key] = v
		for i, r in ipairs(days) do
			if daily then
				local d, share = Change(days, i, s.key)
				-- (Daily %: nothing on days without your gold the day before.)
				if pct then v[i] = share else v[i] = d end
			elseif r[s.key] then
				if not base[s.key] then base[s.key], baseAt[s.key] = r[s.key], i end
				v[i] = r[s.key] - base[s.key]
			end
		end
	end
	local projecting = not daily and perDay and vals.total
	local now = projecting and vals.total[n]

	local low, high = 0, 0
	for _, v in pairs(vals) do
		for i = 1, n do
			if v[i] then low, high = math.min(low, v[i]), math.max(high, v[i]) end
		end
	end
	if projecting then
		local projected = now + perDay * ahead
		low, high = math.min(low, projected), math.max(high, projected)
	end
	if high == low then high = low + (pct and 1 or 10000) end
	local pad = (high - low) * 0.08
	high, low = high + pad, low - pad

	local w, h = graph:GetWidth(), graph:GetHeight()
	-- Lines: day i (and the projection's days past the last) across; bars: a
	-- slot for each day after the first.
	local span = math.max(1, (n - 1) + (projecting and ahead or 0))
	local slot = w / math.max(1, n - 1)
	local function X(i) return daily and (i - 1.5) * slot or (i - 1) / span * w end
	local function Y(v) return (v - low) / (high - low) * h end

	-- Grid: three lines with amounts, and 0 when it's in range.
	for i = 0, 2 do
		local v = low + (high - low) * i / 2
		Segment({ 1, 1, 1 }, 0.08, 1, 0, Y(v), w, Y(v))
		gridLabels[i + 1]:SetText(pct and Percent(v) or Signed(v))
		gridLabels[i + 1]:ClearAllPoints()
		gridLabels[i + 1]:SetPoint("BOTTOMRIGHT", graph, "BOTTOMLEFT", -4, Y(v) - 5)
	end
	if low < 0 and high > 0 then Segment({ 1, 1, 1 }, 0.3, 1, 0, Y(0), w, Y(0)) end
	graph.firstDate:SetText(date("%b %d", ns.Data.DayTime(days[daily and 2 or 1].day)))
	graph.lastDate:SetText(projecting and ("+%d days"):format(ahead) or "Today")
	if projecting then
		Segment({ 1, 1, 1 }, 0.2, 1, X(n), 0, X(n), h)
		graph.todayLabel:ClearAllPoints()
		graph.todayLabel:SetPoint("TOP", graph, "BOTTOMLEFT", X(n), -4)
		graph.todayLabel:Show()
	else
		graph.todayLabel:Hide()
	end

	if daily then
		local width = slot * 0.8 / #shown
		local gap = width > 3 and 1 or 0
		for i = 2, n do
			local left = X(i) - slot * 0.4
			for j, s in ipairs(shown) do
				local v = vals[s.key][i]
				if v and v ~= 0 then Bar(left + (j - 1) * width, width - gap, Y(0), Y(v), s.color) end
			end
		end
	else
		for j = #shown, 1, -1 do
			local s, v = shown[j], vals[shown[j].key]
			local main = j == 1
			local prev
			for i = 1, n do
				if v[i] then
					if prev then
						Segment(s.color, main and 1 or 0.7, main and 2 or 1.5, X(prev), Y(v[prev]), X(i), Y(v[i]))
					elseif i == n then
						Dot(X(i), Y(v[i]), s.color)
					end
					prev = i
				end
			end
		end
	end

	graph.points = { days = days, vals = vals, baseAt = baseAt, shown = shown, daily = daily, X = X, Y = Y, slot = slot, n = n }

	-- The projection: dashed, from today on.
	if projecting then
		local steps = 12
		for i = 0, steps - 1, 2 do
			local d1, d2 = ahead * i / steps, ahead * (i + 1) / steps
			Segment(TOTAL_COLOR, 0.7, 2, X(n + d1), Y(now + perDay * d1), X(n + d2), Y(now + perDay * d2))
		end
		graph.projection = { today = days[n].day, now = now, perDay = perDay, ahead = ahead }
	end
end

-- Hovering: the nearest day; past today, the projection.
local function GraphHover(self)
	local g = self.points
	if not g then return end
	local x = GetCursorPosition() / self:GetEffectiveScale() - self:GetLeft()
	local n, days = g.n, g.days
	local i = g.daily and math.floor(x / g.slot + 1.5 + 0.5) or math.floor(x / self:GetWidth() * ((n - 1)
		+ (self.projection and self.projection.ahead or 0)) + 1.5)
	i = math.max(g.daily and 2 or 1, i)
	local pr = self.projection
	if pr and i > n then
		local ahead = math.min(pr.ahead, i - n)
		if self.hovered == -ahead then return end
		self.hovered = -ahead
		local v = pr.now + pr.perDay * ahead
		self.marker:ClearAllPoints()
		self.marker:SetPoint("CENTER", self, "BOTTOMLEFT", g.X(n + ahead), g.Y(v))
		self.marker:Show()
		GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
		GameTooltip:SetText(date("%A, %B %d", ns.Data.DayTime(pr.today + ahead)), 1, 1, 1)
		GameTooltip:AddLine("Projected: " .. Signed(v), TOTAL_COLOR[1], TOTAL_COLOR[2], TOTAL_COLOR[3])
		GameTooltip:Show()
		return
	end
	i = math.min(n, i)
	if self.hovered == i then return end
	self.hovered = i
	local r = days[i]
	self.marker:Hide()
	self.column:Hide()
	if g.daily then
		self.column:ClearAllPoints()
		self.column:SetPoint("BOTTOM", self, "BOTTOMLEFT", g.X(i), 0)
		self.column:SetSize(g.slot, self:GetHeight())
		self.column:Show()
	else
		local v = g.vals[g.shown[1].key][i]
		if v then
			self.marker:ClearAllPoints()
			self.marker:SetPoint("CENTER", self, "BOTTOMLEFT", g.X(i), g.Y(v))
			self.marker:Show()
		end
	end
	GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
	GameTooltip:SetText(date("%A, %B %d", ns.Data.DayTime(r.day)), 1, 1, 1)
	if not g.daily then
		GameTooltip:AddLine("Since " .. date("%b %d", ns.Data.DayTime(days[1].day)), 0.6, 0.6, 0.6)
	end
	for _, s in ipairs(g.shown) do
		local c, text = s.color, nil
		if g.daily then
			local d, share = Change(days, i, s.key)
			if d then text = Signed(d) .. (share and ("  " .. Percent(share)) or "") end
		else
			local v = g.vals[s.key][i]
			if v then
				text = Signed(v)
				if s.key == "gold" then
					-- Kept from later than the range starts: since then.
					local at = g.baseAt.gold
					if at and at > 1 and days[at + 1] then
						text = text .. " since " .. date("%b %d", ns.Data.DayTime(days[at + 1].day))
					end
					text = text .. "  |cffcccccc(" .. ns.Money(r.gold) .. ")|r"
				end
			end
		end
		if text then GameTooltip:AddLine(s.label .. ": " .. text, c[1], c[2], c[3]) end
	end
	if r.p.held > 0 then
		GameTooltip:AddLine(("Holding %d, cost %s"):format(r.p.held, ns.Money(math.floor(r.p.value + 0.5))), 0.8, 0.8, 0.8)
	end
	GameTooltip:Show()
end

---------------------------------------------------------------------------
-- What's shown: the keys (click one to show or hide its line), how, how long
---------------------------------------------------------------------------
local function UpdateControls()
	local o, x = Options(), 0
	for _, s in ipairs(SERIES) do
		local b = legend[s.key]
		if Available(s) then
			local on = not o.hide[s.key]
			b.swatch:SetAlpha(on and 1 or 0.25)
			b.text:SetTextColor(on and 1 or 0.5, on and 1 or 0.5, on and 1 or 0.5)
			b:ClearAllPoints()
			b:SetPoint("LEFT", x, 0)
			x = x + b:GetWidth() + 2
			b:Show()
		else
			b:Hide()
		end
	end
	for _, b in ipairs(modeButtons) do b:SetOn(o.mode == b.value) end
	for _, b in ipairs(rangeButtons) do b:SetOn(o.range == b.value) end
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
		info[#info + 1] = ("Holding %d, cost %s"):format(nowP.held, ns.Money(math.floor(nowP.value + 0.5)))
	end
	if perDay then
		info[#info + 1] = ("Per day: %s (last %d day%s)   In %d days: %s"):format(Signed(perDay), days, days == 1 and "" or "s",
			ahead, Signed(nowP.total + perDay * ahead))
	else
		info[#info + 1] = "|cff999999Per day: after your first full day.|r"
	end
	detail.text:SetText(table.concat(info, "\n"))
	graph:Show()
	UpdateControls()
	DrawGraph(Days(series), perDay, ahead)
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
	graph.column = graph:CreateTexture(nil, "BORDER")
	graph.column:SetColorTexture(1, 1, 1, 0.1)
	graph.column:Hide()

	-- Above it: the keys on the left; how, and how long, on the right.
	local controls = CreateFrame("Frame", nil, graph)
	controls:SetPoint("BOTTOMLEFT", graph, "TOPLEFT", -64, 6)
	controls:SetPoint("BOTTOMRIGHT", graph, "TOPRIGHT", 0, 6)
	controls:SetHeight(16)
	local function Redraw()
		graph.hovered = nil
		ns.SafeCall(UpdateDetail)
	end
	for _, s in ipairs(SERIES) do
		local b = CreateFrame("Button", nil, controls)
		b:SetHeight(16)
		b.swatch = b:CreateTexture(nil, "ARTWORK")
		b.swatch:SetSize(8, 8)
		b.swatch:SetPoint("LEFT", 3, 0)
		b.swatch:SetColorTexture(s.color[1], s.color[2], s.color[3], 1)
		b.text = b:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		b.text:SetPoint("LEFT", b.swatch, "RIGHT", 4, 0)
		b.text:SetText(s.label)
		b:SetWidth(b.text:GetStringWidth() + 20)
		b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
		b:SetScript("OnClick", function()
			local o = Options()
			-- Not the last one showing.
			if not o.hide[s.key] and #Shown() == 1 then return end
			o.hide[s.key] = not o.hide[s.key] or nil
			Redraw()
		end)
		b:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:SetText(s.tip, 1, 1, 1, 1, true)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		ns.ClickSound(b)
		legend[s.key] = b
	end
	-- A row of choices, right to left from `right` (gap: space before it).
	local function Choice(list, field, store, right, gap)
		for k = #list, 1, -1 do
			local value, label = list[k][1], list[k][2]
			local b = CreateFrame("Button", nil, controls)
			b:SetHeight(16)
			b.value = value
			b.bg = b:CreateTexture(nil, "BACKGROUND")
			b.bg:SetAllPoints()
			b.text = b:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
			b.text:SetPoint("CENTER")
			b.text:SetText(label)
			b:SetWidth(b.text:GetStringWidth() + 10)
			b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
			function b:SetOn(on)
				self.bg:SetColorTexture(1, 0.82, 0, on and 0.3 or 0.08)
				self.text:SetTextColor(on and 1 or 0.7, on and 0.82 or 0.7, on and 0 or 0.7)
			end
			b:SetScript("OnClick", function()
				Options()[field] = value
				Redraw()
			end)
			if list[k][3] then
				b:SetScript("OnEnter", function(self)
					GameTooltip:SetOwner(self, "ANCHOR_TOP")
					GameTooltip:SetText(list[k][3], 1, 1, 1, 1, true)
					GameTooltip:Show()
				end)
				b:SetScript("OnLeave", function() GameTooltip:Hide() end)
			end
			ns.ClickSound(b)
			if right == controls then
				b:SetPoint("RIGHT", controls, "RIGHT", 0, 0)
			else
				b:SetPoint("RIGHT", right, "LEFT", k == #list and -(gap or 1) or -1, 0)
			end
			right = b
			store[#store + 1] = b
		end
		return right
	end
	Choice(MODES, "mode", modeButtons, Choice(RANGES, "range", rangeButtons, controls), 8)
	graph:EnableMouse(true)
	graph:SetScript("OnEnter", function(self) self:SetScript("OnUpdate", GraphHover) end)
	graph:SetScript("OnLeave", function(self)
		self:SetScript("OnUpdate", nil)
		self.hovered = nil
		self.marker:Hide()
		self.column:Hide()
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
