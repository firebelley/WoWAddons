-- Items to flip over a day: ones that keep dipping and coming back up within
-- a day - buy in the dip, list for 24 hours at the price it comes back to.
--
-- From the archive's record of every scan (Archive.Ticks), the last DAYS
-- days:
--   buy at: the low end - the market price a quarter of the scans were at
--     or under.
--   each day it dipped there (that day's first scan at or under it: one a
--     day, so one buyout can't count many times), the most a listing put up
--     then would have sold for within 24 hours: just under the dearest
--     cheapest listing seen in that time - everything under that had gone,
--     and a listing can only go by being bought.
--   list at: the price that would have made the most over those days, after
--     the auction house's cut, of the prices that sold on at least
--     MIN_SHARE of them.
-- Needs dips on MIN_DAYS days; items worth less than MIN_PRICE are left out.
local _, ns = ...

local Flip = {}
ns.Flip = Flip

local DAYS = 14
local HOLD = 24 * 3600
local MIN_DAYS = 3
local MIN_SHARE = 2 / 3
local MIN_PRICE = 100 -- 1s
local CUT = 0.05
local LOW_SHARE = 0.25

-- ticks: Archive.Ticks's, oldest first. nil when it isn't one to flip, else
-- { buy, list (copper each), gain (% after the cut), sold, days }.
function Flip.Work(ticks)
	if #ticks < MIN_DAYS * 2 then return nil end
	local prices = {}
	for i, t in ipairs(ticks) do prices[i] = t.market end
	table.sort(prices)
	local low = prices[math.max(1, math.floor(#prices * LOW_SHARE + 0.5))]
	if low < MIN_PRICE then return nil end
	-- A dip in the last few hours has most of its day still to come.
	local last = ticks[#ticks].t
	local reached, seen = {}, {}
	-- Days by your clock: the seconds it's ahead of UTC.
	local now = time()
	local zone = time(date("*t", now)) - time(date("!*t", now))
	for i, t in ipairs(ticks) do
		local day = t.market <= low and t.t + HOLD <= last + 6 * 3600 and math.floor((t.t + zone) / 86400)
		if day and not seen[day] then
			seen[day] = true
			local best = 0
			for j = i + 1, #ticks do
				local u = ticks[j]
				if u.t > t.t + HOLD then break end
				if u.cheapest - 1 > best then best = u.cheapest - 1 end
			end
			reached[#reached + 1] = best
		end
	end
	local days = #reached
	if days < MIN_DAYS then return nil end
	local list, sold, most = nil, 0, 0
	for _, price in ipairs(reached) do
		local n = 0
		for _, r in ipairs(reached) do
			if r >= price then n = n + 1 end
		end
		local made = (price * (1 - CUT) - low) * n
		if n >= days * MIN_SHARE and made > most then list, sold, most = price, n, made end
	end
	if not list then return nil end
	return { buy = low, list = list, gain = (list * (1 - CUT) / low - 1) * 100, sold = sold, days = days }
end

-- Worked out once per scan: { [house] = { key, items = { [id] = result or false }, all } }
local cache = {}

local function Cached(house)
	local realm = ns.Realm(house)
	local key = (realm and realm.lastScan or 0) .. " " .. date("%Y%m%d")
	local c = cache[house]
	if not c or c.key ~= key then
		c = { key = key, items = {} }
		cache[house] = c
	end
	return c
end

local function Range()
	local today = ns.Data.Today()
	return today - DAYS, today
end

-- The item's flip (see Flip.Work), or nil. Doesn't load the archive: nil
-- until it's loaded (at the auction house, or by Flip.All).
function Flip.Get(id, house)
	house = house or ns.house or "faction"
	if not (id and ns.Archive.Loaded()) then return nil end
	local c = Cached(house)
	local r = c.items[id]
	if r == nil then
		if c.all then return nil end
		local from, to = Range()
		r = Flip.Work(ns.Archive.Ticks(house, id, from, to)) or false
		c.items[id] = r
	end
	return r or nil
end

-- Every item's: { [id] = result } (loads the archive). Worked out a few
-- milliseconds a frame (thousands of items): nil until it's done, then
-- done() is called.
local BUDGET = 8 -- ms a frame
local working = {}

function Flip.All(house, done)
	house = house or ns.house or "faction"
	if not ns.Archive.DB() then return {} end
	local c = Cached(house)
	if c.all then
		local out = {}
		for id, r in pairs(c.items) do
			if r then out[id] = r end
		end
		return out
	end
	if working[house] == c then return nil end
	working[house] = c
	local from, to = Range()
	local ids = {}
	for id in pairs(ns.Archive.TickItems(house, from, to)) do ids[#ids + 1] = id end
	local i = 0
	local function Step()
		if cache[house] ~= c then -- a new scan: start again
			working[house] = nil
			if done then done() end
			return
		end
		local stop = debugprofilestop() + BUDGET
		while i < #ids and debugprofilestop() < stop do
			i = i + 1
			local id = ids[i]
			if c.items[id] == nil then
				c.items[id] = Flip.Work(ns.Archive.Ticks(house, id, from, to)) or false
			end
		end
		if i < #ids then
			C_Timer.After(0, Step)
		else
			c.all, working[house] = true, nil
			if done then done() end
		end
	end
	Step()
	return c.all and Flip.All(house) or nil
end

-- Whether Flip.All is still working.
function Flip.Working(house)
	return working[house or ns.house or "faction"] ~= nil
end
