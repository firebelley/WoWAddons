-- How much sells: an estimate (shown in the price window, marked as one).
--
-- Two scans of the same auction house close together (this session): what
-- was listed in the first and is gone from the second, from listings with
-- time to spare (so not expired), was bought - or cancelled, which looks the
-- same. Scans have no auction IDs, so listings are told apart by seller and
-- price each. A day's rate: what went in the time its scan pairs cover,
-- scaled up to the whole day.
--
-- Kept (not shared with the guild):
--   rec.ds = { [day] = units gone } (Data.lua prunes it with the prices)
--   realm.vol.cover = { [day] = seconds between the day's scan pairs }
--   c.volCheck = { { t1, t2, name, gone }, ... } your own listings' share of
--     it, per item, the last two weeks; /fah volume compares it with what
--     really sold (Sales.lua's soldLog) and what you cancelled (cancelLog).
local _, ns = ...

local Volume = {}
ns.Volume = Volume

local MAX_GAP = 2 * 3600 -- scans further apart don't pair up
-- The least time left in each of the game's time-left bands.
local BAND_MIN = { [0] = 0, [1] = 1800, [2] = 7200, [3] = 43200 }
local KEEP = 14 * 86400

local last = {} -- [house] = { t, groups } the previous scan

-- groups: { [itemID] = { ["seller|unit price"] = { count, shortest band } } } (Scan.lua)
-- Returns what went, { [itemID] = units } (items with none left out), and
-- the seconds since the scan it's compared with; nil without one.
function Volume.Scanned(house, groups)
	local now = ns.Now()
	local prev = last[house]
	last[house] = { t = now, groups = groups }
	if not prev then return nil end
	local gap = now - prev.t
	if gap <= 0 or gap > MAX_GAP then return nil end
	local realm = ns.Realm(house)
	if not realm then return nil end
	local goneByItem = {}
	local day = ns.Data.Today()
	realm.vol = realm.vol or {}
	realm.vol.cover = realm.vol.cover or {}
	realm.vol.cover[day] = (realm.vol.cover[day] or 0) + gap
	for d in pairs(realm.vol.cover) do
		if d < day - (ns.db.historyDays or 30) then realm.vol.cover[d] = nil end
	end

	local c = ns.Sales and ns.Sales.Char and ns.Sales.Char()
	local me = UnitName("player")
	local mine = me and (me .. "|")
	local checks = {}
	for id, before in pairs(prev.groups) do
		local after = groups[id] or {}
		local gone, own, hadOwn = 0, 0, false
		for key, e in pairs(before) do
			local isOwn = mine and key:sub(1, #mine) == mine
			if isOwn then hadOwn = true end
			local left = after[key] and after[key][1] or 0
			-- Gone, with too much time left to have run out.
			if e[1] > left and (BAND_MIN[e[2]] or 0) >= gap then
				gone = gone + e[1] - left
				if isOwn then own = own + e[1] - left end
			end
		end
		local rec = realm.items[id]
		if gone > 0 then goneByItem[id] = gone end
		if gone > 0 and rec then
			rec.ds = rec.ds or {}
			rec.ds[day] = (rec.ds[day] or 0) + gone
		end
		if hadOwn and c then
			checks[#checks + 1] = { prev.t, now, rec and rec.nm or ns.Data.Name(id, rec) or ("item " .. id), own }
		end
	end
	if c and #checks > 0 then
		c.volCheck = c.volCheck or {}
		local list = c.volCheck
		for i = #list, 1, -1 do
			if now - list[i][2] > KEEP then table.remove(list, i) end
		end
		for _, e in ipairs(checks) do list[#list + 1] = e end
	end
	return goneByItem, gap
end

local function Cover(house, day)
	local realm = ns.Realm(house)
	local cover = realm and realm.vol and realm.vol.cover
	return cover and cover[day] or 0
end

-- About how many sold on the day, scaled up to the whole day, and how many
-- minutes of scan pairs that's from; nil for a day without any.
function Volume.Day(rec, house, day)
	local cover = Cover(house, day)
	if cover <= 0 then return nil end
	local gone = rec.ds and rec.ds[day] or 0
	return math.floor(gone / cover * 86400 + 0.5), math.floor(cover / 60 + 0.5)
end

-- About how many sell a day, over the trend period's days with scan pairs;
-- and how many of those days. nil without any.
function Volume.PerDay(rec, house)
	local today = ns.Data.Today()
	local gone, cover, days = 0, 0, 0
	for day = today - ns.Data.TrendDays() + 1, today do
		local c = Cover(house, day)
		if c > 0 then
			gone, cover, days = gone + (rec.ds and rec.ds[day] or 0), cover + c, days + 1
		end
	end
	if cover <= 0 then return nil end
	return gone / cover * 86400, days
end

-- What a log (Sales.lua) has for the item between t1 and t2.
local function Between(log, name, t1, t2)
	local n = 0
	for _, e in ipairs(log or {}) do
		if e[3] == name and e[1] > t1 and e[1] <= t2 then n = n + e[2] end
	end
	return n
end

-- /fah volume: the estimate for your own listings, against what really
-- happened to them.
function Volume.Report()
	local c = ns.Sales and ns.Sales.Char and ns.Sales.Char()
	local list = c and c.volCheck
	if not (list and #list > 0) then
		ns.Print("volume check: nothing yet. It needs two scans less than 2 hours apart while you have auctions up.")
		return
	end
	local items, pairsSeen = {}, {}
	local est, sold, cancelled = 0, 0, 0
	for _, e in ipairs(list) do
		local t1, t2, name, gone = e[1], e[2], e[3], e[4]
		pairsSeen[t1 .. ":" .. t2] = true
		local s, x = Between(c.soldLog, name, t1, t2), Between(c.cancelLog, name, t1, t2)
		est, sold, cancelled = est + gone, sold + s, cancelled + x
		local it = items[name] or { est = 0, sold = 0, cancelled = 0 }
		items[name] = it
		it.est, it.sold, it.cancelled = it.est + gone, it.sold + s, it.cancelled + x
	end
	local n = 0
	for _ in pairs(pairsSeen) do n = n + 1 end
	ns.Print(("volume check over %d scan pair%s, your own listings: estimated %d sold; really %d sold%s."):format(
		n, n == 1 and "" or "s", est, sold, cancelled > 0 and (", " .. cancelled .. " cancelled") or ""))
	local sorted = {}
	for name, it in pairs(items) do
		if it.est + it.sold + it.cancelled > 0 then sorted[#sorted + 1] = { name = name, it = it } end
	end
	table.sort(sorted, function(a, b) return a.it.est + a.it.sold > b.it.est + b.it.sold end)
	for i = 1, math.min(10, #sorted) do
		local it = sorted[i].it
		print(("  %s: estimated %d, sold %d%s"):format(sorted[i].name, it.est, it.sold,
			it.cancelled > 0 and (", cancelled " .. it.cancelled) or ""))
	end
end
