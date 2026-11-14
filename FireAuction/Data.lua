-- The price history, and the trend worked out from it.
--
-- Kept per auction house (ns.Realm): your faction's, and the neutral one.
-- Per item (realm.items[itemID]):
--   p  = lowest buyout per item in the latest scan (copper)
--   m  = the market price in the latest scan (Data.MarketPrice); missing in
--        prices saved before it was added - Data.Market falls back to p
--   q  = how many were listed then (0 = none in the latest full scan)
--   s  = when that scan was (time())
--   nm = name
--   d  = { [day] = price } - one price per day: the average of that day's
--        scans' market prices (days saved before market prices: the lowest
--        buyouts), yours and your guild's
--   dn = { [day] = scans } - how many scans a day's price averages (only
--        when more than one)
--   (td, n = the latest scan's day and its scans: how dn used to be kept)
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

-- The market price: what most of it really sells around, not a few cheap
-- ones. Of all the units listed (with a buyout), take the cheapest quarter;
-- the market price is the one in the middle of those. So 40 at 1s 70c under
-- 1000 at 2s is 2s, one at 1s under 2000 at 2s is 2s, and 2000 at 2s under
-- 5000 at 3s is still 2s.
--   list: { ["buyout,stack,bid"] = auctions } (a scan's listings)
-- nil without buyouts.
local MARKET_SHARE = 0.25
function Data.MarketPrice(list)
	local units, total = {}, 0
	for key, n in pairs(list or {}) do
		local buyout, stack = key:match("^(%d+),(%d+)")
		buyout, stack = tonumber(buyout), tonumber(stack)
		if buyout and buyout > 0 and stack and stack > 0 then
			units[#units + 1] = { buyout / stack, stack * n }
			total = total + stack * n
		end
	end
	if total == 0 then return nil end
	table.sort(units, function(a, b) return a[1] < b[1] end)
	local target = math.ceil(math.max(1, math.ceil(total * MARKET_SHARE)) / 2)
	local count = 0
	for _, u in ipairs(units) do
		count = count + u[2]
		if count >= target then return math.floor(u[1] + 0.5) end
	end
	return math.floor(units[#units][1] + 0.5)
end

-- The item's market price (the lowest buyout for prices saved before market
-- prices were).
function Data.Market(rec)
	return rec and (rec.m or rec.p)
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
		local market = math.max(low, Data.MarketPrice(p.list) or low)
		rec.p, rec.m, rec.q, rec.s = low, market, p.qty, now
		if p.name then rec.nm = p.name end
		if p.list then
			local parts = {}
			for key, count in pairs(p.list) do parts[#parts + 1] = count .. "," .. key end
			rec.l = table.concat(parts, ";")
		end
		Data.AddScan(rec, today, market)
	end
	if complete then
		for id, rec in pairs(realm.items) do
			if not prices[id] then rec.q, rec.l = 0, nil end
		end
	end
	realm.lastScan = now
	Data.Prune(house)
end

-- Moves the old td/n into dn.
local function Upgrade(rec)
	if rec.td then
		if rec.n and rec.n > 1 and rec.d[rec.td] then
			rec.dn = rec.dn or {}
			rec.dn[rec.td] = rec.n
		end
		rec.td, rec.n = nil, nil
	end
end

-- How many scans the day's price averages (0 without one).
function Data.Scans(rec, day)
	if not rec.d[day] then return 0 end
	Upgrade(rec)
	return rec.dn and rec.dn[day] or 1
end

-- Sets the day's price and how many scans it averages.
function Data.SetDay(rec, day, price, scans)
	Upgrade(rec)
	rec.d[day] = price
	if scans > 1 then
		rec.dn = rec.dn or {}
		rec.dn[day] = scans
	elseif rec.dn then
		rec.dn[day] = nil
		if not next(rec.dn) then rec.dn = nil end
	end
end

-- One more scan's market price, into the day's average.
function Data.AddScan(rec, day, price)
	local n = Data.Scans(rec, day)
	local old = rec.d[day]
	if old then price = math.floor(old + (price - old) / (n + 1) + 0.5) end
	Data.SetDay(rec, day, price, n + 1)
end

-- Forget days older than the history setting (and items with nothing left).
function Data.Prune(house)
	local realm = ns.Realm(house)
	if not realm then return end
	local oldest = Data.Today() - ns.db.historyDays
	for id, rec in pairs(realm.items) do
		local any = false
		for day in pairs(rec.d) do
			if day < oldest then
				rec.d[day] = nil
				if rec.dn then rec.dn[day] = nil end
			else
				any = true
			end
		end
		if rec.dn and not next(rec.dn) then rec.dn = nil end
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
