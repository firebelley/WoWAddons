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

---------------------------------------------------------------------------
-- Secret values: in combat this client hides most combat data from addons.
-- Hidden values can't be compared or used in maths, so check first.
---------------------------------------------------------------------------
function API.IsSecret(v)
	return issecretvalue ~= nil and issecretvalue(v) and true or false
end

-- True while your buffs are (mostly) hidden from addons, i.e. in combat.
function API.AurasRestricted()
	local S = C_Secrets
	if not (S and S.ShouldAurasBeSecret) then return false end
	local ok, secret = pcall(S.ShouldAurasBeSecret)
	return ok and secret and true or false
end

-- True if this spell's buff is hidden from addons right now.
function API.AuraIsSecret(spellID)
	local S = C_Secrets
	if not (spellID and S and S.ShouldSpellAuraBeSecret) then return false end
	local ok, secret = pcall(S.ShouldSpellAuraBeSecret, spellID)
	return ok and secret and true or false
end

-- Total power cost of a spell right now (procs like Clearcasting make it 0),
-- or nil if unknown/hidden.
function API.SpellCost(spellID)
	local costs
	if C_Spell and C_Spell.GetSpellPowerCost then
		local ok, result = pcall(C_Spell.GetSpellPowerCost, spellID)
		if ok then costs = result end
	elseif GetSpellPowerCost then
		local ok, result = pcall(GetSpellPowerCost, spellID)
		if ok then costs = result end
	end
	if type(costs) ~= "table" or API.IsSecret(costs) then return nil end
	local total = 0
	for _, c in ipairs(costs) do
		local v = c.cost
		if API.IsSecret(v) then return nil end
		total = total + (v or 0)
	end
	return total
end

-- Cast time in ms right now (procs like Shadow Trance make it 0), or nil.
function API.CastTime(spellID)
	if C_Spell and C_Spell.GetSpellInfo then
		local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
		if ok and type(info) == "table" then
			local t = info.castTime
			if API.IsSecret(t) then return nil end
			return t
		end
	end
	if GetSpellInfo then
		local ok, _, _, _, t = pcall(GetSpellInfo, spellID)
		if ok and not API.IsSecret(t) then return t end
	end
	return nil
end

-- True for attack spells (Frostbolt, Arcane Blast...), false for buffs, heals,
-- items and anything unknown.
function API.IsHarmfulSpell(spellID)
	if C_Spell and C_Spell.IsSpellHarmful then
		local ok, harmful = pcall(C_Spell.IsSpellHarmful, spellID)
		if ok and not API.IsSecret(harmful) then return harmful and true or false end
	end
	if IsHarmfulSpell then
		local name = API.SpellInfo(spellID)
		local ok, harmful = pcall(IsHarmfulSpell, name or spellID)
		if ok then return harmful and true or false end
	end
	return false
end

-- start, duration (0, 0 when not on cooldown or when hidden in combat)
function API.SpellCooldown(spell)
	local start, duration = 0, 0
	if C_Spell and C_Spell.GetSpellCooldown then
		local ok, info = pcall(C_Spell.GetSpellCooldown, spell)
		if ok and type(info) == "table" then start, duration = info.startTime, info.duration end
	elseif GetSpellCooldown then
		local ok, s, d = pcall(GetSpellCooldown, spell)
		if ok then start, duration = s, d end
	end
	if API.IsSecret(start) or API.IsSecret(duration) then return 0, 0 end
	return start or 0, duration or 0
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

-- Calls fn(aura) for each aura on the unit that addons may read, where aura is
-- { name, icon, count, duration, expires, source, spellId }. Hidden (secret)
-- auras are skipped; returns how many were skipped.
local MAX_HIDDEN_RUN = 40 -- stop after this many hidden slots in a row

local function Readable(a)
	local S = API.IsSecret
	return not (S(a.name) or S(a.spellId) or S(a.duration) or S(a.expirationTime) or S(a.sourceUnit))
end

function API.ForEachAura(unit, filter, fn)
	local hidden = 0
	if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
		local S = C_Secrets
		local hiddenRun = 0
		for i = 1, 255 do
			local secret = false
			if S and S.ShouldUnitAuraIndexBeSecret then
				local ok, result = pcall(S.ShouldUnitAuraIndexBeSecret, unit, i, filter)
				secret = ok and result
			end
			local ok, a
			if not secret then
				ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, filter)
				if ok and not a then return hidden end -- past the last aura
			end
			if secret or not ok or not Readable(a) then
				hidden = hidden + 1
				hiddenRun = hiddenRun + 1
				if hiddenRun >= MAX_HIDDEN_RUN then return hidden end
			else
				hiddenRun = 0
				local count = a.applications
				fn({
					name = a.name, icon = a.icon,
					count = (not API.IsSecret(count) and count) or 0,
					duration = a.duration or 0, expires = a.expirationTime or 0,
					source = a.sourceUnit, spellId = a.spellId,
					instance = not API.IsSecret(a.auraInstanceID) and a.auraInstanceID or nil,
				})
			end
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
	return hidden
end

-- The set { [auraInstanceID] = true } of every buff on you, or nil if unknown.
-- Unlike the buffs themselves, these IDs stay readable in combat, so a buff
-- seen out of combat can be checked for later by its ID.
function API.AuraInstanceIDs(unit, filter)
	local fn = C_UnitAuras and C_UnitAuras.GetUnitAuraInstanceIDs
	if not fn then return nil end
	local ok, ids = pcall(fn, unit, filter)
	if not ok or type(ids) ~= "table" or API.IsSecret(ids) then return nil end
	local set = {}
	for _, id in ipairs(ids) do
		if API.IsSecret(id) then return nil end
		set[id] = true
	end
	return set
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
