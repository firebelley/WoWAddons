-- Your group's quest areas on your minimap: the area of the quest each group
-- member is following (the one the game points them to), shaded in their
-- class color, even if you don't have it. Quests you're on yourself are left
-- out (you have them). Hover one to see whose quest it is. They see yours
-- the same way. One switch in the options turns it off both ways.
--
-- Finding an area: the game can't tell an addon a quest area's shape, so a
-- hidden quest-area frame (the kind the world map draws them with) is set to
-- your zone and given the quest; asking it what quest is under a spot tells
-- whether the spot is inside. A coarse pass over the whole map finds where
-- the area is; then each row across it (up to 120 rows, at least 3 yards
-- tall) is sampled, and each edge found exactly by halving. It runs a few
-- milliseconds a frame, after your quest or zone changes, and only while
-- you're grouped.
--
-- Sending: the whole set each time it changes (addon messages, own prefix):
-- B(egin), per quest Q (what it is) and D (its rows, in parts), E(nd). Each
-- row is sent as the spans inside it, each end as two characters.
-- Anyone joining says H(ello) and the others send theirs again.
local _, ns = ...

local Quests = {}
ns.Quests = Quests

local PREFIX = "FireWPQ"
local COARSE = 64      -- cells across the map in the first pass
local SAMPLES = 64     -- spots tried across each row, before finding its edges
local MAX_ROWS = 120
local ROW_YARDS = 3    -- rows at least this tall
local EDGE_STEPS = 10  -- halvings to find an edge
local SPAN = 4095      -- a span's ends in 1/4095ths of the area's width (two characters)
local BUDGET = 3       -- milliseconds a frame for looking
local DELAY = 1.5      -- seconds after a change before looking again
local CHUNK = 200      -- row characters per message
local MAX_TITLE = 80
local RETRY = 1        -- seconds before trying a message the game wouldn't send again
local MAX_RETRIES = 60
local ALPHA = 0.3      -- of the shading
local MIN_PIXELS = 2   -- thinnest a drawn row may be on screen
local SPOT_YARDS = 40  -- radius of the circle for a quest with no area, just an icon
local SPOT_TEXTURE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local INTERVAL = 0.05

local YOU = "\1you"    -- owner of your own quests in test mode (/fwp test)
local floor, ceil, max, min, sqrt = math.floor, math.ceil, math.max, math.min, math.sqrt

local shared = {}      -- [owner] = { [questID] = quest (see Decode) }
Quests.shared = shared
local test = false

function Quests.On() return ns.db ~= nil and ns.db.quests ~= false end

local function Owner(owner) return owner ~= YOU and owner or nil end -- (nil: yours, to ns.OwnerColor)

---------------------------------------------------------------------------
-- A quest area as text
---------------------------------------------------------------------------

-- Two characters per number (0-4095), all safe in addon messages.
local CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local VALUE = {}
for i = 1, #CHARS do VALUE[CHARS:sub(i, i)] = i - 1 end
local function Chars(n)
	local hi, lo = floor(n / 64), n % 64
	return CHARS:sub(hi + 1, hi + 1) .. CHARS:sub(lo + 1, lo + 1)
end
local function Number(s, i)
	local hi, lo = VALUE[s:sub(i, i)], VALUE[s:sub(i + 1, i + 1)]
	return hi and lo and hi * 64 + lo
end

-- A quest as sent (id, map, x0, y0, x1, y1 in 1/10000ths of the map, rows,
-- title, data) into what the minimap draws: its box on the map, the height
-- of a row, and the spans inside each row as map positions (runs, and
-- byRow[r] = { from, to, from, to... }). rows 0: no area, just a spot (x0, y0).
-- nil if it doesn't make sense.
local function Decode(q)
	local id, map, rows = q.id, q.map, q.rows
	if not (id and map and rows) or rows > MAX_ROWS then return nil end
	for _, k in ipairs({ "x0", "y0", "x1", "y1" }) do
		if not q[k] or q[k] < 0 or q[k] > 10000 then return nil end
	end
	local quest = { id = id, map = map, title = q.title ~= "" and q.title or nil,
		x0 = q.x0 / 10000, y0 = q.y0 / 10000, x1 = q.x1 / 10000, y1 = q.y1 / 10000 }
	if rows == 0 then
		quest.point = true
		return quest
	end
	if quest.x1 <= quest.x0 or quest.y1 <= quest.y0 then return nil end
	quest.rows, quest.ch = rows, (quest.y1 - quest.y0) / rows
	local width = quest.x1 - quest.x0
	local runs, byRow, r = {}, {}, 0
	for row in ((q.data or "") .. "."):gmatch("([^%.]*)%.") do
		if r >= rows then break end
		for i = 1, #row - 3, 4 do
			local a, b = Number(row, i), Number(row, i + 2)
			if a and b and b > a and b <= SPAN then
				local ua, ub = quest.x0 + width * a / SPAN, quest.x0 + width * b / SPAN
				runs[#runs + 1] = { r, ua, ub }
				local list = byRow[r] or {}
				byRow[r] = list
				list[#list + 1] = ua
				list[#list + 1] = ub
			end
		end
		r = r + 1
	end
	if #runs == 0 then return nil end
	quest.runs, quest.byRow = runs, byRow
	return quest
end

---------------------------------------------------------------------------
-- What to look at
---------------------------------------------------------------------------

-- Your zone's map (not a city district, cave or building inside it).
local function ZoneMap()
	if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
	local map = C_Map.GetBestMapForUnit("player")
	if not map or ns.IsSecret(map) then return nil end
	local zone = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
	local m = map
	for _ = 1, 6 do
		local info = C_Map.GetMapInfo(m)
		if not info or not info.mapType then break end
		if info.mapType == zone then return m end
		if info.mapType < zone then break end -- a continent: no zone above
		m = info.parentMapID
		if not m or m == 0 then break end
	end
	return map
end

-- The quest you're following (the one the game points you to), if any.
local function Focused()
	if not (C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID) then return nil end
	local ok, id = pcall(C_SuperTrack.GetSuperTrackedQuestID)
	if not ok or not id or ns.IsSecret(id) or id <= 0 then return nil end
	return id
end

local function Title(id)
	local t = C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(id)
	if not t or ns.IsSecret(t) then return "" end
	return (t:gsub("[\t|]", " ")):sub(1, MAX_TITLE)
end

local function Done(id)
	local QL = C_QuestLog
	if QL and QL.ReadyForTurnIn and QL.ReadyForTurnIn(id) then return true end
	return QL and QL.IsComplete and QL.IsComplete(id) or false
end

-- Where each quest's icon is on the map: [questID] = { x, y }.
local function Icons(map)
	local icons = {}
	local ok, list = pcall(C_QuestLog.GetQuestsOnMap, map)
	if ok and type(list) == "table" then
		for _, q in ipairs(list) do
			if q.questID and q.x and q.y then icons[q.questID] = { q.x, q.y } end
		end
	end
	return icons
end

---------------------------------------------------------------------------
-- Looking (in a coroutine, a few milliseconds a frame)
---------------------------------------------------------------------------

local probe -- the hidden quest-area frame (false: this client can't make one)
local function Probe()
	if probe ~= nil then return probe or nil end
	local ok, f = pcall(CreateFrame, "QuestPOIFrame", nil, UIParent)
	if not (ok and f and f.DrawBlob and f.UpdateMouseOverTooltip and f.SetMapID) then
		probe = false
		return nil
	end
	f:SetSize(256, 256)
	f:SetPoint("CENTER")
	f:SetFrameStrata("BACKGROUND")
	f:SetAlpha(0)
	f:EnableMouse(false)
	pcall(f.SetFillAlpha, f, 0)
	pcall(f.SetBorderAlpha, f, 0)
	f:Show()
	probe = f
	return f
end

local deadline, tests = 0, 0
local function Inside(f, id, x, y)
	local ok, hit = pcall(f.UpdateMouseOverTooltip, f, x, y)
	tests = tests + 1
	if tests % 32 == 0 and debugprofilestop() > deadline then coroutine.yield() end
	return ok and hit == id
end

local function Round(v) return floor(v * 10000 + 0.5) end

-- One quest's area on the map, as sent (see Decode), or nil if it has none.
local function Look(f, id, icon, width, height)
	pcall(f.DrawNone, f)
	if not pcall(f.DrawBlob, f, id, true) then return nil end
	local x0, y0, x1, y1 -- coarse cells with a hit
	local function Hit(cx, cy)
		if not x0 then x0, y0, x1, y1 = cx, cy, cx, cy return end
		x0, y0, x1, y1 = min(x0, cx), min(y0, cy), max(x1, cx), max(y1, cy)
	end
	for cy = 0, COARSE - 1 do
		local y = (cy + 0.5) / COARSE
		for cx = 0, COARSE - 1 do
			if Inside(f, id, (cx + 0.5) / COARSE, y) then Hit(cx, cy) end
		end
	end
	-- (an area smaller than a coarse cell, around its icon)
	if icon and Inside(f, id, icon[1], icon[2]) then
		Hit(min(COARSE - 1, floor(icon[1] * COARSE)), min(COARSE - 1, floor(icon[2] * COARSE)))
	end
	if not x0 then return nil end
	-- The box around it, a coarse cell bigger each way, in what can be sent.
	local bx0, by0 = Round(max(0, (x0 - 1) / COARSE)), Round(max(0, (y0 - 1) / COARSE))
	local bx1, by1 = Round(min(1, (x1 + 2) / COARSE)), Round(min(1, (y1 + 2) / COARSE))
	local u0, v0, u1, v1 = bx0 / 10000, by0 / 10000, bx1 / 10000, by1 / 10000
	local rows = max(1, min(MAX_ROWS, ceil((v1 - v0) * height / ROW_YARDS)))
	local ch, bw = (v1 - v0) / rows, u1 - u0
	local step = bw / SAMPLES
	-- Where the edge is between a spot outside and one inside.
	local function Edge(y, out, inside)
		for _ = 1, EDGE_STEPS do
			local mid = (out + inside) / 2
			if Inside(f, id, mid, y) then inside = mid else out = mid end
		end
		return (out + inside) / 2
	end
	local function Code(x) return Chars(max(0, min(SPAN, floor((x - u0) / bw * SPAN + 0.5)))) end
	local out, spans = {}, 0
	for r = 0, rows - 1 do
		local y = v0 + (r + 0.5) * ch
		local row, start, was = {}, nil, false
		for c = 0, SAMPLES do
			local x = u0 + c * step
			local is = Inside(f, id, x, y)
			if is and not was then
				start = c == 0 and u0 or Edge(y, x - step, x)
			elseif was and not is then
				row[#row + 1] = Code(start) .. Code(Edge(y, x, x - step))
				spans = spans + 1
			end
			was = is
		end
		if was then
			row[#row + 1] = Code(start) .. Code(u1)
			spans = spans + 1
		end
		out[r + 1] = table.concat(row)
	end
	if spans == 0 then return nil end
	while out[#out] == "" do out[#out] = nil end
	return { x0 = bx0, y0 = by0, x1 = bx1, y1 = by1, rows = rows, data = table.concat(out, ".") }
end

local function Work()
	local found, lines = {}, {}
	local map = ZoneMap()
	if not map then return found, { where = "no map here", lines = lines } end
	local f = Probe()
	local where = (C_Map.GetMapInfo(map) or {}).name or ("map " .. map)
	if not f then where = where .. ", can't read quest areas" end
	local okSize, width, height = pcall(C_Map.GetMapWorldSize, map)
	if not (okSize and width and height and width > 0 and height > 0) then width, height = 1000, 1000 end
	if f then pcall(f.SetMapID, f, map) end
	local icons = Icons(map)
	local id = Focused()
	if id then
		local title = Title(id)
		local name = title ~= "" and title or ("quest " .. id)
		local done = Done(id)
		local area = f and not done and Look(f, id, icons[id], width, height)
		if area then
			area.id, area.map, area.title = id, map, title
			found[#found + 1] = area
			lines[#lines + 1] = ("%s: area, %d rows"):format(name, area.rows)
		elseif icons[id] and not done then
			-- No area to be found, but there's an icon: that spot.
			local x, y = Round(icons[id][1]), Round(icons[id][2])
			found[#found + 1] = { id = id, map = map, title = title, x0 = x, y0 = y, x1 = x, y1 = y,
				rows = 0, data = "" }
			lines[#lines + 1] = name .. ": spot only"
		else
			lines[#lines + 1] = name .. (done and ": done" or ": nothing in this zone")
		end
	end
	if f then pcall(f.DrawNone, f) end
	return found, { where = where, lines = lines }
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

local function TrySend(text)
	local channel = ns.Channel()
	local send = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
	if not (channel and send) then return true end -- nowhere to send it: drop it
	local ok, result = pcall(send, PREFIX, text, channel)
	-- Older clients return nothing; newer ones 0 (or true) for sent.
	return ok and (result == nil or result == 0 or result == true), result
end

-- Sent in order, a message at a time, waiting when the game throttles. A new
-- set replaces what's still waiting.
local queue, pumpTimer, tries = {}, nil, 0
local function Pump()
	pumpTimer = nil
	while queue[1] do
		local sent, result = TrySend(queue[1])
		if not sent then
			tries = tries + 1
			if tries > MAX_RETRIES then
				if ns.debug then ns.Print("quests: gave up sending (" .. tostring(result) .. ")") end
				wipe(queue)
				return
			end
			pumpTimer = C_Timer.NewTimer(RETRY, Pump)
			return
		end
		tries = 0
		table.remove(queue, 1)
	end
end

local function SendSet(messages)
	wipe(queue)
	tries = 0
	for i, m in ipairs(messages) do queue[i] = m end
	if not pumpTimer then Pump() end
end

local seq = 0
local lastKey, lastMessages
local force = false

local function Messages(found)
	seq = seq % 9999 + 1
	local out, key = { ("B\t%d"):format(seq) }, {}
	for _, q in ipairs(found) do
		local chunks = {}
		for i = 1, #q.data, CHUNK do chunks[#chunks + 1] = q.data:sub(i, i + CHUNK - 1) end
		local head = ("%d\t%d\t%d\t%d\t%d\t%d\t%d"):format(q.id, q.map, q.x0, q.y0, q.x1, q.y1, q.rows)
		out[#out + 1] = ("Q\t%d\t%s\t%d\t%s"):format(seq, head, #chunks, q.title)
		for i, chunk in ipairs(chunks) do out[#out + 1] = ("D\t%d\t%d\t%d\t%s"):format(seq, q.id, i, chunk) end
		key[#key + 1] = head .. "\t" .. q.title .. "\t" .. q.data
	end
	out[#out + 1] = ("E\t%d"):format(seq)
	return out, table.concat(key, "\n")
end

local function Finish(found, report)
	Quests.report = report
	if test then
		local list = {}
		for _, q in ipairs(found) do list[q.id] = Decode(q) end
		shared[YOU] = next(list) and list or nil
	end
	if not (IsInGroup() and Quests.On()) then
		lastKey, lastMessages, force = nil, nil, false
		return
	end
	local messages, key = Messages(found)
	if key ~= lastKey or force then
		if ns.debug then ns.Print(("quests: sending %d"):format(#found)) end
		SendSet(messages)
	end
	lastKey, lastMessages, force = key, messages, false
end

local worker, again
local driver = CreateFrame("Frame")
driver:Hide()
driver:SetScript("OnUpdate", function(self)
	if not worker then self:Hide() return end
	deadline = debugprofilestop() + BUDGET
	local ok, found, report = coroutine.resume(worker)
	if not ok then
		worker = nil
		self:Hide()
		if ns.debug then ns.Print("quests: " .. tostring(found)) end
		return
	end
	if coroutine.status(worker) == "dead" then
		worker = nil
		self:Hide()
		local okFinish, err = pcall(Finish, found, report)
		if not okFinish and ns.debug then ns.Print("quests: " .. tostring(err)) end
		if again then
			again = false
			Quests.Soon()
		end
	end
end)

local function Start()
	if not ((IsInGroup() and Quests.On()) or test) then
		lastKey, lastMessages = nil, nil
		return
	end
	if worker then
		again = true
		return
	end
	worker = coroutine.create(Work)
	driver:Show()
end

local soonTimer
-- Look again soon. sendAnyway: send even if nothing changed.
function Quests.Soon(sendAnyway, delay)
	if sendAnyway then force = true end
	if soonTimer then return end
	soonTimer = C_Timer.NewTimer(delay or DELAY, function()
		soonTimer = nil
		Start()
	end)
end

-- Someone joined: send them what you last sent (a moment later, so a whole
-- raid doesn't answer at once).
local resend
local function Resend()
	if resend then return end
	if not lastMessages then return Quests.Soon(true) end
	resend = C_Timer.NewTimer(0.5 + math.random() * 2, function()
		resend = nil
		if lastMessages then SendSet(lastMessages) end
	end)
end

local function Hello()
	if not Quests.On() then return end
	TrySend("H")
	Quests.Soon(true)
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

local incoming = {} -- [owner] = { seq, quests = { [id] = q } }, a set coming in

local function OnMessage(prefix, text, channel, sender)
	if prefix ~= PREFIX then return end
	if channel ~= "PARTY" and channel ~= "RAID" and channel ~= "INSTANCE_CHAT" then return end
	if ns.IsSecret(text) or ns.IsSecret(sender) or not Quests.On() then return end
	local from = ns.SenderKey(sender)
	if not from then return end
	from = ns.MemberKey(from) or from
	local kind, seq, rest = text:match("^(%a)\t?(%d*)\t?(.*)$")
	if not kind then return end
	if kind == "H" then return Resend() end
	seq = tonumber(seq)
	if not seq then return end
	if kind == "B" then
		incoming[from] = { seq = seq, quests = {} }
		return
	end
	local set = incoming[from]
	if not set or set.seq ~= seq then return end
	if kind == "Q" then
		local id, map, x0, y0, x1, y1, rows, parts, title = strsplit("\t", rest)
		id = tonumber(id)
		if not id then return end
		set.quests[id] = { id = id, map = tonumber(map), x0 = tonumber(x0), y0 = tonumber(y0), x1 = tonumber(x1),
			y1 = tonumber(y1), rows = tonumber(rows), parts = tonumber(parts) or 0,
			title = title or "", chunks = {} }
	elseif kind == "D" then
		local id, part, data = strsplit("\t", rest)
		local q = set.quests[tonumber(id) or 0]
		part = tonumber(part)
		if q and part then q.chunks[part] = data or "" end
	elseif kind == "E" then
		incoming[from] = nil
		local list, n = {}, 0
		for id, q in pairs(set.quests) do
			local complete = true
			for i = 1, q.parts do
				if not q.chunks[i] then complete = false end
			end
			if complete then
				q.data = table.concat(q.chunks)
				list[id] = Decode(q)
				if list[id] then n = n + 1 end
			end
		end
		shared[from] = n > 0 and list or nil
		if ns.debug then ns.Print(("quests: %d from %s"):format(n, from)) end
	end
end

-- (Called by Core when the group changes.) joined: you just joined one.
function Quests.RosterChanged(joined)
	for owner in pairs(shared) do
		if owner ~= YOU and not ns.InGroup(owner) then shared[owner] = nil end
	end
	if not IsInGroup() then wipe(incoming) end
	if joined then C_Timer.After(2, Hello) end
	Quests.Soon()
end

-- The switch in the options: off hides theirs and clears yours from them.
function Quests.Changed()
	if Quests.On() then
		Hello()
	else
		for owner in pairs(shared) do
			if owner ~= YOU then shared[owner] = nil end
		end
		wipe(incoming)
		if IsInGroup() then SendSet((Messages({}))) end
		lastKey, lastMessages = nil, nil
	end
end

---------------------------------------------------------------------------
-- The minimap: each run of cells is a thick line in the owner's color, so
-- it turns with a rotating minimap, cut off at the minimap's edge. Under the
-- pins and guild dots.
---------------------------------------------------------------------------

local layer
local lines, spots, drawn = {}, {}, {}

-- A map's place in the world: its continent, the world position of its top
-- left corner (north, west), and how far north and west one whole map width
-- (du) or height (dv) goes.
local worlds = {} -- [map] = { cont, north, west, du, dv } or false
local function World(map)
	local w = worlds[map]
	if w == nil then
		w = false
		if C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D then
			local ok0, c0, p0 = pcall(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(0, 0))
			local ok1, c1, p1 = pcall(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(0.5, 0.5))
			if ok0 and ok1 and c0 and p0 and p1 and c0 == c1 then
				local n0, w0 = p0:GetXY()
				local n1, w1 = p1:GetXY()
				w = { cont = c0, north = n0, west = w0, du = (w1 - w0) * 2, dv = (n1 - n0) * 2 }
			end
		end
		worlds[map] = w
	end
	return w or nil
end

-- The part of the line a-b inside the circle of radius r around the centre.
local function Clip(ax, ay, bx, by, r)
	local dx, dy = bx - ax, by - ay
	local a = dx * dx + dy * dy
	if a < 1e-6 then return nil end
	local b = 2 * (ax * dx + ay * dy)
	local c = ax * ax + ay * ay - r * r
	local disc = b * b - 4 * a * c
	if disc <= 0 then return nil end
	local s = sqrt(disc)
	local t0, t1 = (-b - s) / (2 * a), (-b + s) / (2 * a)
	if t0 < 0 then t0 = 0 end
	if t1 > 1 then t1 = 1 end
	if t1 <= t0 then return nil end
	return ax + dx * t0, ay + dy * t0, ax + dx * t1, ay + dy * t1
end

local function GetLine(n)
	local l = lines[n]
	if not l then
		l = layer:CreateLine(nil, "ARTWORK")
		l:SetColorTexture(1, 1, 1, 1)
		lines[n] = l
	end
	return l
end

local function GetSpot(n)
	local t = spots[n]
	if not t then
		t = layer:CreateTexture(nil, "ARTWORK")
		t:SetTexture(SPOT_TEXTURE)
		spots[n] = t
	end
	return t
end

local function HideFrom(nLines, nSpots)
	for i = nLines + 1, #lines do lines[i]:Hide() end
	for i = nSpots + 1, #spots do spots[i]:Hide() end
end

-- What the cursor is over: the drawn quests it's inside.
local function Hovered(half)
	if not Minimap:IsMouseOver() then return nil end
	local scale = Minimap:GetEffectiveScale()
	local cx, cy = GetCursorPosition()
	local mx, my = Minimap:GetCenter()
	if not (mx and cx) then return nil end
	local x, y = cx / scale - mx, cy / scale - my
	if x * x + y * y > half * half then return nil end
	local found = {}
	for _, d in ipairs(drawn) do
		local q = d.quest
		local inside = false
		if q.point then
			local sx, sy = x - (d.ox + q.x0 * d.ux + q.y0 * d.vx), y - (d.oy + q.x0 * d.uy + q.y0 * d.vy)
			inside = sx * sx + sy * sy <= d.spot * d.spot
		else
			local det = d.ux * d.vy - d.uy * d.vx
			if det ~= 0 then
				local px, py = x - d.ox, y - d.oy
				local u = (px * d.vy - py * d.vx) / det
				local v = (d.ux * py - d.uy * px) / det
				local row = q.byRow[floor((v - q.y0) / q.ch)]
				if row then
					for i = 1, #row, 2 do
						if u >= row[i] and u < row[i + 1] then inside = true break end
					end
				end
			end
		end
		if inside then found[#found + 1] = d end
	end
	return found
end

local function Tooltip(found)
	if found and #found > 0 then
		if GameTooltip:IsShown() and not GameTooltip:IsOwned(layer) then return end
		GameTooltip:SetOwner(layer, "ANCHOR_CURSOR")
		for i, d in ipairs(found) do
			local title = d.quest.title or ("Quest " .. d.quest.id)
			if i == 1 then GameTooltip:SetText(title, 1, 0.82, 0) else GameTooltip:AddLine(title, 1, 0.82, 0) end
			GameTooltip:AddLine(d.owner == YOU and "You" or d.owner, ns.OwnerColor(Owner(d.owner)))
		end
		GameTooltip:Show()
	elseif GameTooltip:IsOwned(layer) then
		GameTooltip:Hide()
	end
end

local function Draw()
	wipe(drawn)
	local map, px, py
	if next(shared) then map, px, py = ns.PlayerPos() end
	local pw = map and World(map)
	if not pw then
		HideFrom(0, 0)
		Tooltip(nil)
		return
	end
	local cont = pw.cont
	local pn, pwest = pw.north + pw.dv * py, pw.west + pw.du * px
	local half = Minimap:GetWidth() / 2
	local edge = half - 1
	local perYard = half / ns.Minimap.Radius()
	-- Screen pixels per minimap unit.
	local screenH = GetPhysicalScreenSize and select(2, GetPhysicalScreenSize())
	local pixels = (screenH and screenH > 0) and Minimap:GetEffectiveScale() * screenH / 768 or 1
	local facing = ns.Minimap.Facing()
	local cos, sin = 1, 0
	if facing then cos, sin = math.cos(facing), math.sin(facing) end
	-- (east, north) yards to minimap offsets, turned with the minimap.
	local function Turn(east, north)
		if facing then east, north = east * cos + north * sin, -east * sin + north * cos end
		return east * perYard, north * perYard
	end
	local nLines, nSpots = 0, 0
	for owner, list in pairs(shared) do
		local r, g, b = ns.OwnerColor(Owner(owner))
		for id, q in pairs(list) do
			local w = World(q.map)
			local mine = owner ~= YOU and C_QuestLog.IsOnQuest and C_QuestLog.IsOnQuest(id)
			if w and w.cont == cont and not mine then
				-- The quest map's corner, and its across (u) and down (v), as minimap
				-- offsets: a spot (u, v) on that map is at o + u * U + v * V.
				local ox, oy = Turn(pwest - w.west, w.north - pn)
				local ux, uy = Turn(-w.du, 0)
				local vx, vy = Turn(0, w.dv)
				local d = { owner = owner, quest = q, ox = ox, oy = oy, ux = ux, uy = uy, vx = vx, vy = vy }
				if q.point then
					local size = SPOT_YARDS * perYard
					local sx, sy = ox + q.x0 * ux + q.y0 * vx, oy + q.x0 * uy + q.y0 * vy
					if sqrt(sx * sx + sy * sy) + size <= half then
						nSpots = nSpots + 1
						local t = GetSpot(nSpots)
						t:SetVertexColor(r, g, b, ALPHA)
						t:SetSize(size * 2, size * 2)
						t:ClearAllPoints()
						t:SetPoint("CENTER", Minimap, "CENTER", sx, sy)
						t:Show()
						d.spot = size
						drawn[#drawn + 1] = d
					end
				else
					-- Skip it whole if its box is nowhere near the minimap.
					local cu, cv = (q.x0 + q.x1) / 2, (q.y0 + q.y1) / 2
					local cx, cy = ox + cu * ux + cv * vx, oy + cu * uy + cv * vy
					local hw, hh = (q.x1 - q.x0) / 2, (q.y1 - q.y0) / 2
					local reach = sqrt((hw * ux) ^ 2 + (hw * uy) ^ 2) + sqrt((hh * vx) ^ 2 + (hh * vy) ^ 2)
					if sqrt(cx * cx + cy * cy) - reach < half then
						-- Rows thinner than MIN_PIXELS are drawn k at a time (the middle
						-- one's spans), so see-through lines don't overlap into stripes.
						local rowSize = q.ch * sqrt(vx * vx + vy * vy)
						local k = max(1, ceil(MIN_PIXELS / (rowSize * pixels)))
						for r0 = 0, q.rows - 1, k do
							local n = min(k, q.rows - r0)
							local spans = q.byRow[r0 + floor(n / 2)]
							if spans then
								local v = q.y0 + (r0 + n / 2) * q.ch
								for i = 1, #spans, 2 do
									local ua, ub = spans[i], spans[i + 1]
									local ax, ay, bx, by = Clip(ox + ua * ux + v * vx, oy + ua * uy + v * vy,
										ox + ub * ux + v * vx, oy + ub * uy + v * vy, edge)
									if ax then
										nLines = nLines + 1
										local l = GetLine(nLines)
										l:SetColorTexture(r, g, b, ALPHA)
										l:SetThickness(rowSize * n)
										l:SetStartPoint("CENTER", Minimap, ax, ay)
										l:SetEndPoint("CENTER", Minimap, bx, by)
										l:Show()
									end
								end
							end
						end
						drawn[#drawn + 1] = d
					end
				end
			end
		end
	end
	HideFrom(nLines, nSpots)
	Tooltip(Hovered(half))
end

local function Setup()
	if layer or not Minimap then return end
	layer = CreateFrame("Frame", nil, Minimap)
	layer:SetAllPoints(Minimap)
	layer:SetFrameLevel(Minimap:GetFrameLevel() + 2) -- (the pins are at +5)
	local elapsed = 0
	layer:SetScript("OnUpdate", function(_, dt)
		elapsed = elapsed + dt
		if elapsed < INTERVAL then return end
		elapsed = 0
		local ok, err = pcall(Draw)
		if not ok and ns.debug then ns.Print("quests: " .. tostring(err)) end
	end)
end

---------------------------------------------------------------------------
-- Test mode and the status (/fwp test, /fwp quests)
---------------------------------------------------------------------------

function Quests.Test()
	test = not test
	if not test then shared[YOU] = nil end
	Quests.Soon(false, 0)
	ns.Print(test and "test on: your own quest's area shows on your minimap." or "test off.")
end

function Quests.PrintStatus()
	if not Quests.On() then
		ns.Print("group quest areas are off (options).")
		return
	end
	local report = Quests.report
	if report then
		ns.Print(("your quest (%s):"):format(report.where))
		if #report.lines == 0 then print("  none followed") end
		for _, line in ipairs(report.lines) do print("  " .. line) end
	else
		ns.Print(IsInGroup() and "your quest: not looked at yet." or "not in a group (/fwp test to try it alone).")
	end
	for owner, list in pairs(shared) do
		if owner ~= YOU then
			local names = {}
			for id, q in pairs(list) do names[#names + 1] = q.title or ("quest " .. id) end
			table.sort(names)
			print(("  %s: %s"):format(owner, table.concat(names, ", ")))
		end
	end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local events = CreateFrame("Frame")
for _, event in ipairs({ "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "CHAT_MSG_ADDON", "ZONE_CHANGED_NEW_AREA",
	"ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "QUEST_WATCH_LIST_CHANGED", "QUEST_LOG_UPDATE", "QUEST_POI_UPDATE",
	"SUPER_TRACKING_CHANGED" }) do
	pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event, ...)
	if event == "CHAT_MSG_ADDON" then
		OnMessage(...)
	elseif event == "PLAYER_LOGIN" then
		local register = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
		if register then pcall(register, PREFIX) end
		Setup()
	elseif event == "PLAYER_ENTERING_WORLD" then
		local isLogin, isReload = ...
		if (isLogin or isReload) and IsInGroup() then C_Timer.After(3, Hello) end
		Quests.Soon()
	else
		Quests.Soon()
	end
end)
