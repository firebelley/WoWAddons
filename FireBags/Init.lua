-- Shared setup: saved settings, printing, and a tiny event bus every file uses.
local ADDON, ns = ...
ns.ADDON = ADDON

local DEFAULTS = {
	columns = 10,      -- slots per row in the bag window
	bankColumns = 14,  -- slots per row in the bank window
	scale = 1,
	locked = false,
	showKeyring = true,
	sortMode = "auto", -- "auto" (Blizzard's sort if available), "blizzard", "custom"
	newItemGlow = true,
	tooltipCounts = true, -- "Bags: 12  Bank: 40" on item tooltips
	background = "default", -- window background: default, rock, marble, dark
}

function ns.Print(msg)
	print("|cffff8030FireBags|r: " .. msg)
end

---------------------------------------------------------------------------
-- Errors: WoW hides Lua errors unless scriptErrors is on, so FireBags prints
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

---------------------------------------------------------------------------
-- Saved settings
---------------------------------------------------------------------------
ns.On("ADDON_LOADED", function(name)
	if name ~= ADDON then return end
	FireBagsDB = FireBagsDB or {}
	local db = FireBagsDB
	for k, v in pairs(DEFAULTS) do
		if db[k] == nil then db[k] = v end
	end
	db.positions = db.positions or {}
	db.chars = db.chars or {} -- per-character data (bank snapshots)

	-- Older versions saved a single window position.
	if db.position then
		db.positions.inventory = db.positions.inventory or db.position
		db.position = nil
	end
	-- v2: the stone background was briefly the default; go back to the frame's own.
	if (db.settingsVersion or 1) < 2 then
		db.background = "default"
		db.settingsVersion = 2
	end
	ns.db = db
end)
