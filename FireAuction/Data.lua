-- The price history, and the trend worked out from it.
--
-- Per item (realm.items[itemID]):
--   p  = lowest buyout per item in the latest scan (copper)
--   q  = how many were listed then (0 = none in the latest full scan)
--   s  = when that scan was (time())
--   nm = name
--   d  = { [day] = price } - one price per day: the average of that day's
--        scans' lowest buyouts
--   td, n = the day of the latest scan, and how many scans it had
--   l  = the latest scan's listings: "n,buyout,stack,bid,seller;..." where n is
--        how many identical auctions there were (bid only for bid-only ones)
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

function Data.Get(itemID)
	local realm = ns.Realm()
	return realm and itemID and realm.items[itemID]
end

-- prices = { [itemID] = { low = copper, qty = n, name = string|nil } }
-- complete: it was a full scan, so items missing from it aren't listed now.
function Data.CommitScan(prices, complete)
	local realm = ns.Realm()
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
	Data.Prune()
end

-- Forget days older than the history setting (and items with nothing left).
function Data.Prune()
	local realm = ns.Realm()
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
-- Returns slope (copper per day) and the line's value today, or nil with fewer
-- than two days of prices.
function Data.Fit(rec)
	local today = Data.Today()
	local from = today - Data.TrendDays()
	local n, sx, sy, sxx, sxy = 0, 0, 0, 0, 0
	for day, price in pairs(rec.d) do
		if day >= from then
			local x = day - today
			n, sx, sy, sxx, sxy = n + 1, sx + x, sy + price, sxx + x * x, sxy + x * price
		end
	end
	if n < 2 then return nil end
	local den = n * sxx - sx * sx
	if den == 0 then return nil end
	local slope = (n * sxy - sx * sy) / den
	return slope, (sy - slope * sx) / n
end

-- How much the price moved over the trend period, in percent, plus what the
-- line projects for the same time ahead. nil without enough history.
function Data.Trend(rec)
	local slope, now = Data.Fit(rec)
	if not slope then return nil end
	local days = Data.TrendDays()
	local before = now - slope * days
	if before <= 0 or now <= 0 then return nil end
	return (now - before) / before * 100, math.max(0, now + slope * days), slope, now
end

-- The latest scan's listings, cheapest first (bid-only ones last):
-- { { count = auctions, buyout = per stack, stack = n, unit = per item, bid = per stack, seller = name }, ... }
function Data.Listings(rec)
	local list = {}
	if not (rec and rec.l) then return list end
	for entry in rec.l:gmatch("[^;]+") do
		local n, buyout, stack, bid, seller = entry:match("^(%d+),(%d+),(%d+),(%d+),(.*)$")
		if n then
			buyout, stack, bid = tonumber(buyout), tonumber(stack), tonumber(bid)
			list[#list + 1] = {
				count = tonumber(n), buyout = buyout, stack = stack, bid = bid,
				unit = (buyout > 0 and buyout or bid) / math.max(1, stack),
				seller = seller ~= "" and seller or nil,
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
