-- Listing prices: under the purchase tracker (its More button), a price to
-- list at for each of the cheapest listings - 1c under it - with how many
-- are ahead of you there, how long until all of yours sell, the chance they
-- do within 2, 8 and 24 hours, and the profit if they do.
--
-- Commodities sell cheapest first: yours sell once everything under them has.
-- So the speed that matters is how fast the listings under a price go, less
-- the new ones listed under it - measured between your refreshes (Quick buy
-- keeps the cheapest each time, QuickBuy.lua): how many there were under the
-- price, and how many a minute or more later, less what you bought. Only
-- while some were under it: with none, buyers weren't seen. Cancelled ones
-- look bought, and relisted ones new, so churn evens out.
local _, ns = ...

local HIST_GAP = 60          -- seconds between kept snapshots
local HIST_KEEP = 3 * 86400  -- how long they're kept
local PAIR_MAX = 86400       -- snapshots further apart than this aren't compared
local MIN_SEEN = 600         -- seconds of comparisons before a speed is trusted
local PRIOR_WEIGHT = 3600    -- the scan estimate counts as this much watching
local HORIZONS = { 2, 8, 24 } -- the chance columns, in hours
local SPREAD = 1             -- how unsure "sells in" is (log scale)
local LEVELS = 8             -- prices listed
local LIVE_ROWS = 60         -- listings read from the auction house
local TREND_SPAN = 6 * 3600  -- the trend: over this long
local FLOOR_UNITS = 20       -- the trend follows the price this many in
local RECALC = 2             -- seconds between working it out again

local WIDTH = 430
local PAD = 14
local TOP = -66
local ROW = 15
local C_PROFIT, C_CHANCE, C_SELLS, C_AHEAD = 80, 34, 52, 44
local GREY = "|cff999999"
local CUSTOM = "|cff66bbff" -- your own resale price, as in the tracker

ns.Ladder = {}
local Ladder = ns.Ladder

---------------------------------------------------------------------------
-- History: the cheapest listings (not yours) at most once a minute per item,
-- for a few days: ns.db.market.hist[itemID] = { { at, mine, rows }, ... }
-- (rows: price, quantity, ...; mine: how many of it you'd bought in all).
---------------------------------------------------------------------------
local function Market()
	ns.db.market = type(ns.db.market) == "table" and ns.db.market or { snaps = {}, checks = {} }
	return ns.db.market
end

local function Add(hist, id, at, mine, rows)
	local list = hist[id] or {}
	hist[id] = list
	local last = list[#list]
	if last and at - last.at < HIST_GAP then return end
	list[#list + 1] = { at = at, mine = mine, rows = rows }
	local cutoff = at - HIST_KEEP
	while list[1] and list[1].at < cutoff do table.remove(list, 1) end
end

local function History(id)
	local m = Market()
	if not m.hist then
		-- First time: from Quick buy's own log.
		m.hist = {}
		for _, s in ipairs(m.snaps or {}) do
			if s.id and s.rows and #s.rows > 0 then Add(m.hist, s.id, s.at, s.mine, s.rows) end
		end
	end
	return m.hist[id] or {}
end

-- Quick buy's refresh came in (QuickBuy.lua's Snapshot).
function Ladder.Snapped(id, at, mine, rows)
	History(id)
	Add(Market().hist, id, at, mine, rows)
end

---------------------------------------------------------------------------
-- The model
---------------------------------------------------------------------------
-- How many in rows are priced at or under p (and over floor).
local function Under(rows, p, floor)
	local n = 0
	for i = 1, #rows, 2 do
		local price = rows[i]
		if price > p then break end
		if not floor or price > floor then n = n + rows[i + 1] end
	end
	return n
end

-- The dearest price rows go to (past it, they were cut off).
local function Cap(rows) return rows[#rows - 1] or 0 end

-- Units a second leaving from under p, and seconds watched.
local function Speed(list, p)
	local seen, drained = 0, 0
	for i = 2, #list do
		local a, b = list[i - 1], list[i]
		local gap = b.at - a.at
		if gap > 0 and gap <= PAIR_MAX and p <= Cap(a.rows) and p <= Cap(b.rows) then
			local before = Under(a.rows, p)
			if before > 0 then
				local mine = (a.mine and b.mine) and math.min(before, math.max(0, b.mine - a.mine)) or 0
				seen, drained = seen + gap, drained + before - Under(b.rows, p) - mine
			end
		end
	end
	return drained, seen
end

-- About how many sell a second, from the scans (Volume.lua); nil without.
local function Prior(id)
	local rec = ns.Volume and ns.Volume.PerDay and ns.Data.Get(id)
	if not rec then return nil end
	local perDay = ns.Volume.PerDay(rec, ns.house or "faction")
	return perDay and perDay / 86400 or nil
end

-- The cheapest listings now (not yours): the auction house's if loaded,
-- else the last kept, and how old (seconds; 0 for live).
local function Book(id, list)
	local AH = C_AuctionHouse
	local n = AH and AH.GetNumCommoditySearchResults and AH.GetNumCommoditySearchResults(id) or 0
	if n > 0 then
		local rows = {}
		for i = 1, math.min(n, LIVE_ROWS) do
			local r = AH.GetCommoditySearchResultInfo(id, i)
			if not r then break end
			local open = r.quantity - (r.numOwnerItems or 0)
			if open > 0 then
				rows[#rows + 1] = r.unitPrice
				rows[#rows + 1] = open
			end
		end
		if #rows > 0 then return rows, 0 end
	end
	local last = list[#list]
	if last then return last.rows, time() - last.at end
	return nil
end

-- Copper an hour the price FLOOR_UNITS in has moved lately; nil if not
-- watched long enough.
local function Trend(list)
	local now = time()
	local xs, ys = {}, {}
	for _, s in ipairs(list) do
		if s.at >= now - TREND_SPAN then
			local n, price = 0, nil
			for i = 1, #s.rows, 2 do
				n, price = n + s.rows[i + 1], s.rows[i]
				if n >= FLOOR_UNITS then break end
			end
			if price then xs[#xs + 1], ys[#ys + 1] = (s.at - now) / 3600, price end
		end
	end
	if #xs < 5 or xs[#xs] - xs[1] < 0.5 then return nil end
	local mx, my = 0, 0
	for i = 1, #xs do mx, my = mx + xs[i], my + ys[i] end
	mx, my = mx / #xs, my / #xs
	local sxy, sxx = 0, 0
	for i = 1, #xs do
		sxy = sxy + (xs[i] - mx) * (ys[i] - my)
		sxx = sxx + (xs[i] - mx) ^ 2
	end
	return sxx > 0 and sxy / sxx or nil
end

-- The chance something expected in `hours` happens within `within` hours.
local function Chance(hours, within)
	if hours <= 0 then return 0.95 end
	if hours == math.huge then return 0.05 end
	local x = math.log(within / hours) / SPREAD
	return math.max(0.05, math.min(0.95, 1 / (1 + math.exp(-1.702 * x))))
end

local cache = {}

-- The ladder for id: { rows = { { price, ahead, hours (math.huge: not
-- going), perHour }, ... }, trend, seen (seconds watched), age } or nil
-- without listings. count: how many you'd list; floor: in Quick buy, your
-- Up to (what's at or under it you'd buy, so it isn't ahead); custom: your
-- own resale price, a row of its own (custom = true) where it sorts.
function Ladder.Work(id, count, floor, custom)
	local list = History(id)
	local c = cache[id]
	if not (c and c.n == #list and c.last == (list[#list] and list[#list].at)) then
		c = { n = #list, last = list[#list] and list[#list].at, speed = {}, trend = Trend(list) }
		cache[id] = c
	end
	local book, age = Book(id, list)
	if not book then return nil end
	local prior = Prior(id)
	local out = { rows = {}, trend = c.trend, age = age, seen = 0 }
	local function Row(p)
		local sp = c.speed[p]
		if not sp then
			local drained, seen = Speed(list, p)
			sp = { drained, seen }
			c.speed[p] = sp
		end
		local drained, seen = sp[1], sp[2]
		out.seen = math.max(out.seen, seen)
		local rate -- units a second
		if prior then
			rate = (drained + prior * PRIOR_WEIGHT) / (seen + PRIOR_WEIGHT)
		elseif seen >= MIN_SEEN then
			rate = drained / seen
		end
		local ahead = Under(book, p, floor)
		local hours
		if rate then hours = rate > 0 and (ahead + math.max(1, count)) / rate / 3600 or math.huge end
		return { price = p, ahead = ahead, hours = hours, perHour = rate and rate * 3600 }
	end
	local last
	for i = 1, #book, 2 do
		local p = book[i] - 1
		if p > 0 and p ~= last and (not floor or p > floor) then
			last = p
			local r = Row(p)
			r.custom = p == custom or nil
			out.rows[#out.rows + 1] = r
			if #out.rows >= LEVELS then break end
		end
	end
	if custom and custom > 0 then
		local at = #out.rows + 1
		for i, r in ipairs(out.rows) do
			if r.price == custom then at = nil break end
			if r.price > custom then at = i break end
		end
		if at then
			local r = Row(custom)
			r.custom = true
			table.insert(out.rows, at, r)
		end
	end
	-- Dearer can't sell sooner: whatever sells before the cheaper price does
	-- before this one too.
	local slowest
	for _, r in ipairs(out.rows) do
		if r.hours then
			if slowest and r.hours < slowest then r.hours = slowest end
			slowest = r.hours
		end
	end
	return out
end

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------
local frame, summary, summaryHover, rows, worked, workedAt, workedKey

local function Duration(hours)
	if not hours then return GREY .. "?|r" end
	if hours == math.huge then return GREY .. "never|r" end
	local m = hours * 60
	if m < 1 then return "now" end
	if m < 60 then return ("~%dm"):format(math.floor(m + 0.5)) end
	if hours < 48 then return ("~%dh"):format(math.floor(hours + 0.5)) end
	return ("~%dd"):format(math.floor(hours / 24 + 0.5))
end

local function Signed(copper)
	copper = math.floor(copper + 0.5)
	return (copper > 0 and "+" or copper < 0 and "-" or "") .. ns.Money(math.abs(copper))
end

local function ShowTip(owner, tip)
	if not tip then return end
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	for i, line in ipairs(tip) do
		if i == 1 then GameTooltip:SetText(line, 1, 1, 1) else GameTooltip:AddLine(line, nil, nil, nil, true) end
	end
	GameTooltip:Show()
end

-- Columns, right to left after the price: key, width.
local COLUMNS = { { "profit", C_PROFIT } }
for i = #HORIZONS, 1, -1 do COLUMNS[#COLUMNS + 1] = { "h" .. i, C_CHANCE } end
COLUMNS[#COLUMNS + 1] = { "sells", C_SELLS }
COLUMNS[#COLUMNS + 1] = { "ahead", C_AHEAD }

-- A cell: its text, hovered for its own tip (or the row's).
local function Cell(row, justify)
	local cell = CreateFrame("Frame", nil, row)
	cell:SetHeight(ROW)
	cell.text = cell:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	cell.text:SetAllPoints()
	cell.text:SetJustifyH(justify)
	cell:SetScript("OnEnter", function(self) ShowTip(self, self.tip or row.tip) end)
	cell:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return cell
end

local function Row(i)
	local row = rows[i]
	if row then return row end
	row = CreateFrame("Frame", nil, frame)
	row:SetHeight(ROW)
	row.cells = {}
	local x, last = 0, nil
	for _, col in ipairs(COLUMNS) do
		local cell = Cell(row, "RIGHT")
		cell:SetPoint("RIGHT", -x, 0)
		cell:SetWidth(col[2])
		x = x + col[2] + 6
		row.cells[col[1]], last = cell, cell
	end
	local price = Cell(row, "LEFT")
	price:SetPoint("LEFT")
	price:SetPoint("RIGHT", last, "LEFT", -6, 0)
	row.cells.price = price
	rows[i] = row
	return row
end

-- values/tips: by column key; tip: the whole row's.
local function Line(i, y, font, values, tip, tips)
	local row = Row(i)
	row:ClearAllPoints()
	row:SetPoint("TOPLEFT", PAD, y)
	row:SetPoint("TOPRIGHT", -PAD, y)
	row.tip = tip
	for key, cell in pairs(row.cells) do
		cell.text:SetFontObject(font)
		cell.text:SetText(values[key] or "")
		cell.tip = tips and tips[key]
		if cell.EnableMouse then cell:EnableMouse(cell.tip ~= nil or tip ~= nil) end
	end
	row:Show()
end

local function Create(anchor)
	frame = ns.SideWindow("FireAuctionLadder", WIDTH, TOP + 6, "ladderPoint", function(f)
		f:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -4)
	end)
	ns.SideWindowTitle(frame, "Listing prices")
	summary = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	summary:SetPoint("TOPLEFT", 64, -32)
	summary:SetJustifyH("LEFT")
	summaryHover = CreateFrame("Frame", nil, frame)
	summaryHover:SetAllPoints(summary)
	summaryHover:EnableMouse(true)
	summaryHover:SetScript("OnEnter", function(self)
		ShowTip(self, { "Listing prices", "Trend: price change per hour, last 6 hours.",
			"Data: hours of your refreshes this is based on." })
	end)
	summaryHover:SetScript("OnLeave", function() GameTooltip:Hide() end)
	rows = {}
end

function Ladder.Hide()
	if frame then frame:Hide() end
end

-- Show the ladder for id beside the tracker (anchor). info: { left (how many
-- you'd list), short (still to make back, after what's up), floor (your Up
-- to, in Quick buy) }.
function Ladder.Show(anchor, id, info)
	if not frame then Create(anchor) end
	local texture = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)
	ns.SideWindowIcon(frame, texture or "Interface\\Icons\\INV_Misc_QuestionMark")
	local count = info.left or 0
	local custom = ns.QuickBuy and ns.QuickBuy.Target and ns.QuickBuy.Target(id)
	local key = id .. ":" .. count .. ":" .. tostring(info.floor) .. ":" .. tostring(custom)
	if key ~= workedKey or not workedAt or GetTime() - workedAt >= RECALC then
		worked, workedAt, workedKey = Ladder.Work(id, count, info.floor, custom), GetTime(), key
	end
	local w = worked
	local cut = 1 - ns.Cut()
	local n = math.max(1, count)

	local bits = {}
	if w and w.trend then
		bits[#bits + 1] = math.abs(w.trend) < 1 and "Trend flat" or ("Trend %s/h"):format(Signed(w.trend))
	end
	if w and w.seen > 0 then
		bits[#bits + 1] = GREY .. ("Data %s|r"):format((Duration(w.seen / 3600):gsub("~", "")))
	end
	summary:SetText(table.concat(bits, "   "))

	-- The header: each column's name, and what it means.
	local values = { price = "Price", ahead = "Ahead", sells = "Sells in", profit = ("Profit (%d)"):format(n) }
	local tips = {
		price = { "Price", "1c under a listing." },
		ahead = { "Ahead", "Listed cheaper. They sell first." },
		sells = { "Sells in", ("Time until all %d of yours sell."):format(n) },
		profit = { "Profit", ("If all %d sell, after the %d%% cut."):format(n, math.floor(ns.Cut() * 100 + 0.5)) },
	}
	for i, h in ipairs(HORIZONS) do
		values["h" .. i] = h .. "h"
		tips["h" .. i] = { h .. "h", ("Chance all %d sell within %d hours."):format(n, h) }
	end
	local y = TOP
	local i = 1
	Line(i, y, "GameFontDisableSmall", values, nil, tips)
	y = y - ROW - 2
	if not w then
		i = i + 1
		Line(i, y, "GameFontDisableSmall", { price = "Refresh the listings to see" })
		y = y - ROW
	else
		if w.age > 120 then
			i = i + 1
			Line(i, y, "GameFontDisableSmall", { price = ("Listings from %s ago"):format((Duration(w.age / 3600):gsub("~", ""))) })
			y = y - ROW
		end
		for _, r in ipairs(w.rows) do
			i = i + 1
			local v = {
				price = r.custom and (CUSTOM .. ns.Money(r.price) .. "|r") or ns.Money(r.price),
				ahead = tostring(r.ahead),
				sells = Duration(r.hours),
				profit = count > 0 and Signed(math.floor(r.price * cut * count) - (info.short or 0)) or nil,
			}
			for k, h in ipairs(HORIZONS) do
				v["h" .. k] = r.hours and ("%d%%"):format(math.floor(Chance(r.hours, h) * 20 + 0.5) * 5) or nil
			end
			local speed = not r.perHour and "Not enough data yet."
				or r.perHour > 0 and ("~%d sell an hour."):format(math.floor(r.perHour + 0.5))
				or "More listed than sold."
			Line(i, y, "GameFontHighlightSmall", v, { r.custom and ("Your resale price: " .. ns.Money(r.price)) or ns.Money(r.price),
				("%d listed cheaper."):format(r.ahead), speed })
			y = y - ROW
		end
	end
	for k = i + 1, #rows do rows[k]:Hide() end
	frame:SetHeight(-y + PAD)
	frame:Show()
end
