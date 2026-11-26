-- Proc buffs named after your talents (Fingers of Frost, Decimation...),
-- looked up by name while you're in combat.
--
-- In combat the game hides your buffs from addons, and the usual way of
-- reading them (going through the list) stops working entirely. But a few
-- buffs it doesn't hide, and those can still be asked for one at a time by
-- name. So each time your buffs change in a fight, each talent of yours that
-- works by chance is looked up: if a buff with its name has just appeared,
-- that's the proc. Buffs the game does hide simply come back as nothing.
-- (Out of combat, Auras.lua sees every buff anyway.)
local _, ns = ...
local API, Spells = ns.API, ns.Spells

local CHECK_DELAY = 0.05

local TalentBuffs = {}
ns.TalentBuffs = TalentBuffs

local names = {}      -- talent names to look up (rebuilt when the talents change)
local builtFrom       -- the Spells.passives list `names` was made from
local up = {}         -- [name] = true while that buff is on you
local explained = {}  -- [name] = true once /fprocs debug has said it's hidden
local silent = true   -- the first look in a fight only notes what's already there

-- Talents that work by chance (their tooltip says so).
local function Names()
	local passives = Spells.passives
	if builtFrom ~= passives then
		builtFrom = passives
		wipe(names)
		for _, p in ipairs(passives or {}) do
			if p.talent and Spells.PassiveText(p):find("chance", 1, true) then names[#names + 1] = p end
		end
	end
	return names
end

-- true = on you, false = not on you, nil = hidden by the game.
local function Lookup(name)
	local fn = C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName
	if not fn then return nil end
	local ok, aura = pcall(fn, "player", name, "HELPFUL")
	if not ok or API.IsSecret(aura) then return nil end
	if aura == nil then return false end
	return type(aura) == "table" and not API.IsSecret(aura.name), aura
end

-- A buff with no timer is the talent's own passive showing, not a proc.
local function Permanent(aura)
	local d = aura and aura.duration
	return type(d) == "number" and not API.IsSecret(d) and d <= 0
end

local function Check()
	if not API.AurasRestricted() then
		wipe(up) -- (out of combat, Auras.lua announces them)
		silent = true
		return
	end
	for _, p in ipairs(Names()) do
		local name = p.name
		local found, aura = Lookup(name)
		if found == nil then
			if not explained[name] then
				explained[name] = true
				ns.Trace(name .. ": can't be looked up in combat (the game hides it)")
			end
		elseif found and not up[name] then
			up[name] = true
			if not silent and not Permanent(aura) then
				ns.Trace(name .. ": buff found by name in combat")
				ns.Proc(name, (aura and not API.IsSecret(aura.icon) and aura.icon) or p.icon, "aura", "detectBuffs")
			end
		elseif not found then
			up[name] = nil
		end
	end
	silent = false
end

local queued = false
local function QueuedCheck()
	queued = false
	ns.SafeCall(Check)
end
local function RequestCheck()
	if queued then return end
	queued = true
	C_Timer.After(CHECK_DELAY, QueuedCheck)
end

-- UNIT_AURA still fires in combat; its contents are hidden, but it says when
-- to look.
ns.OnUnit("UNIT_AURA", "player", RequestCheck)
ns.On("PLAYER_REGEN_DISABLED", RequestCheck) -- (the silent first look)
ns.On("PLAYER_REGEN_ENABLED", function()
	wipe(up)
	silent = true
end)

-- For /fprocs status: what a lookup by name gives right now.
function TalentBuffs.Describe()
	local parts = {}
	for _, p in ipairs(Names()) do
		local found = Lookup(p.name)
		parts[#parts + 1] = p.name .. " (" .. (found == nil and "hidden" or found and "on you" or "not on you") .. ")"
	end
	return #parts > 0 and table.concat(parts, ", ") or "none"
end
