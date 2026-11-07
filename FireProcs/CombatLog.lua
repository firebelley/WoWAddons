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

local function Handle(_, sub, _, _, _, _, _, dstGUID, _, dstFlags, _, spellID, spellName, _, auraType)
	if not spellName or spellName == "" then return end
	local icon
	if sub == "SPELL_AURA_APPLIED" then
		if dstGUID == playerGUID then return end -- your own buffs are handled in Auras.lua
		local flags = dstFlags or 0
		if auraType == "DEBUFF" then
			if band(flags, HOSTILE) == 0 then return end
		elseif band(flags, FRIENDLY) == 0 then
			return
		end
		icon = IconFromUnit(dstGUID, spellName, auraType == "DEBUFF" and "HARMFUL" or "HELPFUL")
	end

	if Spells.count == 0 or Spells.IsOwnSpellName(spellName) then return end
	if Spells.WasRecentlyCast(spellName, spellID) then return end
	if icon then Spells.RememberIcon(spellName, icon) end
	ns.Proc(spellName, icon or Spells.Icon(spellID, spellName), "event")
end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function()
	-- Cheap checks first: this fires for every hit from everyone around you.
	local _, sub, _, srcGUID = CombatLogGetCurrentEventInfo()
	if srcGUID ~= playerGUID or not EVENTS[sub] then return end
	ns.SafeCall(Handle, CombatLogGetCurrentEventInfo())
end)

ns.On("PLAYER_LOGIN", function()
	playerGUID = UnitGUID("player")
	if CombatLogGetCurrentEventInfo then
		pcall(frame.RegisterEvent, frame, "COMBAT_LOG_EVENT_UNFILTERED")
	end
end)
