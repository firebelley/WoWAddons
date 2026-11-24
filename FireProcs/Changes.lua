-- Procs that change your spells: Missile Barrage (Arcane Missiles costs no
-- mana), Clearcasting (your next spell is free), Shadow Trance / Nightfall
-- (Shadow Bolt becomes instant), Decimation (Soul Fire casts 40% faster)...
--
-- In combat this client hides your buffs from addons completely - not even
-- their number can be read. But a spell's cost and cast time are not buffs:
-- when one of your spells suddenly costs nothing, casts instantly or casts
-- much faster, without you having just cast something like Presence of Mind,
-- a proc did it. "Much faster" only counts when your other spells didn't
-- speed up too - haste (Bloodlust, a haste trinket) speeds up everything alike.
--
-- The announcement is named after the talent that caused it: the passive in
-- your spellbook whose tooltip mentions both a "chance" and the changed spell
-- (or "mana cost" when many spells changed at once, like Clearcasting). Some
-- procs have no chance - Decimation always happens below 35% health - so a
-- talent naming the spell and lasting a while ("lasts 10 sec") counts too.
local _, ns = ...
local API, Spells = ns.API, ns.Spells

local EXPLAIN_WINDOW = 0.6 -- seconds after your own non-attack cast (Presence of Mind...)
local MANY = 3             -- this many spells changing at once = a "your next spell" proc
local FASTER = 0.8         -- cast time at most this fraction of before = "much faster"
local CHECK_DELAY = 0.05

local Changes = { checks = 0 }
ns.Changes = Changes

local last = {} -- [spellID] = { cost, cast } at the previous check
local ratios = {} -- every spell's cast time now / before, this check (kept between checks)

-- A talent's effect that lasts a while after it triggers: "lasts 10 sec",
-- "for 10 sec", "your next Soul Fire", "cast under the effect of Decimation".
-- (Not "by 2 sec": that's a permanent cast time reduction, like Bane.)
local function Temporary(d, name)
	return d:find("lasts", 1, true) or d:find("for %d+%.?%d* sec") or d:find("your next", 1, true)
		or d:find("effect of " .. name:lower(), 1, true)
end

-- The talent behind a change, by its tooltip.
local function FindPassive(spellName)
	local fallback
	for _, p in ipairs(Spells.passives or {}) do
		local d = Spells.PassiveText(p) -- (re-read if it was still loading)
		if spellName then
			if d:find(spellName:lower(), 1, true) then
				if d:find("chance", 1, true) then return p end
				if not fallback and Temporary(d, p.name) then fallback = p end
			end
		elseif d:find("chance", 1, true) and (d:find("mana cost", 1, true) or d:find("clearcasting", 1, true)) then
			return p
		end
	end
	return fallback
end

local WHAT = { free = " is free", instant = " is instant", faster = " casts faster" }

local function Announce(changed)
	if #changed >= MANY then
		local p = FindPassive(nil)
		ns.Trace(("%d spells became free/instant at once: announced as %s"):format(#changed, p and p.name or "free spells"))
		ns.Proc(p and p.name or "Free spells", p and p.icon, "aura", "detectChanges")
		return
	end
	for _, c in ipairs(changed) do
		local p = FindPassive(c.spell.name)
		local name = p and p.name or (c.spell.name .. WHAT[c.what])
		ns.Trace(("%s became %s: announced as %s"):format(c.spell.name, c.what, name))
		ns.Proc(name, p and p.icon or c.spell.icon, "aura", "detectChanges")
	end
end

local function Check()
	Changes.checks = Changes.checks + 1
	local changed = {}
	local faster = 0
	wipe(ratios)
	for _, s in ipairs(Spells.reactive) do
		local cost, cast = API.SpellCost(s.id), API.CastTime(s.id)
		local prev = last[s.id]
		if prev then
			if prev.cost and cost and prev.cost > 0 and cost == 0 then
				changed[#changed + 1] = { spell = s, what = "free" }
			elseif prev.cast and cast and prev.cast > 0 and cast == 0 then
				changed[#changed + 1] = { spell = s, what = "instant" }
			elseif prev.cast and cast and prev.cast > 0 and cast > 0 then
				local r = cast / prev.cast
				ratios[#ratios + 1] = r
				if r <= FASTER then
					changed[#changed + 1] = { spell = s, what = "faster", ratio = r }
					faster = faster + 1
				end
			end
			prev.cost, prev.cast = cost, cast -- (kept, not remade: this runs for every spell, often)
		else
			last[s.id] = { cost = cost, cast = cast }
		end
	end

	-- "Faster" only counts for a spell that sped up much more than your spells
	-- in general (the middle one of all of them): haste speeds up everything.
	if faster > 0 then
		local typical = 1
		if #ratios >= 3 then
			table.sort(ratios)
			typical = ratios[math.ceil(#ratios / 2)]
		end
		for i = #changed, 1, -1 do
			local c = changed[i]
			if c.what == "faster" and c.ratio > typical * FASTER then
				ns.Trace(("%s cast %d%% faster, but so did your other spells (haste?) - not a proc"):format(
					c.spell.name, math.floor((1 - c.ratio) * 100 + 0.5)))
				table.remove(changed, i)
			end
		end
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
local function QueuedCheck()
	queued = false
	ns.SafeCall(Check)
end
local function RequestCheck()
	if queued then return end
	queued = true
	C_Timer.After(CHECK_DELAY, QueuedCheck)
end

-- UNIT_AURA still fires in combat (its contents are hidden, but we only need
-- to know something changed).
ns.OnUnit("UNIT_AURA", "player", RequestCheck)
ns.On("SPELL_UPDATE_USABLE", RequestCheck)
ns.On("SPELLS_CHANGED", function() wipe(last) end)

-- For /fprocs status: what the game reports for a spell right now.
function Changes.Describe(spellID)
	local cost, cast = API.SpellCost(spellID), API.CastTime(spellID)
	local name = API.SpellInfo(spellID)
	local p = name and FindPassive(name)
	local found = p and p.name
	if not found then
		-- Say what was read, so a tooltip worded differently can be spotted.
		local mention, empty = {}, 0
		for _, q in ipairs(Spells.passives or {}) do
			local d = Spells.PassiveText(q)
			if d == "" then
				empty = empty + 1
			elseif name and d:find(name:lower(), 1, true) then
				mention[#mention + 1] = ("%s (\"%s\")"):format(q.name, d)
			end
		end
		found = ("none found among %d passives/talents (%d with no text yet). Mentioning %s: %s"):format(
			#(Spells.passives or {}), empty, tostring(name), #mention > 0 and table.concat(mention, "; ") or "none")
	end
	return ("%s: cost %s, cast time %s; its proc talent: %s"):format(tostring(name),
		cost == nil and "hidden/unknown" or tostring(cost), cast == nil and "hidden/unknown" or tostring(cast), found)
end
