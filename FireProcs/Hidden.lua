-- Proc buffs the game hides from addons in combat (e.g. Missile Barrage).
--
-- Addons can't read a hidden buff, but can still:
--  * list your buffs' instance IDs, so a new one appearing is visible;
--  * see their own casts, which are never hidden;
--  * hand the hidden name and icon straight to the screen without reading them.
-- So: a new buff whose details can't be read, that no non-attack spell/item of
-- yours explains (Ice Barrier, Arcane Power, a potion...), is announced as a
-- proc with its real name and icon. Readable buffs are left to Auras.lua.
local _, ns = ...
local API, Spells = ns.API, ns.Spells

local EXPLAIN_WINDOW = 0.6 -- seconds after your own non-attack cast/item use

local Hidden = { seen = 0, announced = 0, source = "none yet" }
ns.Hidden = Hidden

local known -- [auraInstanceID] = true for the buffs at the last look

local function IsSecret(v) return API.IsSecret(v) end

-- Your buffs as { [auraInstanceID] = auraData or true }, or nil if this client
-- won't list them. Two ways to ask; whichever works.
local function CurrentBuffs(filter)
	local UA = C_UnitAuras
	if UA and UA.GetUnitAuraInstanceIDs then
		local ok, ids = pcall(UA.GetUnitAuraInstanceIDs, "player", filter)
		if ok and type(ids) == "table" and not IsSecret(ids) then
			local set = {}
			for _, id in ipairs(ids) do
				if not IsSecret(id) then set[id] = true end
			end
			Hidden.source = "GetUnitAuraInstanceIDs"
			return set
		end
	end
	if UA and UA.GetUnitAuras then
		local ok, list = pcall(UA.GetUnitAuras, "player", filter)
		if ok and type(list) == "table" and not IsSecret(list) then
			local set = {}
			for _, a in ipairs(list) do
				local id = type(a) == "table" and a.auraInstanceID
				if id and not IsSecret(id) then set[id] = a end
			end
			Hidden.source = "GetUnitAuras"
			return set
		end
	end
	Hidden.source = "unavailable"
	return nil
end

-- The aura's data (contents may be hidden), or nil if the game refuses.
local function AuraData(id, known)
	if type(known) == "table" then return known end
	local UA = C_UnitAuras
	if UA and UA.GetAuraDataByAuraInstanceID then
		local ok, a = pcall(UA.GetAuraDataByAuraInstanceID, "player", id)
		if ok and type(a) == "table" then return a end
	end
end

local function IsHiddenAura(id, data)
	local S = C_Secrets
	if S and S.ShouldUnitAuraInstanceBeSecret then
		local ok, secret = pcall(S.ShouldUnitAuraInstanceBeSecret, "player", id)
		if ok and secret then return true end
	end
	-- Can't read its name: hidden. Can't fetch it at all: hidden if in combat
	-- (outside combat that's just this client lacking the function, and the
	-- buff is readable the normal way in Auras.lua).
	if data == nil then return UnitAffectingCombat("player") and true or false end
	return IsSecret(data.name) or IsSecret(data.spellId)
end

function Hidden.Update()
	local all = CurrentBuffs("HELPFUL")
	if not all then return end
	local previous = known
	known = all
	if not previous then return end -- first look: nothing is "new"

	local mine
	local solo = not (IsInGroup and IsInGroup())
	local explained = GetTime() - Spells.lastHelpfulCastAt < EXPLAIN_WINDOW

	for id, entry in pairs(all) do
		if not previous[id] then
			local data = AuraData(id, entry)
			if IsHiddenAura(id, data) then
				Hidden.seen = Hidden.seen + 1
				mine = mine or CurrentBuffs("HELPFUL|PLAYER") or {}
				if not (mine[id] or solo) then
					ns.Trace("hidden buff appeared: the game doesn't say it's yours and you're in a group, skipped")
				elseif explained then
					ns.Trace(("hidden buff appeared right after you cast %s (not an attack spell): assumed to be from that")
						:format(tostring(Spells.lastHelpfulCastName)))
				elseif ns.db.hiddenProcs == false then
					ns.Trace("hidden buff appeared, but guessing is off (/fprocs hidden)")
				else
					Hidden.announced = Hidden.announced + 1
					ns.Trace("hidden buff appeared with nothing you did to explain it: announced as a proc")
					ns.Display.AlertHidden(data and data.name, data and data.icon, id)
				end
			end
		end
	end
end

-- For /fprocs status: try every way of listing your buffs and report what the
-- game answers.
function Hidden.Probe()
	local UA, S = C_UnitAuras or {}, C_Secrets or {}
	local function Try(label, fn, ...)
		if type(fn) ~= "function" then return label .. ": missing" end
		local ok, a = pcall(fn, ...)
		if not ok then return label .. ": error (" .. tostring(a):sub(1, 90) .. ")" end
		if IsSecret(a) then return label .. ": hidden" end
		if type(a) == "table" then
			local n = 0
			for _ in pairs(a) do n = n + 1 end
			return ("%s: %d entries"):format(label, n)
		end
		return label .. ": " .. tostring(a)
	end
	local hiddenCount = API.ForEachAura("player", "HELPFUL", function() end)
	return {
		("in combat: %s; hidden flag: %s; buffs that can't be read: %d"):format(
			tostring(UnitAffectingCombat("player") and true or false), tostring(API.AurasRestricted()), hiddenCount),
		Try("GetUnitAuraInstanceIDs", UA.GetUnitAuraInstanceIDs, "player", "HELPFUL"),
		Try("GetUnitAuras", UA.GetUnitAuras, "player", "HELPFUL"),
		Try("GetAuraSlots", UA.GetAuraSlots, "player", "HELPFUL"),
		Try("ShouldAurasBeSecret", S.ShouldAurasBeSecret),
		"last buff list used: " .. Hidden.source,
	}
end

-- For /fprocs debug.
function Hidden.Describe()
	local all = CurrentBuffs("HELPFUL")
	local source = Hidden.source
	local mine = CurrentBuffs("HELPFUL|PLAYER")
	local function Count(set)
		if not set then return "?" end
		local n = 0
		for _ in pairs(set) do n = n + 1 end
		return tostring(n)
	end
	return ("buff list via %s: %s buffs, %s cast by you; hidden flag: %s; in a group: %s"):format(
		source, Count(all), Count(mine), tostring(API.AurasRestricted()),
		tostring(IsInGroup and IsInGroup() or false))
end

ns.OnUnit("UNIT_AURA", "player", function() Hidden.Update() end)
ns.On("PLAYER_ENTERING_WORLD", function()
	known = nil
	Hidden.Update()
end)
