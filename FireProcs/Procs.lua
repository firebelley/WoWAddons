-- The single gate every detected proc goes through: mutes, de-duplication,
-- and auto-muting effects that fire on nearly every hit.
local _, ns = ...

local THROTTLE = 3       -- seconds before the same proc is announced again
local FREQ_COUNT = 6     -- an effect seen this many times...
local FREQ_WINDOW = 30   -- ...within this many seconds isn't worth announcing
local DEDUPE = 0.25      -- one proc can log several events (damage + heal)

local lastShown, lastSeen, history = {}, {}, {}

-- Entering some places casts a spell named after the place ("Gadgetzan",
-- "Dun Garok"): never a proc. Place names: every area the game knows (read
-- at login, behind the loading screen), plus every place you've been.
local MAX_AREA = 16000
local places = {}

local function Remember(name)
	if name and name ~= "" then places[name] = true end
end
local function RememberZone()
	Remember(GetZoneText and GetZoneText())
	Remember(GetSubZoneText and GetSubZoneText())
	Remember(GetRealZoneText and GetRealZoneText())
	Remember(GetMinimapZoneText and GetMinimapZoneText())
end
for _, event in ipairs({ "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD" }) do
	ns.On(event, RememberZone)
end

ns.On("PLAYER_LOGIN", function()
	local info = C_Map and C_Map.GetAreaInfo
	if not info then return end
	for id = 1, MAX_AREA do
		local ok, area = pcall(info, id)
		if ok and type(area) == "string" then Remember(area) end
	end
end)

local function IsPlace(name)
	RememberZone() -- the spell can come before the zone-change event
	return places[name] == true
end

-- Internal effects with no real name ("LOGINEFFECT"): no lowercase letters.
local function IsInternal(name)
	return not name:find("%l")
end

local function TooFrequent(name, now)
	if now - (lastSeen[name] or -100) < DEDUPE then return false end
	lastSeen[name] = now
	local h = history[name]
	if not h then
		h = {}
		history[name] = h
	end
	h[#h + 1] = now
	while h[1] and now - h[1] > FREQ_WINDOW do table.remove(h, 1) end
	return #h >= FREQ_COUNT
end

-- kind: "aura" (a buff you gained), "ready" (an ability lit up) or "event"
-- (a one-off spell that went off by itself).
-- setting: the db switch for this kind of detection ("detectBuffs"...), so the
-- options panel can turn whole kinds off. Returns true if it's a live proc.
function ns.Proc(name, icon, kind, setting)
	local db = ns.db
	if not db or not name or name == "" then return false end
	if setting and db[setting] == false then
		ns.Trace(("%s: not announced (%s is off in the options)"):format(name, setting))
		return false
	end
	if db.muted[name] then
		ns.Trace(name .. ": muted, not announced")
		return false
	end
	if IsInternal(name) or IsPlace(name) then
		ns.Trace(name .. ": a place or game effect, not a proc")
		return false
	end
	local now = GetTime()

	-- Effects that fire on (almost) every hit, like some weapon enchants, would
	-- drown out the real procs. Buffs and abilities are naturally limited.
	if kind == "event" and TooFrequent(name, now) then
		db.muted[name] = "auto"
		ns.Print(("%s procs too often - muted. /fprocs unmute %s to undo."):format(name, name))
		return false
	end

	ns.lastProc = name
	if not db.seen[name] then
		db.seen[name] = true
		ns.Print(("new proc: |cffffd100%s|r. Turn it off in /fprocs procs, or type /fprocs mute right after it shows."):format(name))
	end

	if now - (lastShown[name] or -100) >= THROTTLE then
		lastShown[name] = now
		ns.Display.Alert(name, icon)
	end
	return true
end

function ns.ResetProcHistory(name)
	history[name] = nil
	lastSeen[name] = nil
end
