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
--    Nature). If it's blanked: a group member who can heal (priest, druid,
--    paladin, shaman - alive, online, in range) and who cast a heal recently
--    enough that it may still be ticking on you, going by that spell's tooltip.
--    Groups with no such healer around count as being solo.
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

---------------------------------------------------------------------------
-- Group healers
---------------------------------------------------------------------------
local HEALER_CLASSES = { PRIEST = true, DRUID = true, PALADIN = true, SHAMAN = true }
local HEAL_MOMENT = 2.5   -- a direct heal lands right as its cast finishes
local MAX_WINDOW = 60     -- longer tooltip times are buffs (Fortitude), not heals
local UNKNOWN_WINDOW = 21 -- spell hidden or unknown: assume the longest HoT (Regrowth)
local groupHealUntil, groupHealer = 0, nil
local spellIdsHidden = false

local function GroupUnits()
	local list = {}
	if IsInRaid and IsInRaid() then
		for i = 1, 40 do list[#list + 1] = "raid" .. i end
	else
		for i = 1, 4 do list[#list + 1] = "party" .. i end
	end
	return list
end

local function IsGroupUnit(unit)
	return type(unit) == "string" and (unit:match("^party%d+$") or unit:match("^raid%d+$"))
		and not UnitIsUnit(unit, "player")
end

-- True unless the game says for sure they're out of range.
local function MaybeInRange(unit)
	if not UnitInRange then return true end
	local ok, inRange, checked = pcall(UnitInRange, unit)
	if not ok or IsSecret(inRange) or IsSecret(checked) then return true end
	return inRange or not checked
end

-- Someone in your group who could be healing you right now.
local function HealerNearby()
	for _, unit in ipairs(GroupUnits()) do
		if UnitExists(unit) and not UnitIsUnit(unit, "player") then
			local _, class = UnitClass(unit)
			if class and not IsSecret(class) and HEALER_CLASSES[class]
				and UnitIsConnected(unit) and not UnitIsDeadOrGhost(unit) and MaybeInRange(unit) then
				return UnitName(unit) or unit
			end
		end
	end
end

-- A group healer finished a cast (or began a channel like Tranquility).
local function OnGroupCast(unit, _, spellID)
	if not IsGroupUnit(unit) then return end
	local _, class = UnitClass(unit)
	if not (class and HEALER_CLASSES[class]) then return end

	local window
	if spellID == nil or IsSecret(spellID) then
		spellIdsHidden = true
		window = UNKNOWN_WINDOW
	elseif API.SpellDescription(spellID) == "" then
		window = UNKNOWN_WINDOW -- spell data not loaded yet: play safe
	elseif Spells.Heals(spellID) then
		-- Totems and Vampiric Embrace say "Lasts 1 min", so minutes count too.
		local longest = Spells.LongestDuration(spellID)
		for n in API.SpellDescription(spellID):gmatch("(%d+%.?%d*) min") do
			longest = math.max(longest, (tonumber(n) or 0) * 60)
		end
		window = math.max(HEAL_MOMENT, math.min(MAX_WINDOW, longest))
	end
	if window and GetTime() + window > groupHealUntil then
		groupHealUntil = GetTime() + window
		groupHealer = (UnitName(unit) or unit) .. "'s " ..
			((spellID and not IsSecret(spellID) and API.SpellInfo(spellID)) or "spell")
	end
end
ns.On("UNIT_SPELLCAST_SUCCEEDED", OnGroupCast)
ns.On("UNIT_SPELLCAST_CHANNEL_START", OnGroupCast)

function Drain.DescribeGroup()
	if not (IsInGroup and IsInGroup()) then return "not in a group" end
	local healer = HealerNearby()
	if not healer then return "in a group, no healer nearby (works like solo)" end
	local left = groupHealUntil - GetTime()
	return ("healer nearby (%s)%s%s"):format(healer,
		left > 0 and (", " .. groupHealer .. " may be healing you for " .. math.ceil(left) .. "s more") or ", no recent heals",
		spellIdsHidden and "; the game hides which spells group members cast" or "")
end

---------------------------------------------------------------------------
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
		if GetTime() < groupHealUntil then
			return groupHealer .. " may still be healing you"
		end
		-- No group heal can still be running, so a heal is as telling as solo.
		-- (A HoT cast before you joined the group could slip through - rare.)
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
	ns.Proc(p.name, p.icon, "drain", "detectDrain")
end)
