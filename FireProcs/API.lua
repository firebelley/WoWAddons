-- Thin wrappers over game APIs that moved or changed shape between client
-- versions. Each tries the modern API first, then the old global.
local _, ns = ...
local API = {}
ns.API = API

-- name, icon
function API.SpellInfo(spell)
	if not spell then return nil end
	if C_Spell and C_Spell.GetSpellInfo then
		local ok, info = pcall(C_Spell.GetSpellInfo, spell)
		if ok and type(info) == "table" then return info.name, info.iconID end
	end
	if GetSpellInfo then
		local ok, name, _, icon = pcall(GetSpellInfo, spell)
		if ok then return name, icon end
	end
	return nil
end

-- start, duration
function API.SpellCooldown(spell)
	if C_Spell and C_Spell.GetSpellCooldown then
		local ok, info = pcall(C_Spell.GetSpellCooldown, spell)
		if ok and type(info) == "table" then return info.startTime or 0, info.duration or 0 end
	end
	if GetSpellCooldown then
		local ok, start, duration = pcall(GetSpellCooldown, spell)
		if ok then return start or 0, duration or 0 end
	end
	return 0, 0
end

-- usable, notEnoughPower
function API.IsUsable(spell)
	if C_Spell and C_Spell.IsSpellUsable then
		local ok, usable, noPower = pcall(C_Spell.IsSpellUsable, spell)
		if ok then return usable, noPower end
	end
	if IsUsableSpell then
		local ok, usable, noPower = pcall(IsUsableSpell, spell)
		if ok then return usable, noPower end
	end
	return false, false
end

-- Calls fn(aura) for each aura on the unit, where aura is
-- { name, icon, count, duration, expires, source, spellId }.
function API.ForEachAura(unit, filter, fn)
	if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
		for i = 1, 255 do
			local a = C_UnitAuras.GetAuraDataByIndex(unit, i, filter)
			if not a then return end
			fn({
				name = a.name, icon = a.icon, count = a.applications or 0,
				duration = a.duration or 0, expires = a.expirationTime or 0,
				source = a.sourceUnit, spellId = a.spellId,
			})
		end
	elseif UnitAura then
		for i = 1, 40 do
			local name, icon, count, _, duration, expires, source, _, _, spellId = UnitAura(unit, i, filter)
			if not name then return end
			fn({
				name = name, icon = icon, count = count or 0,
				duration = duration or 0, expires = expires or 0,
				source = source, spellId = spellId,
			})
		end
	end
end

-- Calls fn(name, spellID, isPassive) for every spell in your spellbook.
function API.ForEachSpellbookSpell(fn)
	local SB = C_SpellBook
	if SB and SB.GetNumSpellBookSkillLines and SB.GetSpellBookSkillLineInfo and SB.GetSpellBookItemInfo then
		local bank = Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
		local spellType = Enum.SpellBookItemType and Enum.SpellBookItemType.Spell
		for line = 1, SB.GetNumSpellBookSkillLines() do
			local info = SB.GetSpellBookSkillLineInfo(line)
			if info then
				local first = (info.itemIndexOffset or 0) + 1
				for i = first, first + (info.numSpellBookItems or 0) - 1 do
					local item = SB.GetSpellBookItemInfo(i, bank)
					if item and item.spellID and (not spellType or item.itemType == spellType) then
						fn(item.name, item.spellID, item.isPassive)
					end
				end
			end
		end
		return
	end

	if not (GetNumSpellTabs and GetSpellTabInfo and GetSpellBookItemInfo) then return end
	local book = BOOKTYPE_SPELL or "spell"
	for tab = 1, GetNumSpellTabs() do
		local _, _, offset, numSpells = GetSpellTabInfo(tab)
		for i = (offset or 0) + 1, (offset or 0) + (numSpells or 0) do
			local kind, spellID = GetSpellBookItemInfo(i, book)
			if kind == "SPELL" and spellID then
				local name = GetSpellBookItemName and GetSpellBookItemName(i, book) or API.SpellInfo(spellID)
				local passive = IsPassiveSpell and IsPassiveSpell(i, book)
				fn(name, spellID, passive)
			end
		end
	end
end

-- The spell's tooltip text ("" if unknown or not loaded yet).
function API.SpellDescription(spellID)
	if not spellID then return "" end
	if C_Spell and C_Spell.GetSpellDescription then
		local ok, text = pcall(C_Spell.GetSpellDescription, spellID)
		if ok and type(text) == "string" then return text end
	end
	if GetSpellDescription then
		local ok, text = pcall(GetSpellDescription, spellID)
		if ok and type(text) == "string" then return text end
	end
	return ""
end

-- Second opinion on passives: the spellbook's own flag isn't always set for
-- talents and racials listed there. nil = can't tell.
function API.IsPassiveSpell(spellID)
	if C_Spell and C_Spell.IsSpellPassive then
		local ok, passive = pcall(C_Spell.IsSpellPassive, spellID)
		if ok and passive ~= nil then return passive end
	end
	if IsPassiveSpell then
		local ok, passive = pcall(IsPassiveSpell, spellID)
		if ok and passive ~= nil then return passive and true or false end
	end
	return nil
end

function API.TemplateExists(name)
	if C_XMLUtil and C_XMLUtil.GetTemplateInfo then
		local ok, info = pcall(C_XMLUtil.GetTemplateInfo, name)
		return ok and info ~= nil
	end
	return nil -- can't tell on this client
end

-- The "power aura" chime Blizzard plays for procs, with fallbacks.
local ALERT_SOUNDS = {
	SOUNDKIT and SOUNDKIT.UI_POWER_AURA_GENERIC,
	23287, -- UI_POWER_AURA_GENERIC
	SOUNDKIT and SOUNDKIT.MAP_PING,
	3175,  -- MAP_PING
}
function API.PlayAlertSound()
	for i = 1, #ALERT_SOUNDS do
		local id = ALERT_SOUNDS[i]
		if id then
			local ok, willPlay = pcall(PlaySound, id, "SFX")
			if ok and willPlay then return end
		end
	end
end
