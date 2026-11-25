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
local HIST_KEEP = 30 * 86400 -- how long they're kept
local PAIR_MAX = 3600        -- snapshots further apart than this aren't compared
local MIN_SEEN = 600         -- seconds of comparisons before a speed is trusted
local NEVER_SEEN = 6 * 3600  -- ...before "more listed than sold" means never
local PRIOR_WEIGHT = 3600    -- the scan estimate counts as this much watching
local HORIZONS = { 2, 8, 24 } -- the chance columns, in hours
local SPREAD = 1             -- how unsure "sells in" is (log scale)
local LEVELS = 8             -- prices listed
local LIVE_ROWS = 60         -- listings read from the auction house
local TREND_SPAN = 6 * 3600  -- the trend: over this long
local FLOOR_UNITS = 20       -- the trend follows the price this many in
local RECALC = 2             -- seconds between working it out again
local SERIES_DAYS = 30       -- days of price history the chances look at
local SERIES_GAP = 60        -- seconds between points kept from it (dips last a minute or two)
local LOOK = 48 * 3600       -- how far ahead each point is followed
local MIN_SAMPLE = 20        -- points needed to trust a chance

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
-- for a month: ns.Store().market.hist[itemID] = { { at, mine, rows }, ... }
-- (rows: price, quantity, ...; mine: how many of it you'd bought in all).
---------------------------------------------------------------------------
local function Market()
	local store = ns.Store and ns.Store() or ns.db
	store.market = type(store.market) == "table" and store.market or { snaps = {}, checks = {} }
	return store.market
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
-- else the last kept, and how old (seconds; 0 for live). Also yours, the
-- same way (live only; they sell before your dearer ones).
local function Book(id, list)
	local AH = C_AuctionHouse
	local n = AH and AH.GetNumCommoditySearchResults and AH.GetNumCommoditySearchResults(id) or 0
	if n > 0 then
		local rows, own = {}, {}
		for i = 1, math.min(n, LIVE_ROWS) do
			local r = AH.GetCommoditySearchResultInfo(id, i)
			if not r then break end
			local mine = r.numOwnerItems or 0
			local open = r.quantity - mine
			if open > 0 then
				rows[#rows + 1] = r.unitPrice
				rows[#rows + 1] = open
			end
			if mine > 0 then
				own[#own + 1] = r.unitPrice
				own[#own + 1] = mine
			end
		end
		if #rows > 0 then return rows, 0, own end
	end
	local last = list[#list]
	if last then return last.rows, ns.Now() - last.at, {} end
	return nil
end

-- Copper an hour the price FLOOR_UNITS in has moved lately; nil if not
-- watched long enough.
local function Trend(list)
	local now = ns.Now()
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

---------------------------------------------------------------------------
-- The chances, from history: listed at p, yours have sold once the cheapest
-- price goes over p. What counts is your place in line - how many are ahead
-- of you - not the price: a dip under the usual price is a short line, a
-- price level from days ago isn't now's. So at each past refresh, the spot
-- with as many ahead as p has now (the same Up to left out): how long until
-- the cheapest went over it? Across all of them, how often that took under
-- 2, 8, 24 hours is the chance. Moments followed less than that (the data
-- stops) count only as far as they go (Kaplan-Meier). Undercutting, buyers,
-- time of day: all in.
---------------------------------------------------------------------------
-- The cheapest price over time, oldest first: your refreshes and your scans
-- (Archive.lua), one point per SERIES_GAP: { t, cheapest then, highest
-- cheapest before the next point, rows = a refresh's listings if one's in it }.
local function Series(id, list)
	local pts = {}
	for _, s in ipairs(list) do
		if s.rows[1] then pts[#pts + 1] = { s.at, s.rows[1], rows = s.rows } end
	end
	if ns.Archive and ns.Archive.Ticks then
		local today = ns.Data.Today()
		for _, k in ipairs(ns.Archive.Ticks(ns.house or "faction", id, today - SERIES_DAYS, today)) do
			if k.cheapest and k.cheapest > 0 then pts[#pts + 1] = { k.t, k.cheapest } end
		end
	end
	table.sort(pts, function(a, b) return a[1] < b[1] end)
	local out = {}
	for _, p in ipairs(pts) do
		local last = out[#out]
		if last and p[1] - last[1] < SERIES_GAP then
			last[3] = math.max(last[3], p[2])
			last.rows = last.rows or p.rows
		else
			out[#out + 1] = { p[1], p[2], p[2], rows = p.rows }
		end
	end
	return out
end

-- A sample for KM, as one number (sorts fast, without a compare function):
-- whole seconds * 2, +1 if it didn't sell (so at the same time, sales first).
local function Sample(seconds, sold) return math.floor(seconds) * 2 + (sold and 0 or 1) end

-- Kaplan-Meier over samples (Sample): the chance of selling by each of
-- horizons (seconds, ascending; nil with too few samples), and when it's 50%
-- (nil if never).
local function KM(samples, horizons)
	table.sort(samples)
	local n, S, events, h = #samples, 1, 0, 1
	local chance, median = {}, nil
	local function Mark(i) -- samples before i are all at or under horizons[h]
		while horizons[h] and (i > n or samples[i] > horizons[h] * 2 + 1) do
			if events + (n - i + 1) >= MIN_SAMPLE then chance[h] = 1 - S end
			h = h + 1
		end
	end
	for i = 1, n do
		Mark(i)
		if samples[i] % 2 == 0 then
			S = S * (1 - 1 / (n - i + 1))
			events = events + 1
			if not median and S <= 0.5 and n >= MIN_SAMPLE then median = samples[i] / 2 end
		end
	end
	Mark(n + 1)
	return chance, median
end

-- The prices in rows (price, quantity, ...; ascending) with aheads[k] in
-- front (those at or under floor left out): just under the first listing
-- that would put more than that ahead. spots[k] = nil where rows stop first
-- (cut off: not known).
local function Spots(rows, aheads, floor, spots)
	local cum, r, n = 0, 1, #rows
	for k = 1, #aheads do
		while r < n do
			local price, qty = rows[r], rows[r + 1]
			if (floor and price <= floor) or cum + qty <= aheads[k] then
				if not (floor and price <= floor) then cum = cum + qty end
				r = r + 2
			else
				break
			end
		end
		spots[k] = r < n and rows[r] - 1 or nil
	end
	return spots
end

-- aheads: how many are ahead of each row now, ascending; floor: Up to;
-- delay: seconds yours add once it's your turn. Returns
-- { { chance, median }, ... } per row.
local function Passage(series, aheads, floor, delay)
	local n, K = #series, #aheads
	local horizons = {}
	for i, h in ipairs(HORIZONS) do horizons[i] = h * 3600 end
	local samples, spots = {}, {}
	for k = 1, K do samples[k] = {} end
	local last = n > 0 and series[n][1] or 0
	-- Backwards, keeping the points where the cheapest set a new high
	-- looking ahead: highs[1] the highest, falling to the top (the nearest).
	-- The first point the cheapest went over x is the nearest above x.
	local at, highs, top = {}, {}, 0
	for i = n, 1, -1 do
		local s = series[i]
		while top > 0 and highs[top] <= s[3] do top = top - 1 end
		top = top + 1
		at[top], highs[top] = s[1], s[3]
		if s.rows then
			Spots(s.rows, aheads, floor, spots)
			for k = 1, K do
				local x = spots[k]
				if x then
					local t
					if highs[1] > x then
						local lo, hi = 1, top -- the last with highs > x
						while lo < hi do
							local mid = math.floor((lo + hi + 1) / 2)
							if highs[mid] > x then lo = mid else hi = mid - 1 end
						end
						t = at[lo] - s[1]
					end
					local list = samples[k]
					if t and t <= LOOK then
						list[#list + 1] = Sample(t + delay, true)
					else
						list[#list + 1] = Sample(math.min(LOOK, last - s[1]), false)
					end
				end
			end
		end
	end
	local out = {}
	for k = 1, K do
		local chance, median = KM(samples[k], horizons)
		out[k] = { chance = chance, median = median }
	end
	return out
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
	local realm = ns.Realm()
	local scan = realm and realm.lastScan or 0
	local c = cache[id]
	if not (c and c.n == #list and c.last == (list[#list] and list[#list].at) and c.scan == scan) then
		c = { n = #list, last = list[#list] and list[#list].at, scan = scan, speed = {}, trend = Trend(list),
			series = Series(id, list) }
		cache[id] = c
	end
	local book, age, own = Book(id, list)
	if not book then return nil end
	local prior = Prior(id)
	local first = c.series[1]
	local out = { rows = {}, trend = c.trend, age = age, seen = 0, span = first and ns.Now() - first[1] or 0 }
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
		local ahead = Under(book, p, floor) + Under(own, p)
		local hours
		if rate and rate > 0 then
			hours = (ahead + math.max(1, count)) / rate / 3600
		elseif rate and seen >= NEVER_SEEN then
			hours = math.huge -- watched long enough to say so; less, it's just noise
		end
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
	-- From history, where there's enough: the chances, and when it's 50%.
	if #c.series > 0 and #out.rows > 0 then
		local aheads = {}
		for k, r in ipairs(out.rows) do aheads[k] = r.ahead end
		local delay = (prior and prior > 0) and count / prior or 0
		local key = table.concat(aheads, ",") .. ":" .. tostring(floor) .. ":" .. delay
		if c.passageKey ~= key then c.passageKey, c.passage = key, Passage(c.series, aheads, floor, delay) end
		for k, r in ipairs(out.rows) do
			local p = c.passage[k]
			r.chance = p.chance
			if p.median then
				r.hours, r.over = p.median / 3600, nil
			elseif p.chance[#HORIZONS] then
				r.hours, r.over = nil, HORIZONS[#HORIZONS]
			end
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
			"Data: how far back the price history goes (your scans and refreshes)." })
	end)
	summaryHover:SetScript("OnLeave", function() GameTooltip:Hide() end)
	rows = {}
end

function Ladder.Hide()
	if frame then frame:Hide() end
end

-- Show the ladder for id beside the tracker (anchor). info: { left (how many
-- you'd list), short (still to make back, after what's up), floor (your Up
-- to, in Quick buy), price (the sell page's Unit Price) }.
function Ladder.Show(anchor, id, info)
	if not frame then Create(anchor) end
	local texture = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)
	ns.SideWindowIcon(frame, texture or "Interface\\Icons\\INV_Misc_QuestionMark")
	local count = info.left or 0
	local custom = info.price or (ns.QuickBuy and ns.QuickBuy.Target and ns.QuickBuy.Target(id))
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
	local span = w and math.max(w.span, w.seen) or 0
	if span > 0 then
		bits[#bits + 1] = GREY .. ("Data %s|r"):format((Duration(span / 3600):gsub("~", "")))
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
				sells = r.over and (">" .. Duration(r.over):gsub("~", "")) or Duration(r.hours),
				profit = count > 0 and Signed(math.floor(r.price * cut * count) - (info.short or 0)) or nil,
			}
			for k, h in ipairs(HORIZONS) do
				local p = r.chance and r.chance[k] or (r.hours and Chance(r.hours, h))
				if p then
					p = math.max(0.05, math.min(0.95, p))
					v["h" .. k] = ("%d%%"):format(math.floor(p * 20 + 0.5) * 5)
				else
					v["h" .. k] = GREY .. "?|r"
				end
			end
			local speed = not r.perHour and "Not enough data yet."
				or r.perHour > 0 and ("~%d sell an hour."):format(math.floor(r.perHour + 0.5))
				or "More listed than sold."
			local label = r.custom and ((info.price and "Your Unit Price: " or "Your resale price: ") .. ns.Money(r.price))
			Line(i, y, "GameFontHighlightSmall", v, { label or ns.Money(r.price),
				("%d listed cheaper."):format(r.ahead), speed })
			y = y - ROW
		end
	end
	for k = i + 1, #rows do rows[k]:Hide() end
	frame:SetHeight(-y + PAD)
	frame:Show()
end
