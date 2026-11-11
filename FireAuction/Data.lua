-- The price history, and the trend worked out from it.
--
-- Kept per auction house (ns.Realm): your faction's, and the neutral one.
-- Per item (realm.items[itemID]):
--   p  = lowest buyout per item in the latest scan (copper)
--   q  = how many were listed then (0 = none in the latest full scan)
--   s  = when that scan was (time())
--   nm = name
--   d  = { [day] = price } - one price per day: the average of that day's
--        scans' lowest buyouts
--   td, n = the day of the latest scan, and how many scans it had
--   l  = the latest scan's listings: "n,buyout,stack,bid;..." where n is how
--        many identical auctions there were (bid only for bid-only ones)
local _, ns = ...

local Data = {}
ns.Data = Data

local DAY = 86400

function Data.Today()
	return math.floor(time() / DAY)
end

function Data.DayTime(day)
	return day * DAY + DAY / 2
end

-- house: see ns.Realm (nil = the auction house you're using).
function Data.Get(itemID, house)
	local realm = ns.Realm(house)
	return realm and itemID and realm.items[itemID]
end

-- prices = { [itemID] = { low = copper, qty = n, name = string|nil } }
-- complete: it was a full scan, so items missing from it aren't listed now.
-- house: the auction house it was scanned at (see ns.Realm).
function Data.CommitScan(prices, complete, house)
	local realm = ns.Realm(house)
	if not realm then return end
	local now, today = time(), Data.Today()
	for id, p in pairs(prices) do
		local rec = realm.items[id]
		if not rec then
			rec = { d = {} }
			realm.items[id] = rec
		end
		local low = math.floor(p.low + 0.5)
		rec.p, rec.q, rec.s = low, p.qty, now
		if p.name then rec.nm = p.name end
		if p.list then
			local parts = {}
			for key, count in pairs(p.list) do parts[#parts + 1] = count .. "," .. key end
			rec.l = table.concat(parts, ";")
		end
		if rec.td == today and rec.d[today] then
			rec.n = (rec.n or 1) + 1
			rec.d[today] = math.floor(rec.d[today] + (low - rec.d[today]) / rec.n + 0.5)
		else
			rec.td, rec.n = today, 1
			rec.d[today] = low
		end
	end
	if complete then
		for id, rec in pairs(realm.items) do
			if not prices[id] then rec.q, rec.l = 0, nil end
		end
	end
	realm.lastScan = now
	Data.Prune(house)
end

-- Forget days older than the history setting (and items with nothing left).
function Data.Prune(house)
	local realm = ns.Realm(house)
	if not realm then return end
	local oldest = Data.Today() - ns.db.historyDays
	for id, rec in pairs(realm.items) do
		local any = false
		for day in pairs(rec.d) do
			if day < oldest then rec.d[day] = nil else any = true end
		end
		if not any then realm.items[id] = nil end
	end
end

-- The item's days with prices, oldest first: { { day, price }, ... }
function Data.History(rec)
	local list = {}
	for day, price in pairs(rec.d) do list[#list + 1] = { day, price } end
	table.sort(list, function(a, b) return a[1] < b[1] end)
	return list
end

function Data.TrendDays()
	return math.max(2, math.min(ns.db.trendDays, ns.db.historyDays))
end

-- A straight line through the daily prices of the trend period (least squares).
-- Returns slope (copper per day), the line's value today, and how many days
-- back the oldest price in the period is; nil with fewer than two days of
-- prices.
function Data.Fit(rec)
	local today = Data.Today()
	local from = today - Data.TrendDays()
	local n, sx, sy, sxx, sxy = 0, 0, 0, 0, 0
	local oldest = today
	for day, price in pairs(rec.d) do
		if day >= from then
			local x = day - today
			n, sx, sy, sxx, sxy = n + 1, sx + x, sy + price, sxx + x * x, sxy + x * price
			if day < oldest then oldest = day end
		end
	end
	if n < 2 then return nil end
	local den = n * sxx - sx * sx
	if den == 0 then return nil end
	local slope = (n * sxy - sx * sy) / den
	return slope, (sy - slope * sx) / n, math.max(1, today - oldest)
end

-- How much the price moved over the days the trend period has prices for
-- (span: at most the trend period), in percent, and what the line projects
-- for the same time ahead. Only measuring the days that have prices keeps two
-- days of history from being stretched into a week-long rise or fall.
-- Returns pct, projected, slope, now, span; nil without enough history.
function Data.Trend(rec)
	local slope, now, span = Data.Fit(rec)
	if not slope then return nil end
	local before = now - slope * span
	if before <= 0 or now <= 0 then return nil end
	return (now - before) / before * 100, math.max(0, now + slope * span), slope, now, span
end

-- The latest scan's listings, cheapest first (bid-only ones last):
-- { { count = auctions, buyout = per stack, stack = n, unit = per item, bid = per stack }, ... }
-- (Scans saved before sellers were dropped have ",seller" after each entry;
-- the pattern ignores it.)
function Data.Listings(rec)
	local list = {}
	if not (rec and rec.l) then return list end
	for entry in rec.l:gmatch("[^;]+") do
		local n, buyout, stack, bid = entry:match("^(%d+),(%d+),(%d+),(%d+)")
		if n then
			buyout, stack, bid = tonumber(buyout), tonumber(stack), tonumber(bid)
			list[#list + 1] = {
				count = tonumber(n), buyout = buyout, stack = stack, bid = bid,
				unit = (buyout > 0 and buyout or bid) / math.max(1, stack),
			}
		end
	end
	table.sort(list, function(a, b)
		if (a.buyout > 0) ~= (b.buyout > 0) then return a.buyout > 0 end
		if a.unit ~= b.unit then return a.unit < b.unit end
		return a.stack < b.stack
	end)
	return list
end

function Data.Name(itemID, rec)
	local name = rec and rec.nm
	if not name and C_Item and C_Item.GetItemNameByID then
		name = C_Item.GetItemNameByID(itemID)
		if name and rec then rec.nm = name end
	end
	return name
end
