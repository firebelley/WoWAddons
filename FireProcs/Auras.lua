-- Proc buffs: buffs from you that you didn't cast - Clearcasting, Flurry,
-- Enrage, Shadow Trance, Holy Strength (Crusader), trinket and set procs...
-- Plus long buffs other players give you (Arcane Intellect, Fortitude...).
local _, ns = ...
local API, Spells = ns.API, ns.Spells

local STAY_MAX = 60 -- proc buffs up to this long get an icon until they end;
                    -- longer ones only get the announcement

local Auras = {}
ns.Auras = Auras

local present = {} -- candidate buffs at the last scan, by key
local seen = {}    -- every buff at the last scan, by key (for debug output)
local procs = {}   -- keys of buffs announced as procs (shown in the icon row)
local lastSignature
local live = false -- false while taking the silent first look after loading
local wasRestricted = false

-- In combat, this client hides most buffs from addons (only some spells' buffs
-- stay readable). Readable ones are handled as usual; hidden ones are assumed
-- unchanged until combat ends, when everything is quietly re-checked.
Auras.hidden = 0

-- Returns "proc", "gift" (a long buff from someone else) or nil plus the reason.
local function Classify(a)
	-- Some procs carry no caster at all; a short buff with nobody behind it is
	-- treated as yours (buffs from group members name them: "party1"...).
	local mine = a.source == "player" or (a.source == nil and a.duration > 0 and a.duration <= STAY_MAX)
	if mine then
		-- Permanent buffs are passives and stances, never procs.
		if a.duration <= 0 then return nil, "permanent (passive, stance or aura)" end
		local own = Spells.OwnSpellFor(a.name)
		if own then return nil, "belongs to your spell " .. Spells.Describe(own) end
		return "proc"
	end
	-- Short buffs from others are left out - healers' HoTs would never stop.
	if a.duration > STAY_MAX then return "gift" end
	return nil, ("from %s, %ss long (only buffs over %ss from others count)"):format(
		tostring(a.source), tostring(a.duration), STAY_MAX)
end

local function Describe(a)
	return ("%s (id %s, from %s, %ss)"):format(a.name, tostring(a.spellId), tostring(a.source), tostring(a.duration))
end

function Auras.Update()
	local restricted = API.AurasRestricted()
	-- Just left combat: buffs that were hidden reappear, but they aren't new.
	local resync = wasRestricted and not restricted
	wasRestricted = restricted

	local now, seenNow, sig = {}, {}, {}
	Auras.hidden = API.ForEachAura("player", "HELPFUL", function(a)
		Spells.RememberIcon(a.name, a.icon)
		local key = a.spellId or a.name
		seenNow[key] = true
		local kind, why = Classify(a)
		if kind then
			a.gift = kind == "gift"
			now[key] = a
		else
			if a.source == "player" then
				sig[#sig + 1] = a.name -- your own spells: stealth, shouts, seals...
			end
			if live and not seen[key] then
				ns.Trace("buff " .. Describe(a) .. " skipped: " .. why)
			end
		end
	end)
	API.ForEachAura("player", "HARMFUL", function(a) sig[#sig + 1] = a.name end)
	seen = seenNow

	if restricted then
		local t = GetTime()
		for key, a in pairs(present) do
			if not now[key] and API.AuraIsSecret(a.spellId) and (a.expires == 0 or a.expires > t) then
				now[key] = a
			end
		end
	end

	-- Gaining or losing one of these (stealth, Forbearance, a stun...) changes what
	-- you can cast, which mustn't be mistaken for an ability lighting up.
	table.sort(sig)
	local signature = table.concat(sig, "\031")
	if lastSignature and signature ~= lastSignature then ns.Reactive.Quiet() end
	lastSignature = signature

	if live and not resync and Spells.count > 0 then
		for key, a in pairs(now) do
			if not present[key] then
				if not a.gift and Spells.WasRecentlyCast(a.name, a.spellId) then
					ns.Trace("buff " .. Describe(a) .. " skipped: you just cast or used it")
				elseif ns.Proc(a.name, a.icon, "aura", a.gift and "detectGifts" or "detectBuffs") then
					ns.Trace("buff " .. Describe(a) .. " announced")
					if a.duration <= STAY_MAX then procs[key] = true end
				end
			end
		end
	end
	present = now

	local list = {}
	for key in pairs(procs) do
		local a = now[key]
		if a and not ns.db.muted[a.name] then
			list[#list + 1] = a
		else
			procs[key] = nil
		end
	end
	table.sort(list, function(x, y) return x.name < y.name end)
	ns.Display.SetAuras(list)
end

-- For /fprocs debug: what FireProcs makes of every buff you have right now.
function Auras.DescribeCurrent()
	local any = false
	local hidden = API.ForEachAura("player", "HELPFUL", function(a)
		any = true
		local kind, why = Classify(a)
		ns.Trace("  " .. Describe(a) .. ": " .. (kind and ("counts (" .. kind .. ")") or ("skipped, " .. why)))
	end)
	if not any then ns.Trace("  (no readable buffs)") end
	if hidden > 0 then ns.Trace(("  + %d buff(s) hidden from addons right now"):format(hidden)) end
end

ns.OnUnit("UNIT_AURA", "player", function() Auras.Update() end)

-- After any loading screen, take a silent look so existing buffs aren't announced.
ns.On("PLAYER_ENTERING_WORLD", function()
	live = false
	Auras.Update()
	live = true
end)
