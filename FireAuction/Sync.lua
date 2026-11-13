-- Guild price sharing: everyone in your guild with FireAuction shares their
-- scans, so one person's scan updates everybody's prices and history.
--
-- It only uses the game's addon messages on the guild channel (invisible to
-- players), sent no faster than about one a second - well inside what the
-- game allows - and paused whenever the game says to wait (boss fights).
--
-- How it works
--   * After you scan, the new prices go out to the guild ("push").
--   * A little after you log in, you send a summary for each auction house
--     ("hello"): when your newest scan is from, and how many prices you have
--     for each day. Members whose data differs answer with theirs ("offer").
--     You ask whoever has what you're missing to send it ("go"), and send
--     what they're missing yourself.
--   * Per item the newest scan wins; history days fill in where you have none.
--   * A push or reply that arrives complete also marks items as not listed
--     when they weren't in that scan, like your own full scans do.
--
-- Messages (prefix "FireAH") start with their kind and the protocol version,
-- then the sender's session id (3 characters, random per session). Numbers
-- are variable-length: 5 bits per character, with a "more follows" flag, in a
-- 64-character alphabet of letters, digits, "-" and "_". History prices are
-- 2 characters each, on a log scale (within about 0.3% of the real price).
--   H realm house summary                    hello
--   O realm house target summary             offer, answering a hello
--   G realm house target since+1 days        go: send me these
--   B realm house stream T base flags days   a stream begins
--   D stream seq records...                  stream data (each message stands alone)
--   E stream messages records                the stream is over
-- summary = newest-scan today K count*K (prices per day, the last K days)
-- record  = id-gap mask [price qty age market] dayprice...
--   (mask bit 1: the latest prices follow - lowest, how many, how old, and the
--   market price; bit j+1: a price for the stream's day j - the day's market
--   price)
--
-- Version 2 added the market price. Versions don't mix: messages from another
-- version are ignored, and you're told once (per member) that someone needs
-- to update.
local _, ns = ...

local Sync = {}
ns.Sync = Sync

local PREFIX = "FireAH"
local VERSION = 2
local MAX_LEN = 250      -- characters per message (the game allows 255)
local MAX_DAYS = 60      -- days of history compared and shared
local HELLO_DELAY = 12   -- seconds after logging in
local OFFER_WAIT = 6     -- how long a hello collects offers
local LATE_OFFERS = 120  -- ...and answers late ones until
local RATE = 1           -- messages per second, sustained
local BURST = 4          -- ...after a quiet spell
local RETRY = 5          -- seconds to wait when the game won't send yet
local STALE = 180        -- an incoming stream silent this long is over
local LOG = true         -- for now: say in chat when a sync finishes

local HOUSES = { "faction", "neutral" }
local HOUSE_CHAR = { faction = "F", neutral = "N" }
local CHAR_HOUSE = { F = "faction", N = "neutral" }

local floor, byte = math.floor, string.byte

local function Log(msg)
	if LOG then ns.Print("|cff80c0ffsync:|r " .. msg) end
end

---------------------------------------------------------------------------
-- Encoding
---------------------------------------------------------------------------
local ALPHA = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_"
local ENC, DEC = {}, {}
for i = 1, 64 do
	local c = ALPHA:sub(i, i)
	ENC[i - 1] = c
	DEC[byte(c)] = i - 1
end

-- A non-negative whole number.
local function Num(n)
	n = floor(n or 0)
	if n < 0 then n = 0 end
	local out = ""
	while n >= 32 do
		local r = n % 32
		out = out .. ENC[32 + r]
		n = (n - r) / 32
	end
	return out .. ENC[n]
end

-- k on/off flags, 6 per character.
local function Bits(flags, k)
	local out = {}
	for i = 1, k, 6 do
		local v = 0
		for j = 0, 5 do
			if i + j <= k and flags[i + j] then v = v + 2 ^ j end
		end
		out[#out + 1] = ENC[v]
	end
	return table.concat(out)
end

-- A price in 12 bits on a log scale: 1 copper to 2^32.
local LOG_STEP = math.log(2 ^ 32) / 4095
local function Price12(p)
	local code = (p and p > 1) and floor(math.log(p) / LOG_STEP + 0.5) or 0
	if code > 4095 then code = 4095 end
	return ENC[floor(code / 64)] .. ENC[code % 64]
end

-- Sorted list of days -> first, span, flags.
local function DaysText(days)
	if #days == 0 then return Num(0) .. Num(0) end
	local first = days[1]
	local span = days[#days] - first + 1
	local flags = {}
	for _, d in ipairs(days) do flags[d - first + 1] = true end
	return Num(first) .. Num(span) .. Bits(flags, span)
end

local Reader = {}
Reader.__index = Reader

local function NewReader(text, pos)
	return setmetatable({ s = text, i = pos or 1 }, Reader)
end

function Reader:Done() return self.i > #self.s end

function Reader:Take(n)
	local part = self.s:sub(self.i, self.i + n - 1)
	if #part < n then error("short message") end
	self.i = self.i + n
	return part
end

function Reader:Digit()
	local v = DEC[byte(self.s, self.i) or 0]
	if not v then error("bad character") end
	self.i = self.i + 1
	return v
end

function Reader:Num()
	local n, mult = 0, 1
	for _ = 1, 11 do
		local v = self:Digit()
		if v < 32 then return n + v * mult end
		n = n + (v - 32) * mult
		mult = mult * 32
	end
	error("number too long")
end

function Reader:Bits(k)
	local flags = {}
	for i = 1, k, 6 do
		local v = self:Digit()
		for j = 0, 5 do
			if i + j <= k then flags[i + j] = v % 2 == 1 end
			v = floor(v / 2)
		end
	end
	return flags
end

function Reader:Price12()
	local code = self:Digit() * 64 + self:Digit()
	return floor(math.exp(code * LOG_STEP) + 0.5)
end

function Reader:Days()
	local first, span = self:Num(), self:Num()
	if span > 2 * MAX_DAYS then error("too many days") end
	local flags = self:Bits(span)
	local days = {}
	for i = 1, span do
		if flags[i] then days[#days + 1] = first + i - 1 end
	end
	return days
end

---------------------------------------------------------------------------
-- Who we are
---------------------------------------------------------------------------
local node = ENC[math.random(0, 63)] .. ENC[math.random(0, 63)] .. ENC[math.random(0, 63)]

local function RealmTag()
	local name = GetRealmName() or "?"
	local h = 0
	for i = 1, #name do h = (h * 31 + byte(name, i)) % 4096 end
	return ENC[floor(h / 64)] .. ENC[h % 64]
end

local function IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) and true or false end

local function ShortName(sender)
	if Ambiguate then
		local ok, name = pcall(Ambiguate, sender, "none")
		if ok and name then return name end
	end
	return sender
end

---------------------------------------------------------------------------
-- Our data
---------------------------------------------------------------------------
local function Today() return ns.Data.Today() end

-- The newest complete scan we have, ours or a guild member's.
local function Full(realm) return (ns.LastScan(realm)) end

local function WindowDays() return math.min(ns.db.historyDays or 30, MAX_DAYS) end

-- { full, today, k, counts = { [day] = prices that day } }
local function Summary(house)
	local realm = ns.Realm(house)
	if not realm then return nil end
	local today, k = Today(), WindowDays()
	local from = today - k + 1
	local counts = {}
	for _, rec in pairs(realm.items) do
		for day in pairs(rec.d) do
			if day >= from and day <= today then counts[day] = (counts[day] or 0) + 1 end
		end
	end
	return { full = Full(realm), today = today, k = k, counts = counts }
end

local function SummaryText(kind, house, sum, target)
	local parts = { kind, ENC[VERSION], node, RealmTag(), HOUSE_CHAR[house], target or "",
		Num(sum.full), Num(sum.today), Num(sum.k) }
	for i = 0, sum.k - 1 do
		parts[#parts + 1] = Num(sum.counts[sum.today - sum.k + 1 + i] or 0)
	end
	return table.concat(parts)
end

local function ReadSummary(r)
	local sum = { full = r:Num(), today = r:Num(), k = r:Num(), counts = {} }
	if sum.k > MAX_DAYS then error("too many days") end
	for i = 0, sum.k - 1 do
		local c = r:Num()
		if c > 0 then sum.counts[sum.today - sum.k + 1 + i] = c end
	end
	return sum
end

-- The days both summaries cover, oldest first.
local function SharedDays(a, b)
	local from = math.max(a.today - a.k, b.today - b.k) + 1
	local to = math.min(a.today, b.today)
	local days = {}
	for d = from, to do days[#days + 1] = d end
	return days
end

local function Differs(mine, theirs)
	if mine.full ~= theirs.full then return true end
	for _, d in ipairs(SharedDays(mine, theirs)) do
		if (mine.counts[d] or 0) ~= (theirs.counts[d] or 0) then return true end
	end
	return false
end

local refreshPending = false
local function DataChanged()
	if refreshPending then return end
	refreshPending = true
	C_Timer.After(2, function()
		refreshPending = false
		if ns.Window then ns.SafeCall(ns.Window.Refresh) end
		if ns.BagIcons then ns.SafeCall(ns.BagIcons.Refresh) end
		if ns.Crafting then ns.SafeCall(ns.Crafting.Refresh) end
	end)
end

---------------------------------------------------------------------------
-- Sending: small messages first, then streams one at a time, paced.
---------------------------------------------------------------------------
local control, streams = {}, {}
local tokens, waitUntil = BURST, 0
local pump = CreateFrame("Frame")
pump:Hide()

local RESULT_RETRY = { [3] = true, [8] = true, [9] = true, [11] = true } -- throttled, busy, lockdown

-- "sent", "retry", "drop" (this message) or "stop" (not in a guild)
local function SendNow(text)
	local send = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
	if not send then return "stop" end
	local ok, result = pcall(send, PREFIX, text, "GUILD")
	if not ok then return "drop" end
	if result == nil or result == true or result == 0 then return "sent" end
	if RESULT_RETRY[result] then return "retry" end
	if result == 10 then return "stop" end
	ns.Debug("sync: message not sent (" .. tostring(result) .. ")")
	return "drop"
end

local function Queue(text)
	control[#control + 1] = text
	pump:Show()
end

local streamCount = 0

local function QueueStream(house, since, days, why)
	-- A reply not started yet can take this one in too.
	for i = 2, #streams do
		local s = streams[i]
		if s.house == house and not s.begun then
			if since and (not s.since or since < s.since) then s.since = since end
			local set = {}
			for _, d in ipairs(s.days) do set[d] = true end
			for _, d in ipairs(days) do
				if not set[d] then s.days[#s.days + 1] = d end
			end
			table.sort(s.days)
			return
		end
	end
	streamCount = (streamCount + 1) % 64
	local s = {
		house = house, since = since, days = days, why = why,
		sid = ENC[streamCount], seq = 0, records = 0, latest = 0, dayPrices = 0,
	}
	-- A fresh scan goes next, not behind a long catch-up.
	local at = #streams + 1
	if why == "scan" then
		at = (streams[1] and streams[1].begun) and 2 or 1
		if at > #streams + 1 then at = #streams + 1 end
	end
	table.insert(streams, at, s)
	pump:Show()
end

-- Picks the items to send, when the stream reaches the front.
local function Prepare(s)
	local realm = ns.Realm(s.house)
	s.T = realm and Full(realm) or 0
	s.complete = s.since ~= nil and s.since < s.T
	s.base = s.T
	s.ids = {}
	if not realm then return end
	for id, rec in pairs(realm.items) do
		local include = s.since and rec.s and rec.s > s.since and rec.p
		if not include then
			for _, day in ipairs(s.days) do
				if rec.d[day] then include = true break end
			end
		end
		if include then
			s.ids[#s.ids + 1] = id
			if rec.s and rec.s > s.base and s.since and rec.s > s.since then s.base = rec.s end
		end
	end
	table.sort(s.ids)
	s.cursor = 1
	s.started = GetTime()
end

local function RecordText(s, rec, gap)
	local latest = s.since and rec.s and rec.s > s.since and rec.p
	local flags = { latest and true or false }
	local prices = {}
	for j, day in ipairs(s.days) do
		local p = rec.d[day]
		if p then
			flags[j + 1] = true
			prices[#prices + 1] = Price12(p)
		end
	end
	if not latest and #prices == 0 then return nil end
	local out = Num(gap) .. Bits(flags, #s.days + 1)
	if latest then out = out .. Num(rec.p) .. Num(rec.q or 0) .. Num(s.base - rec.s) .. Num(rec.m or rec.p) end
	return out .. table.concat(prices), latest, #prices
end

local function NextStreamMessage(s)
	if not s.begun then
		s.begun = true
		Prepare(s)
		if #s.ids == 0 then return nil end -- nothing to send after all
		return table.concat({ "B", ENC[VERSION], node, RealmTag(), HOUSE_CHAR[s.house], s.sid,
			Num(s.T), Num(s.base), Num(s.complete and 1 or 0), DaysText(s.days) })
	end
	local realm = ns.Realm(s.house)
	if realm and s.cursor <= #s.ids then
		local head = "D" .. ENC[VERSION] .. node .. s.sid .. Num(s.seq)
		local parts, len, prev = { head }, #head, 0
		while s.cursor <= #s.ids do
			local id = s.ids[s.cursor]
			local rec = realm.items[id]
			local text, latest, n
			if rec then text, latest, n = RecordText(s, rec, id - prev) end
			if text then
				if len + #text > MAX_LEN and #parts > 1 then break end
				parts[#parts + 1] = text
				len = len + #text
				prev = id
				s.records = s.records + 1
				if latest then s.latest = s.latest + 1 end
				s.dayPrices = s.dayPrices + n
			end
			s.cursor = s.cursor + 1
		end
		if #parts > 1 then
			s.seq = s.seq + 1
			return table.concat(parts)
		end
	end
	if not s.ended then
		s.ended = true
		return "E" .. ENC[VERSION] .. node .. s.sid .. Num(s.seq) .. Num(s.records)
	end
	return nil
end

local function StreamFinished(s)
	if s.records == 0 then return end
	local what = {}
	if s.latest > 0 then what[#what + 1] = s.latest .. " prices" end
	if s.dayPrices > 0 then
		what[#what + 1] = ("%d history prices over %d day%s"):format(s.dayPrices, #s.days, #s.days == 1 and "" or "s")
	end
	Log(("sent %s (%s auction house) to your guild in %ds."):format(table.concat(what, " and "),
		ns.HouseName(s.house), floor(GetTime() - (s.started or GetTime()) + 0.5)))
end

local function Pump()
	if GetTime() < waitUntil or tokens < 1 then return end
	local text, stream
	if control[1] then
		text = control[1]
	else
		stream = streams[1]
		if not stream then
			if tokens >= BURST then pump:Hide() end
			return
		end
		if not stream.pending then
			stream.pending = NextStreamMessage(stream)
			if not stream.pending then
				table.remove(streams, 1)
				StreamFinished(stream)
				return
			end
		end
		text = stream.pending
	end
	local result = SendNow(text)
	if result == "retry" then
		waitUntil = GetTime() + RETRY
		return
	end
	tokens = tokens - 1
	if result == "stop" then
		wipe(control)
		wipe(streams)
		return
	end
	if stream then stream.pending = nil else table.remove(control, 1) end
end

pump:SetScript("OnUpdate", function(_, elapsed)
	tokens = math.min(BURST, tokens + elapsed * RATE)
	local ok, err = pcall(Pump)
	if not ok then
		ns.ReportError(err)
		wipe(control)
		wipe(streams)
	end
end)

---------------------------------------------------------------------------
-- Receiving streams
---------------------------------------------------------------------------
local incoming = {} -- ["node:sid"] = state

local lastRetryHello = -math.huge

local function EndIncoming(key, st, reason)
	incoming[key] = nil
	-- Parts went missing: ask again in a little while (not too often).
	if reason and GetTime() - lastRetryHello > 300 then
		lastRetryHello = GetTime()
		C_Timer.After(20, function() Sync.Hello() end)
	end
	local realm = ns.Realm(st.house)
	if realm and (st.added + st.updated + st.filled + st.gone > 0 or st.newerScan) then
		ns.Data.Prune(st.house)
		DataChanged()
	end
	local what = {}
	if st.updated > 0 then what[#what + 1] = st.updated .. " newer prices" end
	if st.added > 0 then what[#what + 1] = st.added .. " new items" end
	if st.filled > 0 then what[#what + 1] = st.filled .. " history prices" end
	if st.gone > 0 then what[#what + 1] = st.gone .. " no longer listed" end
	local got = #what > 0 and table.concat(what, ", ") or "nothing new"
	Log(("from %s (%s auction house): %s, in %ds%s."):format(st.from, ns.HouseName(st.house), got,
		floor(GetTime() - st.started + 0.5), reason and (" - " .. reason) or ""))
end

local function OnBegin(r, from, sender)
	if r:Take(2) ~= RealmTag() then return end
	local house = CHAR_HOUSE[r:Take(1)]
	if not house then return end
	local sid = r:Take(1)
	local T, base, flags = r:Num(), r:Num(), r:Num()
	local days = r:Days()
	local key = from .. ":" .. sid
	if incoming[key] then EndIncoming(key, incoming[key], "cut short") end
	local set = {}
	local today = Today()
	for _, d in ipairs(days) do set[d] = d <= today + 1 end
	incoming[key] = {
		house = house, T = T, base = base, complete = flags % 2 == 1, days = days, okDay = set,
		from = ShortName(sender), expected = 0, inOrder = true, messages = 0, seen = {},
		started = GetTime(), last = GetTime(),
		added = 0, updated = 0, filled = 0, gone = 0,
	}
end

local function Merge(st, realm, id, p, q, s, m, dayPrices)
	local today = Today()
	local rec = realm.items[id]
	local new = rec == nil
	if new then rec = { d = {} } end
	if p then
		st.seen[id] = true
		if not rec.s or s > rec.s then
			rec.p, rec.m, rec.q, rec.s, rec.l = p, m, q, s, nil
			if not new then st.updated = st.updated + 1 end
		end
	end
	local oldest = today - (ns.db.historyDays or 30)
	for day, price in pairs(dayPrices) do
		if not rec.d[day] and day >= oldest and st.okDay[day] then
			rec.d[day] = price
			if day == today and rec.td ~= today then rec.td, rec.n = today, 1 end
			st.filled = st.filled + 1
		end
	end
	if new then
		if not rec.p then
			-- History without a latest price: the newest day stands in for it.
			local newest
			for day in pairs(rec.d) do
				if not newest or day > newest then newest = day end
			end
			if not newest then return end
			rec.p, rec.q, rec.s = rec.d[newest], 0, 0
		end
		if not next(rec.d) then rec.d[floor(rec.s / 86400)] = rec.p end
		realm.items[id] = rec
		st.added = st.added + 1
	end
end

local function OnData(r, from)
	local sid = r:Take(1)
	local key = from .. ":" .. sid
	local st = incoming[key]
	if not st then return end -- we missed the start
	local seq = r:Num()
	if seq ~= st.expected then st.inOrder = false end
	st.expected = seq + 1
	st.messages = st.messages + 1
	st.last = GetTime()
	local realm = ns.Realm(st.house)
	if not realm then return end
	local now = time()
	local prev = 0
	local ok, err = pcall(function()
		while not r:Done() do
			local id = prev + r:Num()
			prev = id
			local flags = r:Bits(#st.days + 1)
			local p, q, s, m
			if flags[1] then
				p, q = r:Num(), r:Num()
				s = st.base - r:Num()
				m = r:Num()
			end
			local dayPrices = {}
			for j, day in ipairs(st.days) do
				if flags[j + 1] then dayPrices[day] = r:Price12() end
			end
			-- Sanity: skip anything that can't be a real price.
			local sane = id > 0 and id < 10000000
				and (not p or (p > 0 and p < 1e11 and q < 1e7 and s <= now + 86400 and s > now - 200 * 86400
					and m >= p and m < 1e11))
			if sane then Merge(st, realm, id, p, q, s, m, dayPrices) end
		end
	end)
	if not ok then
		st.inOrder = false
		ns.Debug("sync: bad message from " .. st.from .. ": " .. tostring(err))
	end
end

local function OnEnd(r, from)
	local sid = r:Take(1)
	local key = from .. ":" .. sid
	local st = incoming[key]
	if not st then return end
	local messages = r:Num()
	r:Num() -- records
	local whole = st.inOrder and messages == st.messages
	if whole and st.complete then
		-- A complete scan: what wasn't in it isn't listed any more.
		local realm = ns.Realm(st.house)
		if realm then
			for id, rec in pairs(realm.items) do
				if not st.seen[id] and rec.s and rec.s < st.T and (rec.q or 0) > 0 then
					rec.q, rec.l = 0, nil
					st.gone = st.gone + 1
				end
			end
			if st.T > (realm.syncedFull or 0) then
				realm.syncedFull = st.T
				st.newerScan = true -- the "last scan" shown changes, even if no price did
			end
		end
	end
	EndIncoming(key, st, not whole and ("missed %d of %d messages"):format(messages - st.messages, messages) or nil)
end

C_Timer.NewTicker(30, function()
	local now = GetTime()
	for key, st in pairs(incoming) do
		if now - st.last > STALE then EndIncoming(key, st, "it stopped") end
	end
end)

---------------------------------------------------------------------------
-- Hello, offers and requests
---------------------------------------------------------------------------
-- After a hello, offers are collected for OFFER_WAIT seconds and answered
-- together; ones that come later (someone was in a boss fight) are still
-- answered one by one until LATE_OFFERS.
local waiting = nil -- [house] = { [node] = summary }, while a hello collects offers
local helloAt = nil

local function Decide(offers)
	for house, list in pairs(offers) do
		local mine = Summary(house)
		if mine and next(list) then
			-- Pull: the newest scan from whoever has it, and each day from
			-- whoever has the most prices for it.
			local want = {}
			local bestFull, bestNode = mine.full, nil
			for n, o in pairs(list) do
				if o.full > bestFull then bestFull, bestNode = o.full, n end
			end
			if bestNode then want[bestNode] = { since = mine.full, days = {} } end
			local pushDays, minFull = {}, mine.full
			for d = mine.today - mine.k + 1, mine.today do
				local have = mine.counts[d] or 0
				local best, bestN, behind = have, nil, false
				for n, o in pairs(list) do
					if d > o.today - o.k and d <= o.today then
						local c = o.counts[d] or 0
						if c > best then best, bestN = c, n end
						if c < have then behind = true end
					end
				end
				if bestN then
					want[bestN] = want[bestN] or { days = {} }
					table.insert(want[bestN].days, d)
				end
				if behind then pushDays[#pushDays + 1] = d end
			end
			for n, req in pairs(want) do
				Queue(table.concat({ "G", ENC[VERSION], node, RealmTag(), HOUSE_CHAR[house], n,
					Num(req.since and req.since + 1 or 0), DaysText(req.days) }))
			end
			-- Push: what they're missing that we have.
			for _, o in pairs(list) do
				if o.full < minFull then minFull = o.full end
			end
			local since = minFull < mine.full and minFull or nil
			if since or #pushDays > 0 then QueueStream(house, since, pushDays, "hello") end
		end
	end
end

function Sync.Hello()
	if not (ns.db and IsInGuild and IsInGuild()) then return false end
	local offers = {}
	waiting, helloAt = offers, GetTime()
	for _, house in ipairs(HOUSES) do
		local sum = Summary(house)
		if sum then
			Queue(SummaryText("H", house, sum))
			offers[house] = {}
		end
	end
	C_Timer.After(OFFER_WAIT, function()
		if waiting == offers then waiting = nil end
		Decide(offers)
	end)
	return true
end

local function OnHello(r, from)
	if r:Take(2) ~= RealmTag() then return end
	local house = CHAR_HOUSE[r:Take(1)]
	if not house then return end
	local theirs = ReadSummary(r)
	local mine = Summary(house)
	if not (mine and Differs(mine, theirs)) then return end
	-- Answer after a moment, so a whole guild doesn't answer at once.
	C_Timer.After(0.3 + math.random() * 2.5, function()
		local now = Summary(house)
		if now then Queue(SummaryText("O", house, now, from)) end
	end)
end

local function OnOffer(r, from)
	if r:Take(2) ~= RealmTag() then return end
	local house = CHAR_HOUSE[r:Take(1)]
	if not house or r:Take(3) ~= node then return end
	local sum = ReadSummary(r)
	if waiting and waiting[house] then
		waiting[house][from] = sum
	elseif helloAt and GetTime() - helloAt < LATE_OFFERS then
		Decide({ [house] = { [from] = sum } })
	end
end

local function OnGo(r, from)
	if r:Take(2) ~= RealmTag() then return end
	local house = CHAR_HOUSE[r:Take(1)]
	if not house or r:Take(3) ~= node then return end
	local since = r:Num()
	local days = r:Days()
	QueueStream(house, since > 0 and since - 1 or nil, days, "request")
end

local HANDLERS = { H = OnHello, O = OnOffer, G = OnGo, B = OnBegin, D = OnData, E = OnEnd }

-- Someone on another version: say so once per member, so it's clear why
-- prices aren't coming from (or going to) them.
local toldVersion = {}
local function OtherVersion(version, sender)
	local name = ShortName(sender or "?")
	if toldVersion[name] then return end
	toldVersion[name] = true
	if version > VERSION then
		ns.Print(("%s has a newer FireAuction - update to sync with them."):format(name))
	else
		ns.Print(("%s has an older FireAuction - no syncing until they update."):format(name))
	end
end

local function OnMessage(prefix, text, channel, sender)
	if prefix ~= PREFIX or channel ~= "GUILD" then return end
	if IsSecret(text) or IsSecret(sender) or type(text) ~= "string" or #text < 5 then return end
	local handler = HANDLERS[text:sub(1, 1)]
	if not handler then return end
	local version = DEC[byte(text, 2)]
	if version ~= VERSION then
		if version and text:sub(3, 5) ~= node then OtherVersion(version, sender) end
		return
	end
	local from = text:sub(3, 5)
	if from == node then return end -- our own, echoed back
	if not ns.db then return end
	local ok, err = pcall(handler, NewReader(text, 6), from, sender or "?")
	if not ok then ns.Debug("sync: couldn't read a message: " .. tostring(err)) end
end

-- After your own scan: send it to the guild.
function Sync.ScanDone(house)
	if not (IsInGuild and IsInGuild()) then return end
	local realm = ns.Realm(house)
	if not realm or (realm.lastScan or 0) == 0 then return end
	QueueStream(house, realm.lastScan - 1, { Today() }, "scan")
end

function Sync.Status()
	local n = 0
	for _ in pairs(incoming) do n = n + 1 end
	return ("sync: session %s, %s, %d messages and %d streams queued, %d coming in"):format(node,
		(IsInGuild and IsInGuild()) and "in a guild" or "not in a guild", #control, #streams, n)
end

-- /fah sync: compare with the guild now.
function Sync.Now()
	if Sync.Hello() then
		Log("asking your guild for newer prices...")
	else
		ns.Print("you're not in a guild.")
	end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local helloDone = false
local function HelloSoon(delay)
	C_Timer.After(delay, function()
		if not helloDone and Sync.Hello() then helloDone = true end
	end)
end

do
	local register = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
	if register then pcall(register, PREFIX) end
end

ns.On("CHAT_MSG_ADDON", OnMessage)
ns.On("PLAYER_LOGIN", function() HelloSoon(HELLO_DELAY) end)
-- Joined a guild (or the guild info came late).
ns.On("PLAYER_GUILD_UPDATE", function()
	if not helloDone and IsInGuild and IsInGuild() then HelloSoon(3) end
end)
