-- Your profit from Quick buy sessions, day by day, for the Profit tab of the
-- price window (Profit.lua). Saved, and kept through End session.
--
-- Only sessions count (Start session on Quick buy): what they bought, and of
-- those items, what sold - your listings and seeds, after the auction house's
-- cut - and the deposits lost. Items you had before don't count, so a sale
-- counts only as far as you still hold items bought in a session.
--
--   ns.db.ledger = {
--     items = { [itemID] = { house, days = { [day] = { b, s, spent, income, lost } } } },
--       b, s = how many bought / sold that day
--     kept = { listed = { listings of ended sessions still up, each with its itemID },
--              ... } (followed by Listings.lua like a session's),
--     log = { "time day kind itemID ...", ... } every change as it came in, so
--       the days can be worked out again (/fah rebuild):
--       b qty spent | s qty income (before the cap to what you hold) | l copper
--       | u undoneDay n income lost | d b s spent income lost (a day from before
--       the log)
--   }
local _, ns = ...

local Ledger = {}
ns.Ledger = Ledger

local function DB()
	local db = ns.db.ledger
	if not db then
		db = {}
		ns.db.ledger = db
	end
	db.items = db.items or {}
	db.kept = db.kept or {}
	db.kept.listed = db.kept.listed or {}
	if not db.log then
		db.log = {}
		local now = time()
		for id, item in pairs(db.items) do
			for day, d in pairs(item.days) do
				db.log[#db.log + 1] = ("%d %d d %d %d %d %d %d %d"):format(now, day, id, d.b, d.s, d.spent, d.income, d.lost)
			end
		end
	end
	return db
end

local replayDay -- the day of the record being replayed (Rebuild)

local function Log(kind, id, ...)
	if replayDay then return end
	local parts = { time(), ns.Data.Today(), kind, id }
	for i = 1, select("#", ...) do parts[#parts + 1] = math.floor((select(i, ...)) or 0) end
	local log = DB().log
	log[#log + 1] = table.concat(parts, " ")
end

local function Day(id, day)
	local items = DB().items
	local item = items[id]
	if not item then
		item = { house = ns.house or "faction", days = {} }
		items[id] = item
	end
	day = day or replayDay or ns.Data.Today()
	local d = item.days[day]
	if not d then
		d = { b = 0, s = 0, spent = 0, income = 0, lost = 0 }
		item.days[day] = d
	end
	return d
end

-- Bought in a session at some point.
function Ledger.Tracked(id)
	return id ~= nil and DB().items[id] ~= nil
end

-- How many bought in sessions you still hold (not sold).
function Ledger.Held(id)
	local item = DB().items[id]
	if not item then return 0 end
	local n = 0
	for _, d in pairs(item.days) do n = n + d.b - d.s end
	return math.max(0, n)
end

function Ledger.Buy(id, qty, total)
	if not (id and qty and qty > 0) then return end
	Log("b", id, qty, total)
	local d = Day(id)
	d.b, d.spent = d.b + qty, d.spent + (total or 0)
end

-- A sale of qty for income (after the cut). Counts up to what you hold from
-- sessions; returns how many and how much counted.
function Ledger.Sold(id, qty, income)
	if not (Ledger.Tracked(id) and qty and qty > 0) then return 0, 0 end
	Log("s", id, qty, income)
	local n = math.min(qty, Ledger.Held(id))
	if n <= 0 then return 0, 0 end
	local counted = math.floor((income or 0) * n / qty + 0.5)
	local d = Day(id)
	d.s, d.income = d.s + n, d.income + counted
	return n, counted
end

-- A deposit (or cancel cost) lost; returns how much counted.
function Ledger.Lost(id, copper)
	if not (Ledger.Tracked(id) and copper and copper > 0) then return 0 end
	Log("l", id, copper)
	local d = Day(id)
	d.lost = d.lost + copper
	return copper
end

-- Take back what Sold and Lost counted on a day (a listing that wasn't over
-- after all).
function Ledger.Undo(id, day, n, income, lost)
	local item = DB().items[id]
	local d = item and day and item.days[day]
	if not d then return end
	Log("u", id, day, n, income, lost)
	d.s = math.max(0, d.s - (n or 0))
	d.income = math.max(0, d.income - (income or 0))
	d.lost = math.max(0, d.lost - (lost or 0))
end

-- Listings of ended sessions, still up: they keep counting until they end.
function Ledger.Kept()
	return DB().kept
end

-- Works the days out again from the log; returns how many records.
function Ledger.Rebuild()
	local db = DB()
	for _, item in pairs(db.items) do item.days = {} end
	local ok, err = pcall(function()
		for _, line in ipairs(db.log) do
			local f = {}
			for w in line:gmatch("%S+") do f[#f + 1] = tonumber(w) or w end
			local kind, id = f[3], f[4]
			replayDay = f[2]
			if kind == "b" then Ledger.Buy(id, f[5], f[6])
			elseif kind == "s" then Ledger.Sold(id, f[5], f[6])
			elseif kind == "l" then Ledger.Lost(id, f[5])
			elseif kind == "u" then Ledger.Undo(id, f[5], f[6], f[7], f[8])
			elseif kind == "d" then
				local d = Day(id)
				d.b, d.s = d.b + f[5], d.s + f[6]
				d.spent, d.income, d.lost = d.spent + f[7], d.income + f[8], d.lost + f[9]
			end
		end
	end)
	replayDay = nil
	if not ok then error(err) end
	return #db.log
end

---------------------------------------------------------------------------
-- Profit over time
---------------------------------------------------------------------------
-- What an item is worth on a day: that day's market price (or the nearest
-- before, else after), after the cut; without prices, what you paid on
-- average - no profit either way.
local function Pricer(id, item)
	local rec = ns.Data.Get(id, item.house) or ns.Data.Get(id)
	local history = rec and ns.Data.History(rec) or {}
	return function(day, avgCost)
		local price
		for _, h in ipairs(history) do
			if h[1] <= day then price = h[2] else break end
		end
		price = price or (history[1] and history[1][2])
		if price then return price * (1 - ns.QuickBuy.AH_CUT) end
		return avgCost or 0
	end
end

-- Day by day from the first session to today, for one item or (nil) all:
-- { { day, cash, value, total, held }, ... } - cash: sales less purchases and
-- deposits so far; value: what you still hold, at the market price; total:
-- the two together. nil with nothing yet.
function Ledger.Series(onlyID)
	local items = DB().items
	local list = {}
	local first
	for id, item in pairs(items) do
		if not onlyID or id == onlyID then
			list[#list + 1] = { id = id, item = item, price = Pricer(id, item), cash = 0, held = 0, b = 0, spent = 0 }
			for day in pairs(item.days) do first = math.min(first or day, day) end
		end
	end
	if not first then return nil end
	local today = ns.Data.Today()
	local series = {}
	for day = first, math.max(first, today) do
		local cash, value, held = 0, 0, 0
		for _, e in ipairs(list) do
			local d = e.item.days[day]
			if d then
				e.cash = e.cash + d.income - d.spent - d.lost
				e.held = math.max(0, e.held + d.b - d.s)
				e.b, e.spent = e.b + d.b, e.spent + d.spent
			end
			cash, held = cash + e.cash, held + e.held
			if e.held > 0 then value = value + e.held * e.price(day, e.b > 0 and e.spent / e.b or 0) end
		end
		series[#series + 1] = { day = day, cash = cash, value = value, total = cash + value, held = held }
	end
	return series
end

-- From a series: the average profit per day over the last `days` full days
-- (not today, still going), or nil before a full day.
function Ledger.PerDay(series, days)
	if not series then return nil end
	local n, sum = 0, 0
	for i = #series - 1, math.max(1, #series - days), -1 do
		local before = i > 1 and series[i - 1].total or 0
		sum, n = sum + series[i].total - before, n + 1
	end
	if n == 0 then return nil end
	return sum / n, n
end

-- Every item with sessions: { { id, total, held }, ... }, most profit first.
function Ledger.Items()
	local out = {}
	for id in pairs(DB().items) do
		local series = Ledger.Series(id)
		local last = series and series[#series]
		if last then out[#out + 1] = { id = id, total = last.total, held = last.held } end
	end
	table.sort(out, function(a, b) return a.total > b.total end)
	return out
end

-- All time, for one item or (nil) all: spent, income (after the cut), lost,
-- bought, sold.
function Ledger.Totals(onlyID)
	local spent, income, lost, b, s = 0, 0, 0, 0, 0
	for id, item in pairs(DB().items) do
		if not onlyID or id == onlyID then
			for _, d in pairs(item.days) do
				spent, income, lost = spent + d.spent, income + d.income, lost + d.lost
				b, s = b + d.b, s + d.s
			end
		end
	end
	return spent, income, lost, b, s
end
