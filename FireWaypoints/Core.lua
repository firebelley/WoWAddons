-- FireWaypoints: as many map pins as you like, shared with your group.
--
-- Shift-click the world map to drop a pin (or /fwp 45.2 60.1 for a spot in
-- your zone). Pins show on the world map and the minimap; right-click one to
-- remove it. Everyone in your group with FireWaypoints sees your pins (in your
-- class color, with your name), and you see theirs.
--
-- Sharing: addon messages to the group. Each change is sent as it happens;
-- anyone joining (or reloading) says hello and the others send their pins.
-- Your own pins are kept per character between sessions; other players' only
-- while you're grouped with them.
local _, ns = ...

local PREFIX = "FireWP"
local MAX_MESSAGE = 240
local MAX_PER_PLAYER = 100
local RETRY = 5           -- seconds before resending pins the game wouldn't send
local DEFAULTS = { minimap = true, share = true }

ns.mine = {}   -- [id] = pin, your pins (saved)
ns.shared = {} -- [owner] = { [id] = pin }, other players' pins
local hidden = {} -- ["owner:id"] = where it was: someone else's pin you removed, this session
-- (by place, so it stays hidden when they resend their pins, but a new pin
-- of theirs that reuses the number shows)
local me
local listeners = {}

function ns.Print(msg) print("|cffff8000FireWaypoints|r: " .. msg) end
local function IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) and true or false end
ns.IsSecret = IsSecret

-- Map, minimap and options redraw when pins change.
function ns.OnChange(fn) listeners[#listeners + 1] = fn end
local function Changed()
	for _, fn in ipairs(listeners) do
		local ok, err = pcall(fn)
		if not ok and ns.debug then ns.Print("error: " .. tostring(err)) end
	end
end
ns.Changed = Changed

---------------------------------------------------------------------------
-- Names and the group (the same naming FireRoll uses)
---------------------------------------------------------------------------

local function Key(name)
	if not name or name == "" or IsSecret(name) then return nil end
	if Ambiguate then return Ambiguate(name, "none") end
	return name
end

-- On Forever names have two parts ("First Last"), and UnitName gives the
-- surname where other clients give the realm.
local function SurnameSeparator()
	local enabled = RegionalUniqueNamesEnabled and RegionalUniqueNamesEnabled()
	if not enabled then return nil end
	local c = Constants and Constants.CharacterNameSeparatorConsts
	return c and c.CHARACTERNAME_SURNAME_SEPARATOR or " "
end

local function UnitKey(unit)
	local name, second = UnitName(unit)
	if not name or IsSecret(name) then return nil end
	if second and second ~= "" and not IsSecret(second) then
		local sep = SurnameSeparator()
		if sep then name = name .. sep .. second
		else name = name .. "-" .. second:gsub("%s", "") end
	end
	return Key(name)
end

local function Norm(name) return (name:gsub("%-[^%-]*$", "")):lower() end -- drops a realm

-- Everyone in the group but you: [key] = unit.
local rosterCache
local function Roster()
	if rosterCache then return rosterCache end
	local list = {}
	if IsInRaid() then
		for i = 1, GetNumGroupMembers() do
			local unit = "raid" .. i
			if not UnitIsUnit(unit, "player") then
				local key = UnitKey(unit)
				if key then list[key] = unit end
			end
		end
	else
		for i = 1, GetNumSubgroupMembers() do
			local key = UnitKey("party" .. i)
			if key then list[key] = "party" .. i end
		end
	end
	rosterCache = list
	return list
end

-- The group member a message's sender is, named the way the group list does.
local function FindMember(roster, name)
	if roster[name] then return name end
	local n = Norm(name)
	for key in pairs(roster) do
		if Norm(key) == n then return key end
	end
	local found
	for key in pairs(roster) do
		local k = Norm(key)
		if k:sub(1, #n + 1) == n .. " " or k:sub(-#n - 1) == " " .. n or n:sub(-#k - 1) == " " .. k then
			if found then return nil end
			found = key
		end
	end
	return found
end

function ns.OwnerColor(owner)
	if not owner then return 1, 0.82, 0 end -- yours: gold
	local unit = Roster()[owner]
	local class = unit and select(2, UnitClass(unit))
	local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if c then return c.r, c.g, c.b end
	return 0.4, 0.8, 1
end

local function Channel()
	if not IsInGroup() then return nil end
	local home, instance = LE_PARTY_CATEGORY_HOME, LE_PARTY_CATEGORY_INSTANCE
	if instance and IsInGroup(instance) and not (home and IsInGroup(home)) then return "INSTANCE_CHAT" end
	return IsInRaid() and "RAID" or "PARTY"
end

---------------------------------------------------------------------------
-- Where a pin is
---------------------------------------------------------------------------

-- Pins are kept as a spot on the map they were placed on; its world position
-- (continent + yards) lets it show on other maps and the minimap.
local function WorldPos(map, x, y)
	if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return nil end
	local ok, cont, pos = pcall(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(x, y))
	if ok and cont and pos then return cont, pos end
	return nil
end

-- (Kept apart from the pins: yours are saved, and these can't be.)
local worldCache = setmetatable({}, { __mode = "k" }) -- [pin] = { cont, world } or false

-- Where a pin is on another map, even off its edge (nil if it can't be said).
local function OnMap(pin, map)
	if pin.map == map then return pin.x, pin.y end
	local w = worldCache[pin]
	if w == nil then
		local cont, world = WorldPos(pin.map, pin.x, pin.y)
		w = cont and { cont, world } or false
		worldCache[pin] = w
	end
	if not w or not C_Map.GetMapPosFromWorldPos then return nil end
	local on = w[map]
	if on == nil then
		local ok, onMap, pos = pcall(C_Map.GetMapPosFromWorldPos, w[1], w[2], map)
		on = (ok and onMap == map and pos) and { pos:GetXY() } or false
		w[map] = on
	end
	if not on then return nil end
	return on[1], on[2]
end

-- Where a pin is on another map (nil if not on it).
function ns.PosOnMap(pin, map)
	local x, y = OnMap(pin, map)
	if not x or x < 0 or x > 1 or y < 0 or y > 1 then return nil end
	return x, y
end

-- Where you are: your map and your spot on it, or nil (instances hide it).
function ns.PlayerPos()
	if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return nil end
	local map = C_Map.GetBestMapForUnit("player")
	if not map or IsSecret(map) then return nil end
	local pos = C_Map.GetPlayerMapPosition(map, "player")
	if not pos then return nil end
	local x, y = pos:GetXY()
	if not x or IsSecret(x) or IsSecret(y) or (x == 0 and y == 0) then return nil end
	return map, x, y
end

-- A pin's offset from you in yards (east, south), or nil if it can't be said
-- (another continent, an instance). map, px, py: where you are, if known.
function ns.Offset(pin, map, px, py)
	if not map then map, px, py = ns.PlayerPos() end
	if not map then return nil end
	local x, y = OnMap(pin, map)
	if not x then return nil end
	local ok, w, h = pcall(C_Map.GetMapWorldSize, map)
	if not (ok and w and h and w > 0 and h > 0) then return nil end
	return (x - px) * w, (y - py) * h
end

function ns.Distance(pin)
	local dx, dy = ns.Offset(pin)
	if not dx then return nil end
	return math.sqrt(dx * dx + dy * dy)
end

function ns.MapName(map)
	local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(map)
	return info and info.name or ("map " .. tostring(map))
end

-- Can pins go on this map? (Not the whole world or a map with no place in it.)
function ns.CanPlace(map, x, y)
	return map ~= nil and WorldPos(map, x, y) ~= nil
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

local function Pack(id, p)
	return ("%d,%d,%d,%d"):format(id, p.map, math.floor(p.x * 10000 + 0.5), math.floor(p.y * 10000 + 0.5))
end

local function Unpack(s)
	local id, map, x, y = (s or ""):match("^(%d+),(%d+),(%d+),(%d+)$")
	id, map, x, y = tonumber(id), tonumber(map), tonumber(x), tonumber(y)
	if not (id and map and x and y) or x > 10000 or y > 10000 then return nil end
	return id, { map = map, x = x / 10000, y = y / 10000 }
end

local retry
local SendAll

local function Send(text)
	if not ns.db.share then return true end
	local channel = Channel()
	if not channel then return true end
	local send = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
	if not send then return true end
	local ok, result = pcall(send, PREFIX, text, channel)
	-- Older clients return nothing; newer ones 0 (or true) for sent.
	local sent = ok and (result == nil or result == 0 or result == true)
	if not sent and ns.debug then ns.Print("couldn't send (" .. tostring(result) .. "), trying again shortly") end
	if not sent and not retry then
		-- Blocked (boss fight, throttled...): send everything again in a moment.
		retry = C_Timer.NewTimer(RETRY, function()
			retry = nil
			SendAll()
		end)
	end
	return sent
end

-- All your pins, replacing what the group has from you.
SendAll = function()
	local ids = {}
	for id in pairs(ns.mine) do ids[#ids + 1] = id end
	table.sort(ids)
	local parts, line = {}, nil
	for _, id in ipairs(ids) do
		local item = Pack(id, ns.mine[id])
		if line and #line + 1 + #item > MAX_MESSAGE then
			parts[#parts + 1] = line
			line = nil
		end
		line = line and (line .. ";" .. item) or item
	end
	if line then parts[#parts + 1] = line end
	if #parts == 0 then parts[1] = "" end
	for i, part in ipairs(parts) do
		if not Send("S\t" .. (i == 1 and "1" or "0") .. "\t" .. part) then return end
	end
end

local function Hello()
	if not (ns.db.share and Channel()) then return end
	Send("H")
	SendAll()
end

local replyTimer
local function ReplyLater()
	if replyTimer or not next(ns.mine) then return end
	-- Spread the replies out so a whole raid doesn't answer at once.
	replyTimer = C_Timer.NewTimer(0.5 + math.random() * 2, function()
		replyTimer = nil
		SendAll()
	end)
end

---------------------------------------------------------------------------
-- Your pins
---------------------------------------------------------------------------

local function FreeID()
	local id = 1
	while ns.mine[id] do id = id + 1 end
	return id
end

function ns.Add(map, x, y)
	if not ns.CanPlace(map, x, y) then return nil end
	local id = FreeID()
	if id > MAX_PER_PLAYER then
		ns.Print(("you have %d pins already - right-click some to remove them."):format(MAX_PER_PLAYER))
		return nil
	end
	local pin = { map = map, x = x, y = y, t = time() }
	ns.mine[id] = pin
	Send("A\t" .. Pack(id, pin))
	Changed()
	return id
end

-- Removes a pin: yours for everyone, someone else's just for you.
function ns.Remove(owner, id)
	if not owner then
		if not ns.mine[id] then return end
		ns.mine[id] = nil
		Send("D\t" .. id)
	else
		local list = ns.shared[owner]
		if not (list and list[id]) then return end
		hidden[owner .. ":" .. id] = Pack(id, list[id])
		list[id] = nil
	end
	Changed()
end

function ns.ClearMine()
	wipe(ns.mine)
	SendAll()
	Changed()
end

function ns.ClearOthers()
	for owner, list in pairs(ns.shared) do
		for id, pin in pairs(list) do hidden[owner .. ":" .. id] = Pack(id, pin) end
	end
	wipe(ns.shared)
	Changed()
end

-- Every pin: fn(owner or nil for yours, id, pin).
function ns.ForEach(fn)
	for id, pin in pairs(ns.mine) do fn(nil, id, pin) end
	for owner, list in pairs(ns.shared) do
		for id, pin in pairs(list) do fn(owner, id, pin) end
	end
end

function ns.Count()
	local mine, others = 0, 0
	for _ in pairs(ns.mine) do mine = mine + 1 end
	for _, list in pairs(ns.shared) do
		for _ in pairs(list) do others = others + 1 end
	end
	return mine, others
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

local function Put(owner, id, pin)
	if hidden[owner .. ":" .. id] == Pack(id, pin) then return end
	local list = ns.shared[owner]
	if not list then
		list = {}
		ns.shared[owner] = list
	end
	if not list[id] then
		local n = 0
		for _ in pairs(list) do n = n + 1 end
		if n >= MAX_PER_PLAYER then return end
	end
	list[id] = pin
end

local function OnAddonMessage(prefix, text, _, sender)
	if prefix ~= PREFIX then return end
	if IsSecret(text) or IsSecret(sender) then return end
	local from = Key(sender)
	if not from then return end
	-- Our own messages come back to us too.
	me = me or UnitKey("player")
	if me and Norm(from) == Norm(me) then return end
	local okSelf, isSelf = pcall(UnitIsUnit, sender, "player")
	if okSelf and isSelf and not IsSecret(isSelf) then return end
	from = FindMember(Roster(), from) or from
	local kind, a, b = strsplit("\t", text)
	if ns.debug then ns.Print(("%s from %s"):format(tostring(kind), from)) end
	if kind == "H" then
		ReplyLater()
	elseif kind == "A" then
		local id, pin = Unpack(a)
		if id then Put(from, id, pin) Changed() end
	elseif kind == "D" then
		local id = tonumber(a)
		local list = ns.shared[from]
		if id and list then
			list[id] = nil
			Changed()
		end
	elseif kind == "S" then
		if a == "1" then ns.shared[from] = nil end
		for item in (b or ""):gmatch("[^;]+") do
			local id, pin = Unpack(item)
			if id then Put(from, id, pin) end
		end
		Changed()
	end
end

---------------------------------------------------------------------------
-- The group changing
---------------------------------------------------------------------------

local wasGrouped = false
local function OnRoster()
	rosterCache = nil
	local grouped = IsInGroup()
	if not grouped then
		if next(ns.shared) then
			wipe(ns.shared)
			wipe(hidden)
			Changed()
		end
	else
		-- Drop the pins of anyone who left.
		local roster, changed = Roster(), false
		for owner in pairs(ns.shared) do
			if not FindMember(roster, owner) then
				ns.shared[owner] = nil
				changed = true
			end
		end
		if changed then Changed() end
		if not wasGrouped then C_Timer.After(2, Hello) end
	end
	wasGrouped = grouped
end

---------------------------------------------------------------------------
-- Events and slash command
---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("CHAT_MSG_ADDON")
events:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" then
		if ... ~= "FireWaypoints" then return end
		FireWaypointsDB = type(FireWaypointsDB) == "table" and FireWaypointsDB or {}
		ns.db = FireWaypointsDB
		for k, v in pairs(DEFAULTS) do
			if ns.db[k] == nil then ns.db[k] = v end
		end
		FireWaypointsCharDB = type(FireWaypointsCharDB) == "table" and FireWaypointsCharDB or {}
		FireWaypointsCharDB.pins = type(FireWaypointsCharDB.pins) == "table" and FireWaypointsCharDB.pins or {}
		ns.mine = FireWaypointsCharDB.pins
		local register = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
		if register then pcall(register, PREFIX) end
	elseif event == "PLAYER_LOGIN" then
		me = UnitKey("player")
		Changed()
	elseif event == "PLAYER_ENTERING_WORLD" then
		local isLogin, isReload = ...
		rosterCache = nil
		if isLogin or isReload then
			wasGrouped = IsInGroup()
			if wasGrouped then C_Timer.After(3, Hello) end
		end
	elseif event == "GROUP_ROSTER_UPDATE" then
		OnRoster()
	elseif event == "CHAT_MSG_ADDON" then
		OnAddonMessage(...)
	end
end)

-- Sharing switched back on: the group gets your pins.
function ns.SharingChanged()
	if ns.db.share then Hello() end
end

local function PrintList()
	local mine, others = ns.Count()
	if mine + others == 0 then
		ns.Print("no pins. Shift-click the world map to drop one.")
		return
	end
	ns.Print(("%d pin%s of yours, %d from your group:"):format(mine, mine == 1 and "" or "s", others))
	local rows = {}
	ns.ForEach(function(owner, id, pin)
		local d = ns.Distance(pin)
		rows[#rows + 1] = { owner = owner or "", id = id, text = ("  %s%d - %s %.1f, %.1f%s"):format(
			owner and (owner .. " ") or "", id, ns.MapName(pin.map), pin.x * 100, pin.y * 100,
			d and (" |cff999999(%d yards)|r"):format(d) or "") }
	end)
	table.sort(rows, function(a, b)
		if a.owner ~= b.owner then return a.owner < b.owner end
		return a.id < b.id
	end)
	for _, r in ipairs(rows) do print(r.text) end
end

SLASH_FIREWAYPOINTS1 = "/fwp"
SLASH_FIREWAYPOINTS2 = "/firewaypoints"
SlashCmdList.FIREWAYPOINTS = function(input)
	input = strtrim(input or "")
	local cmd = input:lower()
	local x, y = input:gsub(",", " "):match("^([%d%.]+)%s+([%d%.]+)$")
	x, y = tonumber(x), tonumber(y)
	if x and y then
		local map = ns.PlayerPos()
		map = map or (C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player"))
		if not map or x > 100 or y > 100 then
			ns.Print("can't place a pin there.")
		elseif ns.Add(map, x / 100, y / 100) then
			ns.Print(("pin dropped at %.1f, %.1f in %s."):format(x, y, ns.MapName(map)))
		else
			ns.Print("pins can't go on this map.")
		end
	elseif cmd == "" or cmd == "list" then
		PrintList()
	elseif cmd == "clear" then
		ns.ClearMine()
		ns.Print("your pins are cleared (for your group too).")
	elseif cmd == "clear all" then
		ns.ClearMine()
		ns.ClearOthers()
		ns.Print("all pins cleared. Your group's come back if they drop new ones or you regroup.")
	elseif cmd == "options" or cmd == "config" then
		ns.Options.Open()
	elseif cmd == "debug" then
		ns.debug = not ns.debug
		local map, px, py = ns.PlayerPos()
		ns.Print(("debug %s. You are %q on %s at %s."):format(ns.debug and "on" or "off", tostring(me),
			tostring(map), px and ("%.3f, %.3f"):format(px, py) or "?"))
	else
		ns.Print("commands:")
		print("  shift-click the world map - drop a pin (right-click a pin to remove it)")
		print("  /fwp 45.2 60.1 - drop a pin at those coordinates in your zone")
		print("  /fwp list - list the pins")
		print("  /fwp clear - remove your pins (for your group too)")
		print("  /fwp clear all - also hide your group's pins")
		print("  /fwp options - open the options")
	end
end
