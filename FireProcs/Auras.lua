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
local procs = {}   -- keys of buffs announced as procs (shown in the icon row)
local lastSignature
local live = false -- false while taking the silent first look after loading

-- Permanent buffs (duration 0) are passives and stances, never procs.
local function IsCandidate(a)
	return a.source == "player" and a.duration > 0 and not Spells.IsOwnSpellName(a.name)
end

-- Long buffs someone else gave you: Arcane Intellect, Fortitude, Blessings,
-- world buffs... Short ones are left out - healers' HoTs would never stop.
local function IsGift(a)
	return a.source ~= "player" and a.duration > STAY_MAX
end

function Auras.Update()
	local now, sig = {}, {}
	API.ForEachAura("player", "HELPFUL", function(a)
		Spells.RememberIcon(a.name, a.icon)
		if IsCandidate(a) then
			now[a.spellId or a.name] = a
		elseif IsGift(a) then
			a.gift = true
			now[a.spellId or a.name] = a
		elseif a.source == "player" then
			sig[#sig + 1] = a.name -- your own spells: stealth, shouts, seals...
		end
	end)
	API.ForEachAura("player", "HARMFUL", function(a) sig[#sig + 1] = a.name end)

	-- Gaining or losing one of these (stealth, Forbearance, a stun...) changes what
	-- you can cast, which mustn't be mistaken for an ability lighting up.
	table.sort(sig)
	local signature = table.concat(sig, "\031")
	if lastSignature and signature ~= lastSignature then ns.Reactive.Quiet() end
	lastSignature = signature

	if live and Spells.count > 0 then
		for key, a in pairs(now) do
			if not present[key] and (a.gift or not Spells.WasRecentlyCast(a.name, a.spellId)) then
				if ns.Proc(a.name, a.icon, "aura") and a.duration <= STAY_MAX then
					procs[key] = true
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

ns.OnUnit("UNIT_AURA", "player", function() Auras.Update() end)

-- After any loading screen, take a silent look so existing buffs aren't announced.
ns.On("PLAYER_ENTERING_WORLD", function()
	live = false
	Auras.Update()
	live = true
end)
