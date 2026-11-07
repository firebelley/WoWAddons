-- Shared setup: saved settings, printing, and a tiny event bus every file uses.
local ADDON, ns = ...
ns.ADDON = ADDON

local DEFAULTS = {
	sound = true,
}

function ns.Print(msg)
	print("|cffff8030FireProcs|r: " .. msg)
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
	ns.db = db
end)
