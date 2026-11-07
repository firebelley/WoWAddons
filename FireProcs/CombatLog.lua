-- One-off procs that leave no buff on you, from the combat log: on-hit heals
-- (racials, Lifestealing), stuns and debuffs from talents (Impact, Mace Stun,
-- Blackout, Winter's Chill), extra attacks (Windfury, Sword Specialization),
-- mana or rage returns (Illumination), buffs on others (Inspiration)...
local _, ns = ...
local API, Spells = ns.API, ns.Spells

local band = bit.band
local HOSTILE = COMBATLOG_OBJECT_REACTION_HOSTILE or 0x40
local FRIENDLY = COMBATLOG_OBJECT_REACTION_FRIENDLY or 0x10

-- Periodic ticks (DoTs, HoTs) are left out on purpose.
local EVENTS = {
	SPELL_DAMAGE = true, SPELL_HEAL = true, SPELL_ENERGIZE = true,
	SPELL_LEECH = true, SPELL_EXTRA_ATTACKS = true, SPELL_AURA_APPLIED = true,
}

local playerGUID

local function IconFromUnit(guid, name, filter)
	for _, unit in ipairs({ "target", "focus", "mouseover" }) do
		if UnitExists(unit) and UnitGUID(unit) == guid then
			local icon
			API.ForEachAura(unit, filter, function(a)
				if not icon and a.name == name then icon = a.icon end
			end)
			return icon
		end
	end
end

-- Status for /fprocs debug.
local CombatLog = { registered = false, problem = nil, events = 0, mine = 0 }
ns.CombatLog = CombatLog

-- Debug lines are printed once per effect, or the chat would scroll away.
local traced = {}
local function Trace(sub, name, msg)
	if not ns.tracing then return end
	local key = sub .. "\031" .. tostring(name)
	if traced[key] then return end
	traced[key] = true
	ns.Trace(("log %s %s: %s"):format(sub, tostring(name), msg))
end
function CombatLog.ResetTrace() wipe(traced) end

local function Handle(_, sub, _, _, _, _, _, dstGUID, _, dstFlags, _, spellID, spellName, _, auraType)
	if not spellName or spellName == "" then return end
	local icon
	if sub == "SPELL_AURA_APPLIED" then
		if dstGUID == playerGUID then return end -- your own buffs are handled in Auras.lua
		local flags = dstFlags or 0
		if auraType == "DEBUFF" then
			if band(flags, HOSTILE) == 0 then return Trace(sub, spellName, "skipped, debuff on a non-enemy") end
		elseif band(flags, FRIENDLY) == 0 then
			return Trace(sub, spellName, "skipped, buff on a non-friend")
		end
		icon = IconFromUnit(dstGUID, spellName, auraType == "DEBUFF" and "HARMFUL" or "HELPFUL")
	end

	if Spells.count == 0 then return Trace(sub, spellName, "skipped, spellbook not loaded yet") end
	local own = Spells.OwnSpellFor(spellName)
	if own then return Trace(sub, spellName, "skipped, belongs to your spell " .. Spells.Describe(own)) end
	if Spells.WasRecentlyCast(spellName, spellID) then return Trace(sub, spellName, "skipped, you just cast or used it") end
	if icon then Spells.RememberIcon(spellName, icon) end
	if ns.Proc(spellName, icon or Spells.Icon(spellID, spellName), "event") then
		Trace(sub, spellName, "announced")
	end
end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function()
	CombatLog.events = CombatLog.events + 1
	-- Cheap checks first: this fires for every hit from everyone around you.
	local _, sub, _, srcGUID = CombatLogGetCurrentEventInfo()
	if srcGUID ~= playerGUID then return end
	CombatLog.mine = CombatLog.mine + 1
	if not EVENTS[sub] then
		if ns.tracing and sub:sub(1, 6) == "SPELL_" then
			Trace(sub, (select(13, CombatLogGetCurrentEventInfo())), "skipped, this kind of entry isn't watched")
		end
		return
	end
	ns.SafeCall(Handle, CombatLogGetCurrentEventInfo())
end)

ns.On("PLAYER_LOGIN", function()
	playerGUID = UnitGUID("player")
	if not CombatLogGetCurrentEventInfo then
		CombatLog.problem = "this client has no CombatLogGetCurrentEventInfo"
		return
	end
	local ok, err = pcall(frame.RegisterEvent, frame, "COMBAT_LOG_EVENT_UNFILTERED")
	CombatLog.registered = ok and frame:IsEventRegistered("COMBAT_LOG_EVENT_UNFILTERED") and true or false
	if not ok then
		CombatLog.problem = tostring(err)
	elseif not CombatLog.registered then
		CombatLog.problem = "the client refused to let addons listen"
	end
end)
