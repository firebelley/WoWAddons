-- The single gate every detected proc goes through: mutes, de-duplication,
-- and auto-muting effects that fire on nearly every hit.
local _, ns = ...

local THROTTLE = 3       -- seconds before the same proc is announced again
local FREQ_COUNT = 6     -- an effect seen this many times...
local FREQ_WINDOW = 30   -- ...within this many seconds isn't worth announcing
local DEDUPE = 0.25      -- one proc can log several events (damage + heal)

local lastShown, lastSeen, history = {}, {}, {}

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
-- (a one-off effect from the combat log). Returns true if it's a live proc.
function ns.Proc(name, icon, kind)
	local db = ns.db
	if not db or not name or name == "" or db.muted[name] then return false end
	local now = GetTime()

	-- Effects that fire on (almost) every hit, like some weapon enchants, would
	-- drown out the real procs. Buffs and abilities are naturally limited.
	if kind == "event" and TooFrequent(name, now) then
		db.muted[name] = "auto"
		ns.Print(("%s happens too often to be worth announcing, so it's muted now. Type /fprocs unmute %s to undo."):format(name, name))
		return false
	end

	ns.lastProc = name
	if not db.seen[name] then
		db.seen[name] = true
		ns.Print(("new proc: |cffffd100%s|r. Type /fprocs mute right after it shows to stop announcing it."):format(name))
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
