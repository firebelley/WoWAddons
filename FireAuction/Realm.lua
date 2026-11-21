-- The realm's name, for everything kept per realm ("Realm - Horde",
-- "Name - Realm").
--
-- Forever's client started giving "" for GetRealmName() (2026-11-20), which
-- split everything in two: what came after went under " - Horde" and
-- "Name - ". So the last real name seen stands in for a blank one (or, before
-- one's seen, the one the saved data was kept under), and whatever went under
-- the blank one is put back with the rest when the addon loads.
local _, ns = ...

-- A realm name from the saved keys, when they name only one.
local function SavedName(db)
	local found, count = nil, 0
	local function Add(name)
		if name and name ~= "" and name ~= found then
			found, count = name, count + 1
		end
	end
	for key in pairs(db.realms or {}) do Add(key:match("^(.+) %- %a+$")) end
	for key in pairs(db.chars or {}) do Add(key:match("^.- %- (.+)$")) end
	return count == 1 and found or nil
end

function ns.RealmName()
	local name = GetRealmName and GetRealmName()
	if type(name) == "string" and name ~= "" then
		if ns.db then ns.db.realmName = name end
		return name
	end
	return ns.db and ns.db.realmName or ""
end

---------------------------------------------------------------------------
-- Putting the blank realm's data back
---------------------------------------------------------------------------
local Data = ns.Data
local floor = math.floor

-- Prices: an item from the blank realm (b) into the same item (a).
local function MergeItem(a, b)
	if (b.s or 0) > (a.s or 0) then
		a.p, a.m, a.q, a.s, a.l = b.p, b.m, b.q, b.s, b.l
	end
	a.nm = a.nm or b.nm
	a.d = a.d or {}
	for day, price in pairs(b.d or {}) do
		local bn, bq = Data.Scans(b, day), Data.Listed(b, day)
		local old = a.d[day]
		if not old then
			Data.SetDay(a, day, price, bn, bq)
		else
			local an, aq = Data.Scans(a, day), Data.Listed(a, day)
			-- The same day from the same guild member's sync is in both once.
			if not (old == price and an == bn) then
				local n = an + bn
				local q = aq and bq and floor((aq * an + bq * bn) / n + 0.5) or aq or bq
				Data.SetDay(a, day, floor((old * an + price * bn) / n + 0.5), n, q)
			end
		end
		local pl, ph, ql, qh = Data.Range(b, day)
		if pl then Data.MergeRange(a, day, pl, ph, ql, qh) end
	end
	for day, gone in pairs(b.ds or {}) do
		a.ds = a.ds or {}
		a.ds[day] = (a.ds[day] or 0) + gone
	end
end

local function MergeRealm(a, b)
	for id, rec in pairs(b.items or {}) do
		if a.items[id] then MergeItem(a.items[id], rec) else a.items[id] = rec end
	end
	for _, k in ipairs({ "lastScan", "lastRequest", "syncedFull" }) do
		a[k] = math.max(a[k] or 0, b[k] or 0)
	end
	if b.vol and b.vol.cover then
		a.vol = a.vol or {}
		a.vol.cover = a.vol.cover or {}
		for day, s in pairs(b.vol.cover) do a.vol.cover[day] = (a.vol.cover[day] or 0) + s end
	end
	for k, v in pairs(b) do
		if a[k] == nil then a[k] = v end
	end
end

-- { { t, ... }, ... } logs: both, by time, b's without the ones a has too
-- (a log can hold the same entry twice: two sales in the same second).
local function MergeLog(a, b)
	if not b then return a end
	if not a then return b end
	local function Key(e)
		local parts = {}
		for i = 1, 8 do parts[i] = tostring(e[i]) end -- (entries can have gaps)
		return table.concat(parts, "\1")
	end
	local count, out = {}, {}
	for _, e in ipairs(a) do
		local k = Key(e)
		count[k] = (count[k] or 0) + 1
		out[#out + 1] = e
	end
	for _, e in ipairs(b) do
		local k = Key(e)
		if (count[k] or 0) > 0 then
			count[k] = count[k] - 1
		else
			out[#out + 1] = e
		end
	end
	table.sort(out, function(x, y) return (x[1] or 0) < (y[1] or 0) end)
	return out
end
ns.MergeLog = MergeLog

-- A character's (a) and the same character under the blank realm (b, the
-- newer: it's where everything went once the name went blank).
local function MergeChar(a, b)
	-- What's up and what's owed now: the newer side's, unless it has none.
	if b.owned and next(b.owned) then a.owned = b.owned end
	if b.sales and (#b.sales > 0 or (b.soldLog and #b.soldLog > 0)) then a.sales = b.sales end
	for id, d in pairs(b.deposits or {}) do
		a.deposits = a.deposits or {}
		a.deposits[id] = d
	end
	for _, k in ipairs({ "soldLog", "cancelLog", "volCheck" }) do
		a[k] = MergeLog(a[k], b[k])
	end
	local ga, gb = a.gold, b.gold
	if gb and gb.days then
		if not (ga and ga.days) then
			a.gold = gb
		else
			for day, v in pairs(gb.days) do ga.days[day] = v end
			if (gb.first or math.huge) < (ga.first or math.huge) then ga.first, ga.open = gb.first, gb.open end
		end
	end
	for k, v in pairs(b) do
		if a[k] == nil then a[k] = v end
	end
end

-- At load (Init.lua): anything under the blank realm goes back.
function ns.MergeBlankRealm(db)
	db.realmName = db.realmName or SavedName(db)
	local realm = db.realmName
	if not realm or realm == "" then return end
	local moved = 0
	for key, b in pairs(db.realms) do
		local side = key:match("^ %- (%a+)$")
		if side then
			local to = realm .. " - " .. side
			if db.realms[to] then MergeRealm(db.realms[to], b) else db.realms[to] = b end
			db.realms[key] = nil
			moved = moved + 1
		end
	end
	for key, b in pairs(db.chars or {}) do
		local name = key:match("^(.-) %- $")
		if name then
			local to = name .. " - " .. realm
			if db.chars[to] then MergeChar(db.chars[to], b) else db.chars[to] = b end
			db.chars[key] = nil
			moved = moved + 1
		end
	end
	for _, p in ipairs(db.archivePending or {}) do
		local name = type(p[1]) == "string" and p[1]:match("^(.-) %- $")
		if name then p[1] = name .. " - " .. realm end
	end
	return moved
end
