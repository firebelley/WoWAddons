-- Procs that change your spells: Missile Barrage (Arcane Missiles costs no
-- mana), Clearcasting (your next spell is free), Shadow Trance / Nightfall
-- (Shadow Bolt becomes instant)...
--
-- In combat this client hides your buffs from addons completely - not even
-- their number can be read. But a spell's cost and cast time are not buffs:
-- when one of your spells suddenly costs nothing or casts instantly, without
-- you having just cast something like Presence of Mind, a proc did it.
--
-- The announcement is named after the talent that caused it: the passive in
-- your spellbook whose tooltip mentions both a "chance" and the changed spell
-- (or "mana cost" when many spells changed at once, like Clearcasting).
local _, ns = ...
local API, Spells = ns.API, ns.Spells

local EXPLAIN_WINDOW = 0.6 -- seconds after your own non-attack cast (Presence of Mind...)
local MANY = 3             -- this many spells changing at once = a "your next spell" proc
local CHECK_DELAY = 0.05

local Changes = { checks = 0 }
ns.Changes = Changes

local last = {} -- [spellID] = { cost, cast } at the previous check

-- The talent behind a change, by its tooltip.
local function FindPassive(spellName)
	for _, p in ipairs(Spells.passives or {}) do
		local d = p.desc
		if d:find("chance", 1, true) then
			if spellName then
				if d:find(spellName:lower(), 1, true) then return p end
			elseif d:find("mana cost", 1, true) or d:find("clearcasting", 1, true) then
				return p
			end
		end
	end
end

local function Announce(changed)
	if #changed >= MANY then
		local p = FindPassive(nil)
		ns.Trace(("%d spells became free/instant at once: announced as %s"):format(#changed, p and p.name or "free spells"))
		ns.Proc(p and p.name or "Free spells", p and p.icon, "aura")
		return
	end
	for _, c in ipairs(changed) do
		local p = FindPassive(c.spell.name)
		local name = p and p.name or (c.spell.name .. (c.what == "free" and " is free" or " is instant"))
		ns.Trace(("%s became %s: announced as %s"):format(c.spell.name, c.what, name))
		ns.Proc(name, p and p.icon or c.spell.icon, "aura")
	end
end

local function Check()
	Changes.checks = Changes.checks + 1
	local changed = {}
	for _, s in ipairs(Spells.reactive) do
		local cost, cast = API.SpellCost(s.id), API.CastTime(s.id)
		local prev = last[s.id]
		if prev then
			if prev.cost and cost and prev.cost > 0 and cost == 0 then
				changed[#changed + 1] = { spell = s, what = "free" }
			elseif prev.cast and cast and prev.cast > 0 and cast == 0 then
				changed[#changed + 1] = { spell = s, what = "instant" }
			end
		end
		last[s.id] = { cost = cost, cast = cast }
	end

	if #changed == 0 or not UnitAffectingCombat("player") then return end
	if GetTime() - Spells.lastHelpfulCastAt < EXPLAIN_WINDOW then
		ns.Trace(("%d spell(s) became free/instant right after you cast %s: assumed to be from that"):format(
			#changed, tostring(Spells.lastHelpfulCastName)))
		return
	end
	Announce(changed)
end

local queued = false
local function RequestCheck()
	if queued then return end
	queued = true
	C_Timer.After(CHECK_DELAY, function()
		queued = false
		ns.SafeCall(Check)
	end)
end

-- UNIT_AURA still fires in combat (its contents are hidden, but we only need
-- to know something changed).
ns.OnUnit("UNIT_AURA", "player", RequestCheck)
ns.On("SPELL_UPDATE_USABLE", RequestCheck)
ns.On("SPELLS_CHANGED", function() wipe(last) end)

-- For /fprocs status: what the game reports for a spell right now.
function Changes.Describe(spellID)
	local cost, cast = API.SpellCost(spellID), API.CastTime(spellID)
	return ("%s: cost %s, cast time %s"):format(tostring(API.SpellInfo(spellID)),
		cost == nil and "hidden/unknown" or tostring(cost), cast == nil and "hidden/unknown" or tostring(cast))
end
