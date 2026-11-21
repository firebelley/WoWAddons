-- Shared setup: saved settings, printing, and a tiny event bus every file uses.
local ADDON, ns = ...
ns.ADDON = ADDON

local DEFAULTS = {
	columns = 10,      -- slots per row in the bag window
	bankColumns = 14,  -- slots per row in the bank window
	bankTabsSeparate = false, -- bank tabs as their own sections (true) or one grid (false)
	scale = 1,
	locked = false,
	showKeyring = true,
	sortMode = "auto", -- "auto" (Blizzard's sort if available), "blizzard", "custom"
	newItemGlow = true,
	tooltipCounts = true, -- "Bags: 12  Bank: 40" on item tooltips
	craftCounts = true,   -- profession windows count your bank too
	craftVendor = true,   -- ...and show how many more you could make by buying vendor reagents
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
	return xpcall(fn, ns.ReportError, ...)
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
	db.vendorItems = db.vendorItems or {} -- [itemID] = true for items merchants sell (Crafting.lua)

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
	ns.MergeBlankRealm(db)
end)

---------------------------------------------------------------------------
-- The realm's name, for per-character keys ("Name - Realm"). Forever's
-- client started giving "" for it (2026-11-20): the last real name seen
-- stands in (before one's seen: the one in the saved keys), and a character
-- saved under the blank name ("Name - ") goes back with the rest.
---------------------------------------------------------------------------
function ns.RealmName()
	local name = GetRealmName and GetRealmName()
	if type(name) == "string" and name ~= "" then
		if ns.db then ns.db.realmName = name end
		return name
	end
	return ns.db and ns.db.realmName or ""
end

function ns.MergeBlankRealm(db)
	if not db.realmName then
		local found, count = nil, 0
		for key in pairs(db.chars) do
			local realm = key:match("^.- %- (.+)$")
			if realm and realm ~= found then found, count = realm, count + 1 end
		end
		if count == 1 then db.realmName = found end
	end
	local realm = db.realmName
	if not realm then return end
	for key, b in pairs(db.chars) do
		local name = key:match("^(.-) %- $")
		if name then
			local to = name .. " - " .. realm
			local a = db.chars[to]
			if not a then
				db.chars[to] = b
			else
				-- The newer bank snapshot, and the actions if any were set up since.
				if b.bank and (b.bank.time or 0) > (a.bank and a.bank.time or 0) then a.bank = b.bank end
				if b.actions and #b.actions > 0 then a.actions = b.actions end
				for k, v in pairs(b) do
					if a[k] == nil then a[k] = v end
				end
			end
			db.chars[key] = nil
		end
	end
end
