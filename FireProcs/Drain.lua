-- Life-drain procs (Touch of the Grave, Lifestealing...) that this client only
-- reports in the combat log, which addons can't read.
--
-- The game still tells addons "you were just healed" (UNIT_COMBAT). The amount
-- is hidden and the school is often blanked to 1 (physical - no real heal is
-- physical), but the fact that a heal landed is enough. During combat, a heal on
-- you that nothing you did explains is a drain proc. Explanations ruled out:
--  * you're channeling (Drain Life, bandages)
--  * you cast/used something that heals and may still be (Death Coil,
--    Healthstone, potion, Siphon Life for as long as its tooltip says)
--  * your own heal-over-time on you (Renew)
--  * a healer: if the school is real, only Shadow counts (healers use Holy and
--    Nature); if it's blanked, only while you're not in a group.
local _, ns = ...
local API, Spells = ns.API, ns.Spells

local band = bit.band
local PHYSICAL, SHADOW = 1, 32 -- school masks

local Drain = { heals = 0, secret = 0 }
ns.Drain = Drain

local function IsSecret(v)
	return issecretvalue ~= nil and issecretvalue(v)
end

-- Debug output, capped so a long fight doesn't flood chat.
local traceCount = 0
local function Trace(msg)
	if not ns.tracing or traceCount >= 15 then return end
	traceCount = traceCount + 1
	ns.Trace(msg)
end
function Drain.ResetTrace() traceCount = 0 end

local function IsChanneling()
	if UnitChannelInfo then return UnitChannelInfo("player") ~= nil end
	if ChannelInfo then return ChannelInfo() ~= nil end
	return false
end

-- A heal-over-time of yours on you (Renew...). Only your own buffs are read:
-- this client hides enemies' auras from addons during combat. Drains you put on
-- the target (Siphon Life) are covered by Spells.healUntil instead.
local function OwnHealingAura()
	local found
	-- Short ones only: armors and other long buffs mention "health" too.
	local ok = pcall(API.ForEachAura, "player", "HELPFUL", function(a)
		if not found and a.source == "player" and a.duration > 0 and a.duration <= 60
			and Spells.Heals(a.spellId) then
			found = a.name
		end
	end)
	return ok and found or nil
end

-- Returns nil if it's a drain proc, or why not.
local function WhyNot(school)
	-- Characters without a drain passive (e.g. a non-undead mage) have nothing
	-- to detect, so their unexplained heals are never guessed at.
	if not Spells.drainPassive then return "you have no passive that drains or heals by chance" end
	if not UnitAffectingCombat("player") then return "out of combat" end
	if IsChanneling() then return "you're channeling" end
	if GetTime() < Spells.healUntil then return "something you cast or used may still be healing you" end
	local aura = OwnHealingAura()
	if aura then return "your " .. aura .. " heals you" end

	local known = type(school) == "number" and not IsSecret(school) and school ~= PHYSICAL
	if known then
		if band(school, SHADOW) == 0 then return "school " .. school .. " isn't shadow" end
	elseif IsInGroup and IsInGroup() then
		return "school hidden and you're in a group (could be a healer)"
	end
end

ns.OnUnit("UNIT_COMBAT", "player", function(_, action, _, _, school)
	if IsSecret(action) then
		Drain.secret = Drain.secret + 1
		return Trace("hit/heal on you, kind hidden")
	end
	if action ~= "HEAL" then return end
	Drain.heals = Drain.heals + 1

	local why = WhyNot(school)
	Trace(("heal on you (school %s): %s"):format(
		IsSecret(school) and "hidden" or tostring(school), why and ("skipped, " .. why) or "announced"))
	if why then return end

	local p = Spells.drainPassive
	ns.Proc(p.name, p.icon, "drain")
end)
