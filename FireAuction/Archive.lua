-- The long-term history: kept in its own addon, FireAuctionHistory (load on
-- demand: its saved file isn't read at login, only once you're at the auction
-- house or something asks for it). Your own scans only - not shared with the
-- guild. Nothing here is shown yet: it's collected for later (candlesticks,
-- time of day, what sells).
--
-- FireAuctionHistoryDB = {
--   v = 2,
--   houses = { ["Realm - Horde"/"Realm - Neutral"] = {   (as ns.Realm's keys)
--     daily = { [bucket] = { [itemID] = records } or packed } kept DAILY_KEEP days
--       one record per day, appended when the day is over; bucket =
--       floor(day / 32), day = floor(time() / 86400) (UTC, as Data.lua)
--     today = { day, items = { [itemID] = { o, h, l, c, cl, ch, qsum, ql, qh,
--       gone, n } } }  the day so far, unencoded
--     ticks = { [day] = { [itemID] = records } or packed }  kept TICK_KEEP days
--       one record per scan, for every item listed
--     cover = { [day] = seconds }  how long the day's scan pairs span (for
--       turning "gone" into a rate), kept DAILY_KEEP days
--   } },
--   chars = { ["Name - Realm"] = { { t, kind, item, qty, unit, house, extra }, ... } }
--     your own listings, kept EVENT_KEEP days. kind: "post" (extra: duration
--     in seconds), "sold" (from the mail: exact qty; unit = gross / qty),
--     "cancel", "expire". item: itemID, or the name when it isn't known.
--     house: "f" faction / "n" neutral.
--   market, attempts   Quick buy's logs (QuickBuy.lua, Ladder.lua), moved
--     here from FireAuctionDB to keep the login file small.
-- }
--
-- Records are numbers in a 64-character alphabet, 5 bits a character, low
-- digits first; a character from the upper half means more follow (Num/Read).
--   daily record: dayInBucket, o, h-o, o-l, c-l, l-cl, ch-cl, q, q-ql, qh-q,
--     gone, n
--     o/h/l/c: market price (Data.MarketPrice) of the day's first, highest,
--     lowest and last scan; cl/ch: lowest and highest cheapest buyout; q:
--     average listed, ql/qh fewest and most; gone: units gone between the
--     day's scan pairs (Volume.lua's estimate: bought or cancelled); n: scans.
--   tick record: minute of the day, market, market-cheapest, listed,
--     gone+1 (0: no scan just before to compare with)
-- (No sellers: Forever's full scan doesn't name them.)
--
-- Packed: a day's ticks once it's over, and a bucket of days once it's
-- full, are one string, ";itemID:records;itemID:records..." (Pack). The
-- game reads a saved file as Lua, which holds at most 2^18 different strings
-- and numbers; a string per item per day would pass that within months.
local _, ns = ...

local Archive = {}
ns.Archive = Archive

local ADDON = "FireAuctionHistory"
local BUCKET = 32
local DAILY_KEEP = 366
local TICK_KEEP = 90
local EVENT_KEEP = 366

---------------------------------------------------------------------------
-- Numbers <-> text
---------------------------------------------------------------------------
local ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_"
local CH, IDX = {}, {}
for i = 1, 64 do
	CH[i - 1] = ALPHABET:sub(i, i)
	IDX[ALPHABET:byte(i)] = i - 1
end

local function Num(v)
	v = math.floor((v or 0) + 0.5)
	if v < 0 then v = 0 end
	local out = {}
	while v >= 32 do
		out[#out + 1] = CH[32 + v % 32]
		v = math.floor(v / 32)
	end
	out[#out + 1] = CH[v]
	return table.concat(out)
end

-- The number at pos, and where the next one starts (nil at the end).
local function Read(s, pos)
	local v, mul = 0, 1
	while true do
		local d = IDX[s:byte(pos) or 0]
		if not d then return nil end
		pos = pos + 1
		if d >= 32 then
			v, mul = v + (d - 32) * mul, mul * 32
		else
			return v + d * mul, pos
		end
	end
end
Archive.Num, Archive.Read = Num, Read

---------------------------------------------------------------------------
-- Packed lists: { [itemID] = records } as one string
---------------------------------------------------------------------------
local function Pack(list)
	local parts = {}
	for id, s in pairs(list) do parts[#parts + 1] = ";" .. id .. ":" .. s end
	return table.concat(parts)
end

-- A list, as a table (a packed one unpacked).
local function Open(list)
	if type(list) ~= "string" then return list end
	local out = {}
	for id, s in list:gmatch(";(%d+):([^;]*)") do out[tonumber(id)] = s end
	return out
end

-- Where each item's records are in a packed list: { [id] = start, ... },
-- with [-id] = end. Worked out when first read; let go when memory is
-- collected.
local where = setmetatable({}, { __mode = "v" })
local function Where(s)
	local w = where[s]
	if not w then
		w = {}
		for id, from, to in s:gmatch(";(%d+):()[^;]*()") do
			id = tonumber(id)
			w[id], w[-id] = from, to - 1
		end
		where[s] = w
	end
	return w
end

-- An item's records in a list (table or packed), or nil.
local function Entry(list, id)
	if type(list) ~= "string" then return list and list[id] end
	local w = Where(list)
	local from = w[id]
	return from and list:sub(from, w[-id]) or nil
end

-- The items in a list (table or packed): { [id] = true }, added to out.
local function Items(list, out)
	if type(list) == "string" then
		for id in pairs(Where(list)) do
			if id > 0 then out[id] = true end
		end
	else
		for id in pairs(list or {}) do out[id] = true end
	end
	return out
end

---------------------------------------------------------------------------
-- Loading
---------------------------------------------------------------------------
local db, tried
local AddEvents, PackOld -- (further down)

-- The archive, loaded if it isn't yet; nil when FireAuctionHistory can't be
-- loaded (not installed or disabled).
function Archive.DB()
	if db or tried then return db end
	tried = true
	local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
	if not load then return nil end
	local ok, loaded, why = pcall(load, ADDON)
	if not (ok and loaded) then
		ns.Print(("price history off: %s isn't loaded (%s)."):format(ADDON, tostring(why or "error")))
		return nil
	end
	FireAuctionHistoryDB = type(FireAuctionHistoryDB) == "table" and FireAuctionHistoryDB or {}
	db = FireAuctionHistoryDB
	db.houses = db.houses or {}
	-- v1 counted sellers, which the scan doesn't give (always one): its few
	-- hours of data go.
	if (db.v or 1) < 2 then
		for _, h in pairs(db.houses) do h.today, h.ticks, h.daily = nil, {}, {} end
	end
	db.v = 2
	db.chars = db.chars or {}
	-- Quick buy's logs live here now.
	if ns.db then
		for _, key in ipairs({ "market", "attempts" }) do
			if ns.db[key] ~= nil then
				if db[key] == nil then db[key] = ns.db[key] end
				ns.db[key] = nil
			end
		end
	end
	Archive.MergeBlankRealm(db)
	local today = math.floor(time() / 86400)
	for _, h in pairs(db.houses) do PackOld(h, today) end
	AddEvents(db)
	return db
end

-- Where Quick buy's logs go: the archive, or FireAuctionDB without one.
function ns.Store()
	return Archive.DB() or ns.db
end

-- At the auction house: load it now, not in the middle of something.
ns.On("AUCTION_HOUSE_SHOW", function() Archive.DB() end)

local function HouseKey(house)
	local faction = UnitFactionGroup("player")
	if not faction then return nil end
	return ns.RealmName() .. " - " .. (house == "neutral" and "Neutral" or faction)
end

local function House(house)
	local d = Archive.DB()
	local key = d and HouseKey(house or ns.house or "faction")
	if not key then return nil end
	local h = d.houses[key]
	if not h then
		h = { daily = {}, ticks = {}, cover = {} }
		d.houses[key] = h
	end
	return h
end

---------------------------------------------------------------------------
-- Days
---------------------------------------------------------------------------
local function EncodeDay(day, r)
	local q = r.n > 0 and math.floor(r.qsum / r.n + 0.5) or 0
	return Num(day % BUCKET) .. Num(r.o) .. Num(r.h - r.o) .. Num(r.o - r.l) .. Num(r.c - r.l)
		.. Num(r.l - r.cl) .. Num(r.ch - r.cl) .. Num(q) .. Num(q - r.ql) .. Num(r.qh - q)
		.. Num(r.gone) .. Num(r.n)
end

-- The day's records, read from pos: a day table and where the next starts.
local function DecodeDay(s, pos, bucket)
	local v = {}
	for i = 1, 12 do
		v[i], pos = Read(s, pos)
		if not v[i] then return nil end
	end
	local o, l = v[2], v[2] - v[4]
	local cl, q = l - v[6], v[8]
	return {
		day = bucket * BUCKET + v[1], o = o, h = o + v[3], l = l, c = l + v[5], cl = cl, ch = cl + v[7],
		q = q, ql = q - v[9], qh = q + v[10], gone = v[11], n = v[12],
	}, pos
end

local function Prune(h, today)
	for bucket in pairs(h.daily) do
		if (bucket + 1) * BUCKET - 1 < today - DAILY_KEEP then h.daily[bucket] = nil end
	end
	for day in pairs(h.ticks) do
		if day < today - TICK_KEEP then h.ticks[day] = nil end
	end
	for day in pairs(h.cover) do
		if day < today - DAILY_KEEP then h.cover[day] = nil end
	end
end

-- The day is over: its records join the rest.
local function Flush(h)
	local t = h.today
	if not t then return end
	local bucket = math.floor(t.day / BUCKET)
	local list = Open(h.daily[bucket]) or {}
	h.daily[bucket] = list
	for id, r in pairs(t.items) do
		if r.n > 0 then list[id] = (list[id] or "") .. EncodeDay(t.day, r) end
	end
	h.today = nil
end

-- Days over and full buckets: packed (see the top). Ones still being added
-- to stay tables.
function PackOld(h, today) -- (declared at the top)
	for day, list in pairs(h.ticks or {}) do
		if type(list) == "table" and day < today then h.ticks[day] = next(list) and Pack(list) or nil end
	end
	local current = math.floor(today / BUCKET)
	for bucket, list in pairs(h.daily or {}) do
		if type(list) == "table" and bucket < current then h.daily[bucket] = next(list) and Pack(list) or nil end
	end
end

---------------------------------------------------------------------------
-- Collecting (Scan.lua, after a full scan)
---------------------------------------------------------------------------
-- gone: Volume.lua's { [itemID] = units gone } (nil when this scan had no
-- partner); gap: seconds since that partner.
function Archive.Scanned(house, gone, gap)
	local h = House(house)
	local realm = ns.Realm(house)
	if not (h and realm) then return end
	local now = time()
	local today = math.floor(now / 86400)
	if h.today and h.today.day ~= today then
		Flush(h)
		Prune(h, today)
		PackOld(h, today)
	end
	h.today = h.today or { day = today, items = {} }
	local items = h.today.items
	if gone and gap then h.cover[today] = (h.cover[today] or 0) + gap end
	local minute = math.floor((now % 86400) / 60)
	local ticks
	for id, rec in pairs(realm.items) do
		if rec.s == realm.lastScan and (rec.q or 0) > 0 then
			local market, cheapest, listed = ns.Data.Market(rec), rec.p, rec.q
			local g = gone and (gone[id] or 0)
			local r = items[id]
			if not r then
				r = { o = market, h = market, l = market, c = market, cl = cheapest, ch = cheapest,
					qsum = 0, ql = listed, qh = listed, gone = 0, n = 0 }
				items[id] = r
			end
			r.h, r.l, r.c = math.max(r.h, market), math.min(r.l, market), market
			r.cl, r.ch = math.min(r.cl, cheapest), math.max(r.ch, cheapest)
			r.qsum, r.ql, r.qh = r.qsum + listed, math.min(r.ql, listed), math.max(r.qh, listed)
			r.gone, r.n = r.gone + (g or 0), r.n + 1
			ticks = ticks or Open(h.ticks[today]) or {}
			h.ticks[today] = ticks
			ticks[id] = (ticks[id] or "") .. Num(minute) .. Num(market) .. Num(market - cheapest) .. Num(listed)
				.. Num(g and g + 1 or 0)
		end
	end
end

-- Events waiting for the archive (FireAuctionDB.archivePending: { { key,
-- event }, ... }) - kept away from the auction house, where loading it would
-- be a hitch; added when it's next loaded.
function AddEvents(d) -- (declared at the top)
	local pending = ns.db and ns.db.archivePending
	if not pending then return end
	ns.db.archivePending = nil
	local now = time()
	for _, p in ipairs(pending) do
		local list = d.chars[p[1]] or {}
		d.chars[p[1]] = list
		list[#list + 1] = p[2]
	end
	for _, list in pairs(d.chars) do
		table.sort(list, function(a, b) return a[1] < b[1] end)
		while list[1] and now - list[1][1] > EVENT_KEEP * 86400 do table.remove(list, 1) end
	end
end

-- One of your own listings: kind "post", "sold", "cancel" or "expire"
-- (see the top). item: itemID or name; t: when (default now).
function Archive.Event(kind, item, qty, unit, house, extra, t)
	local name = UnitName("player")
	if not (name and item and ns.db) then return end
	local key = name .. " - " .. ns.RealmName()
	local e = { t or time(), kind, item, qty, unit and math.floor(unit + 0.5) or nil,
		(house or ns.house) == "neutral" and "n" or "f", extra }
	ns.db.archivePending = ns.db.archivePending or {}
	table.insert(ns.db.archivePending, { key, e })
	if db or ns.atAH then
		local d = Archive.DB()
		if d then AddEvents(d) end
	end
end

---------------------------------------------------------------------------
-- A blank realm name (Realm.lua): its house and characters go back
---------------------------------------------------------------------------
-- Two records of the same day, a the earlier: one record.
local function JoinDay(a, b)
	return { o = a.o, c = b.c, h = math.max(a.h, b.h), l = math.min(a.l, b.l), cl = math.min(a.cl, b.cl),
		ch = math.max(a.ch, b.ch), qsum = a.qsum + b.qsum, ql = math.min(a.ql, b.ql), qh = math.max(a.qh, b.qh),
		gone = a.gone + b.gone, n = a.n + b.n }
end

-- An item's day records (oldest first, as they were added): one per day.
local function JoinDays(s, bucket)
	local byDay, days, pos = {}, {}, 1
	while pos <= #s do
		local r
		r, pos = DecodeDay(s, pos, bucket)
		if not r then break end
		r.qsum = r.q * r.n
		if byDay[r.day] then
			byDay[r.day] = JoinDay(byDay[r.day], r)
		else
			byDay[r.day] = r
			days[#days + 1] = r.day
		end
	end
	table.sort(days)
	local out = {}
	for i, day in ipairs(days) do out[i] = EncodeDay(day, byDay[day]) end
	return table.concat(out)
end

-- An item's scans: by time.
local function SortTicks(s)
	local list, pos = {}, 1
	while pos <= #s do
		local v = {}
		for i = 1, 5 do
			v[i], pos = Read(s, pos)
			if not v[i] then break end
		end
		if not v[5] then break end
		list[#list + 1] = v
	end
	table.sort(list, function(x, y) return x[1] < y[1] end)
	local out = {}
	for i, v in ipairs(list) do out[i] = Num(v[1]) .. Num(v[2]) .. Num(v[3]) .. Num(v[4]) .. Num(v[5]) end
	return table.concat(out)
end

-- The blank realm's house (b, the newer) into the same house (a).
local function MergeHouse(a, b)
	a.daily, a.ticks, a.cover = a.daily or {}, a.ticks or {}, a.cover or {}
	-- Both days so far: an older one is over, the same one is one day.
	local ta, tb = a.today, b.today
	if ta and tb and ta.day == tb.day then
		for id, r in pairs(tb.items) do
			ta.items[id] = ta.items[id] and JoinDay(ta.items[id], r) or r
		end
		b.today = nil
	elseif ta and tb then
		if ta.day < tb.day then Flush(a); a.today = tb else Flush(b) end
		b.today = nil
	elseif tb then
		a.today, b.today = tb, nil
	end
	-- (Packed lists are unpacked to merge; Archive.DB packs them again.)
	for bucket, items in pairs(b.daily or {}) do
		local list = a.daily[bucket]
		if not list then
			a.daily[bucket] = items
		else
			list = Open(list)
			a.daily[bucket] = list
			for id, s in pairs(Open(items)) do
				list[id] = list[id] and JoinDays(list[id] .. s, bucket) or s
			end
		end
	end
	-- A day flushed on one side that's still going on the other: one day.
	if a.today then
		local bucket = math.floor(a.today.day / BUCKET)
		local list = Open(a.daily[bucket])
		a.daily[bucket] = list
		for id, s in pairs(list or {}) do
			local kept = {}
			local pos, joined = 1, nil
			while pos <= #s do
				local r, nextPos = DecodeDay(s, pos, math.floor(a.today.day / BUCKET))
				if not r then break end
				if r.day == a.today.day then
					r.qsum = r.q * r.n
					joined = joined and JoinDay(joined, r) or r
				else
					kept[#kept + 1] = s:sub(pos, nextPos - 1)
				end
				pos = nextPos
			end
			if joined then
				local r = a.today.items[id]
				a.today.items[id] = r and JoinDay(joined, r) or joined
				list[id] = #kept > 0 and table.concat(kept) or nil
			end
		end
	end
	for day, items in pairs(b.ticks or {}) do
		local list = a.ticks[day]
		if not list then
			a.ticks[day] = items
		else
			list = Open(list)
			a.ticks[day] = list
			for id, s in pairs(Open(items)) do
				list[id] = list[id] and SortTicks(list[id] .. s) or s
			end
		end
	end
	for day, s in pairs(b.cover or {}) do a.cover[day] = (a.cover[day] or 0) + s end
end

function Archive.MergeBlankRealm(d)
	local realm = ns.RealmName()
	if realm == "" then return end
	for key, b in pairs(d.houses) do
		local side = key:match("^ %- (%a+)$")
		if side then
			local to = realm .. " - " .. side
			if d.houses[to] then MergeHouse(d.houses[to], b) else d.houses[to] = b end
			d.houses[key] = nil
		end
	end
	for key, b in pairs(d.chars) do
		local name = key:match("^(.-) %- $")
		if name then
			local to = name .. " - " .. realm
			d.chars[to] = ns.MergeLog(d.chars[to], b)
			d.chars[key] = nil
		end
	end
end
Archive.MergeHouse = MergeHouse

---------------------------------------------------------------------------
-- Reading (for whatever shows it later)
---------------------------------------------------------------------------
-- The item's days from `from` to `to` (day numbers; today's so far
-- included), oldest first: { { day, o, h, l, c, cl, ch, q, ql, qh, gone,
-- n }, ... }.
function Archive.Days(house, id, from, to)
	local h = House(house)
	local out = {}
	if not h then return out end
	for bucket = math.floor(from / BUCKET), math.floor(to / BUCKET) do
		local s = Entry(h.daily[bucket], id)
		local pos = 1
		while s and pos <= #s do
			local r
			r, pos = DecodeDay(s, pos, bucket)
			if not r then break end
			if r.day >= from and r.day <= to then out[#out + 1] = r end
		end
	end
	local t = h.today
	local r = t and t.items[id]
	if r and r.n > 0 and t.day >= from and t.day <= to then
		local q = math.floor(r.qsum / r.n + 0.5)
		out[#out + 1] = { day = t.day, o = r.o, h = r.h, l = r.l, c = r.c, cl = r.cl, ch = r.ch, q = q, ql = r.ql,
			qh = r.qh, gone = r.gone, n = r.n }
	end
	return out
end

-- The item's scans from day `from` to `to`, oldest first: { { t (time()),
-- market, cheapest, listed, gone (nil: not known) }, ... }.
function Archive.Ticks(house, id, from, to)
	local h = House(house)
	local out = {}
	if not h then return out end
	for day = from, to do
		local s = Entry(h.ticks[day], id)
		local pos = 1
		while s and pos <= #s do
			local v = {}
			for i = 1, 5 do
				v[i], pos = Read(s, pos)
				if not v[i] then break end
			end
			if not v[5] then break end
			out[#out + 1] = { t = day * 86400 + v[1] * 60, market = v[2], cheapest = v[2] - v[3], listed = v[4],
				gone = v[5] > 0 and v[5] - 1 or nil }
		end
	end
	return out
end

-- The items with scans from day `from` to `to`: { [itemID] = true }.
function Archive.TickItems(house, from, to)
	local h = House(house)
	local out = {}
	if not h then return out end
	for day = from, to do Items(h.ticks[day], out) end
	return out
end

-- Whether the archive is loaded (Archive.DB loads it).
function Archive.Loaded()
	return db ~= nil
end

-- Seconds the day's scan pairs span (Volume.lua's "gone" covers that long).
function Archive.Cover(house, day)
	local h = House(house)
	return h and h.cover[day] or 0
end
