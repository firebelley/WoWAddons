-- Shared setup: saved settings, printing, and a tiny event bus every file uses.
local ADDON, ns = ...
ns.ADDON = ADDON

local DEFAULTS = {
	sound = true,
	showIcons = true,  -- icons (with timers) for active proc buffs under the announcements
	scale = 1,         -- size of the announcements
	hold = 1.5,        -- seconds an announcement stays before fading
	-- What to announce (see Options.lua).
	detectBuffs = true,     -- proc buffs: Clearcasting, Flurry...
	detectAbilities = true, -- abilities that light up: Overpower, Execute...
	glowButtons = true,     -- ...and make their action buttons glow
	detectChanges = true,   -- spells that become free/instant: Missile Barrage...
	detectDrain = true,     -- life-drain heals: Touch of the Grave
	detectGifts = true,     -- long buffs from other players: Arcane Intellect...
	detectTriggered = true, -- spells that go off by themselves
	-- Buff reminders (see SelfBuffs.lua).
	remindBuffs = true,     -- notice when your own long buffs are gone
	remindAnnounce = true,  -- ...announce it once
	remindIcon = true,      -- ...and keep an icon up until you recast it
}
ns.DEFAULTS = DEFAULTS

function ns.Print(msg)
	print("|cffff8030FireProcs|r: " .. msg)
end

-- /fprocs debug: explains every decision in chat.
ns.tracing = false
function ns.Trace(msg)
	if ns.tracing then print("|cff80a0ffFireProcs debug|r: " .. msg) end
end

---------------------------------------------------------------------------
-- Errors: WoW hides Lua errors unless scriptErrors is on, so FireProcs prints
-- its own (each distinct message once per session).
---------------------------------------------------------------------------
local reported = {}
function ns.ReportError(err)
	local msg = tostring(err)
	if reported[msg] then return end
	reported[msg] = true
	ns.Print("|cffff4040error:|r " .. msg)
end

function ns.SafeCall(fn, ...)
	local n, args = select("#", ...), { ... }
	return xpcall(function() return fn(unpack(args, 1, n)) end, ns.ReportError)
end

---------------------------------------------------------------------------
-- Events: ns.On(event, fn) lets any file listen without its own frame.
-- Events that don't exist on this client are silently ignored.
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local handlers = {}

function ns.On(event, fn)
	if not handlers[event] then
		handlers[event] = {}
		pcall(eventFrame.RegisterEvent, eventFrame, event)
	end
	table.insert(handlers[event], fn)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
	for _, fn in ipairs(handlers[event]) do
		ns.SafeCall(fn, ...)
	end
end)

-- Like ns.On, but only for one unit (so UNIT_AURA from the whole raid doesn't
-- wake us up). fn receives the same arguments as the event.
function ns.OnUnit(event, unit, fn)
	local f = CreateFrame("Frame")
	if not pcall(f.RegisterUnitEvent, f, event, unit) then
		pcall(f.RegisterEvent, f, event)
	end
	f:SetScript("OnEvent", function(_, _, u, ...)
		if u == unit then ns.SafeCall(fn, u, ...) end
	end)
end

---------------------------------------------------------------------------
-- Saved settings
---------------------------------------------------------------------------
ns.On("ADDON_LOADED", function(name)
	if name ~= ADDON then return end
	FireProcsDB = FireProcsDB or {}
	local db = FireProcsDB
	for k, v in pairs(DEFAULTS) do
		if db[k] == nil then db[k] = v end
	end
	db.muted = db.muted or {} -- [spell name] = true, or "auto" when FireProcs muted it
	db.seen = db.seen or {}   -- [spell name] = true for every proc announced so far
	db.selfBuffs = db.selfBuffs or {} -- [buff name] = { icon, on, group } for buff reminders
	ns.db = db
end)
