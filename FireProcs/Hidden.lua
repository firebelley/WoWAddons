-- Proc buffs the game hides from addons in combat (e.g. Missile Barrage).
--
-- Addons can't read a hidden buff, but can still:
--  * list the instance IDs of your buffs (and of the ones *you* applied), so a
--    new one appearing is visible;
--  * see their own casts, which are never hidden;
--  * hand the hidden name and icon straight to the screen without reading them.
-- So: a new hidden buff that no non-attack spell/item of yours explains (Ice
-- Barrier, Arcane Power, a potion...) is announced as a proc, with its real
-- name and icon. Readable buffs are left to Auras.lua.
local _, ns = ...
local API, Spells = ns.API, ns.Spells

local EXPLAIN_WINDOW = 0.6 -- seconds after your own non-attack cast/item use

local Hidden = { seen = 0, announced = 0 }
ns.Hidden = Hidden

local known -- [auraInstanceID] = true for the buffs at the last look

local function InstanceIDs(filter)
	if not (C_UnitAuras and C_UnitAuras.GetUnitAuraInstanceIDs) then return nil end
	local ok, ids = pcall(C_UnitAuras.GetUnitAuraInstanceIDs, "player", filter)
	if not ok or type(ids) ~= "table" or API.IsSecret(ids) then return nil end
	local set = {}
	for _, id in ipairs(ids) do
		if not API.IsSecret(id) then set[id] = true end
	end
	return set
end

local function IsHiddenAura(id)
	local S = C_Secrets
	if not (S and S.ShouldUnitAuraInstanceBeSecret) then return false end
	local ok, secret = pcall(S.ShouldUnitAuraInstanceBeSecret, "player", id)
	return ok and secret and true or false
end

-- The aura's (hidden) data, only ever passed to the screen.
local function AuraData(id)
	if C_UnitAuras.GetAuraDataByAuraInstanceID then
		local ok, a = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, "player", id)
		if ok and type(a) == "table" then return a end
	end
	if C_UnitAuras.GetUnitAuras then
		local ok, list = pcall(C_UnitAuras.GetUnitAuras, "player", "HELPFUL")
		if ok and type(list) == "table" then
			for _, a in ipairs(list) do
				local aid = a.auraInstanceID
				if not API.IsSecret(aid) and aid == id then return a end
			end
		end
	end
end

function Hidden.Update()
	local all = InstanceIDs("HELPFUL")
	if not all then return end
	local first = known == nil
	local previous = known
	known = all
	if first or not API.AurasRestricted() then return end

	local mine = InstanceIDs("HELPFUL|PLAYER") or {}
	local solo = not (IsInGroup and IsInGroup())
	local explained = GetTime() - Spells.lastHelpfulCastAt < EXPLAIN_WINDOW

	for id in pairs(all) do
		if not previous[id] and IsHiddenAura(id) then
			Hidden.seen = Hidden.seen + 1
			-- Buffs from others name their caster; procs are yours or have no
			-- caster at all, which only a solo player can rely on.
			if not (mine[id] or solo) then
				ns.Trace("hidden buff appeared: the game doesn't say it's yours and you're in a group, skipped")
			elseif explained then
				ns.Trace(("hidden buff appeared right after you cast %s (not an attack spell): assumed to be from that")
					:format(tostring(Spells.lastHelpfulCastName)))
			elseif ns.db.hiddenProcs ~= false then
				Hidden.announced = Hidden.announced + 1
				ns.Trace("hidden buff appeared with nothing you did to explain it: announced as a proc")
				local a = AuraData(id)
				ns.Display.AlertHidden(a and a.name, a and a.icon, id)
			end
		end
	end
end

-- For /fprocs debug.
function Hidden.Describe()
	local all, mine = InstanceIDs("HELPFUL"), InstanceIDs("HELPFUL|PLAYER")
	local function Count(set)
		if not set then return "unavailable" end
		local n = 0
		for _ in pairs(set) do n = n + 1 end
		return tostring(n)
	end
	return ("buff IDs: %s total, %s cast by you; buffs hidden right now: %s; in a group: %s"):format(
		Count(all), Count(mine), tostring(API.AurasRestricted()), tostring(IsInGroup and IsInGroup() or false))
end

ns.OnUnit("UNIT_AURA", "player", function() Hidden.Update() end)
ns.On("PLAYER_ENTERING_WORLD", function()
	known = nil
	Hidden.Update()
end)
