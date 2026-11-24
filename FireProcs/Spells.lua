-- What you can cast (your spellbook) and what you've just cast.
--
-- The core idea of FireProcs: a buff or effect from you that isn't a spell you
-- can cast, and that you didn't just trigger by using an item, must have come
-- from a talent, racial, set bonus, weapon or other passive - i.e. a proc.
local _, ns = ...
local API = ns.API

local Spells = {
	passives = {},
	active = {},   -- [name] = spellID for every castable (non-passive) spell
	reactive = {}, -- { name, id, icon } list, minus shapeshift forms
	count = 0,
}
ns.Spells = Spells

local RECENT_CAST = 2 -- seconds a cast/item use "explains" an effect with its name

local prefixCache = {}
local icons = {}
local recentByName, recentById, sentCasts = {}, {}, {}

---------------------------------------------------------------------------
-- Spellbook
---------------------------------------------------------------------------
local function FormNames()
	local names = {}
	if GetNumShapeshiftForms and GetShapeshiftFormInfo then
		for i = 1, GetNumShapeshiftForms() or 0 do
			local _, _, _, spellID = GetShapeshiftFormInfo(i)
			local name = spellID and API.SpellInfo(spellID)
			if name then names[name] = true end
		end
	end
	return names
end

-- A passive whose tooltip says it drains/heals by chance, e.g. Touch of the
-- Grave: "...chance to drain Health from the target". Drain.lua names its
-- announcements after it.
local function IsDrainPassive(spellID)
	local text = API.SpellDescription(spellID):lower()
	return (text:find("drain") and text:find("health")) or (text:find("chance") and text:find("heal"))
end

-- Your learned talents, with their tooltip text: talents like Missile Barrage
-- aren't in the spellbook, so their text is read from their tooltip.
-- Tooltip text can still be loading (at login especially): it then comes back
-- empty, and Spells.PassiveText reads it again when it's needed.
local scanner
local function TalentText(tab, i)
	local lines = {}
	local T = C_TooltipInfo
	if T and T.GetTalent then
		local ok, data = pcall(T.GetTalent, tab, i)
		if ok and type(data) == "table" and type(data.lines) == "table" then
			for l = 2, #data.lines do -- line 1 is the name
				local text = data.lines[l].leftText
				if type(text) == "string" and not API.IsSecret(text) then lines[#lines + 1] = text end
			end
		end
	end
	if #lines == 0 then
		scanner = scanner or CreateFrame("GameTooltip", "FireProcsScanTooltip", nil, "GameTooltipTemplate")
		scanner:SetOwner(UIParent, "ANCHOR_NONE")
		if pcall(scanner.SetTalent, scanner, tab, i) then
			for l = 2, scanner:NumLines() do
				local fs = _G["FireProcsScanTooltipTextLeft" .. l]
				local text = fs and fs:GetText()
				if type(text) == "string" and not API.IsSecret(text) then lines[#lines + 1] = text end
			end
		end
		scanner:Hide()
	end
	return table.concat(lines, " "):lower()
end

-- This client's talents are a talent tree (C_Traits), not the old talent
-- tabs: each learned node gives a spell, whose tooltip is its description.
-- Spells you can cast are skipped (they're in the spellbook already).
local function AddTraitTalents(list, active)
	local CT, T = C_ClassTalents, C_Traits
	if not (CT and CT.GetActiveConfigID and T and T.GetConfigInfo and T.GetTreeNodes and T.GetNodeInfo
		and T.GetEntryInfo and T.GetDefinitionInfo) then return end
	local configID = CT.GetActiveConfigID()
	local config = configID and T.GetConfigInfo(configID)
	if not (config and config.treeIDs) then return end
	local have = {}
	for _, p in ipairs(list) do have[p.name] = true end
	for _, treeID in ipairs(config.treeIDs) do
		for _, nodeID in ipairs(T.GetTreeNodes(treeID) or {}) do
			local node = T.GetNodeInfo(configID, nodeID)
			local entryID = node and node.activeEntry and node.activeEntry.entryID
			if entryID and ((node.ranksPurchased or 0) > 0 or (node.activeRank or 0) > 0) then
				local entry = T.GetEntryInfo(configID, entryID)
				local def = entry and entry.definitionID and T.GetDefinitionInfo(entry.definitionID)
				local spellID = def and (def.overriddenSpellID or def.spellID)
				local name, icon = API.SpellInfo(spellID)
				if name and not have[name] and not active[name] then
					have[name] = true
					list[#list + 1] = {
						name = name, id = spellID, icon = icon, talent = true,
						desc = API.SpellDescription(spellID):lower(),
					}
				end
			end
		end
	end
end

local function AddTalents(list)
	if not (GetNumTalentTabs and GetNumTalents and GetTalentInfo) then return end
	for tab = 1, GetNumTalentTabs() or 0 do
		for i = 1, GetNumTalents(tab) or 0 do
			local name, icon, _, _, rank = GetTalentInfo(tab, i)
			if name and type(rank) == "number" and rank > 0 then
				list[#list + 1] = { name = name, icon = icon, desc = TalentText(tab, i), talent = true, tab = tab, index = i }
			end
		end
	end
end

-- A passive's or talent's lower-case tooltip text, read again if it was still
-- loading before.
function Spells.PassiveText(p)
	if p.desc == "" then
		if p.id then
			p.desc = API.SpellDescription(p.id):lower()
		elseif p.tab then
			p.desc = TalentText(p.tab, p.index)
		end
	end
	return p.desc
end

function Spells.Rebuild()
	local active, count, drain, passives = {}, 0, nil, {}
	API.ForEachSpellbookSpell(function(name, spellID, isPassive)
		if not (name and spellID) then return end
		-- Passive talents/racials (Touch of the Grave, Missile Barrage...) share a
		-- name with their proc, so they must never count as castable.
		if not isPassive and not API.IsPassiveSpell(spellID) then
			if not active[name] then count = count + 1 end
			active[name] = spellID -- ranks are listed low to high; keep the highest
		else
			local _, icon = API.SpellInfo(spellID)
			local entry = { name = name, id = spellID, icon = icon, desc = API.SpellDescription(spellID):lower() }
			passives[#passives + 1] = entry
			if not drain and IsDrainPassive(spellID) then drain = entry end
		end
	end)
	local ok, err = pcall(AddTraitTalents, passives, active)
	if not ok then ns.Trace("couldn't read your talent tree: " .. tostring(err)) end
	pcall(AddTalents, passives)
	Spells.drainPassive = drain
	Spells.passives = passives -- passive spells and learned talents, with lower-case tooltip text

	-- Forms, stances and auras switch on/off with you, so they're never "procs".
	local forms, reactive = FormNames(), {}
	for name, spellID in pairs(active) do
		local _, icon = API.SpellInfo(spellID)
		if icon then icons[name] = icon end
		if not forms[name] then
			reactive[#reactive + 1] = { name = name, id = spellID, icon = icon }
		end
	end

	Spells.active, Spells.reactive, Spells.count = active, reactive, count
	wipe(prefixCache)
	if ns.Reactive then ns.Reactive.Quiet() end
end

local rebuildQueued = false
local function RequestRebuild()
	if rebuildQueued then return end
	rebuildQueued = true
	C_Timer.After(0.2, function()
		rebuildQueued = false
		ns.SafeCall(Spells.Rebuild)
	end)
end

-- True for your own spells and their direct side effects, which are named
-- after them: "Charge Stun", "Feral Charge Effect", "Judgement of Wisdom",
-- "Counterspell - Silenced", "Explosive Trap Effect"...
-- Returns the name of the spell of yours that `name` belongs to, or nil.
function Spells.OwnSpellFor(name)
	if not name then return nil end
	if Spells.active[name] then return name end
	local cached = prefixCache[name]
	if cached ~= nil then return cached or nil end

	cached = false
	for own in pairs(Spells.active) do
		local n = #own
		if #name > n + 1 and name:sub(1, n) == own then
			local nextChar = name:sub(n + 1, n + 1)
			if nextChar == " " or nextChar == ":" or nextChar == "-" or nextChar == "(" then
				cached = own
				break
			end
		end
	end
	prefixCache[name] = cached
	return cached or nil
end

function Spells.IsOwnSpellName(name)
	return Spells.OwnSpellFor(name) ~= nil
end

-- "Fireball (id 133)" for debug output.
function Spells.Describe(own)
	return ("%s (id %s)"):format(own, tostring(Spells.active[own]))
end

---------------------------------------------------------------------------
-- Icons: remember them wherever we see them, for effects that only give a name.
---------------------------------------------------------------------------
function Spells.RememberIcon(name, icon)
	if name and icon then icons[name] = icon end
end

function Spells.Icon(spellID, name)
	if spellID and spellID ~= 0 then
		local _, icon = API.SpellInfo(spellID)
		if icon then return icon end
	end
	if name then
		if icons[name] then return icons[name] end
		local _, icon = API.SpellInfo(name)
		return icon
	end
end

---------------------------------------------------------------------------
-- Recent casts. UNIT_SPELLCAST_SENT only fires for casts *you* start (spells,
-- potions, trinkets...), never for spells a talent triggers on its own.
---------------------------------------------------------------------------
-- Does this spell/item heal you? (Death Coil, Healthstone, potions...)
local healsCache = {}
function Spells.Heals(spellID)
	if not spellID then return false end
	local cached = healsCache[spellID]
	if cached == nil then
		local text = API.SpellDescription(spellID):lower()
		cached = (text:find("heal") or text:find("health")) and true or false
		if text ~= "" then healsCache[spellID] = cached end
	end
	return cached
end

-- Until when something you cast/used may still be healing you. Instant heals
-- (Death Coil, Healthstone) count for a moment; ones that last (Siphon Life:
-- "...every 3 sec. Lasts 30 sec.") for the longest time their tooltip mentions.
local HEAL_MOMENT = 2.5
Spells.healUntil = 0

local function LongestDuration(spellID)
	local longest = 0
	for n in API.SpellDescription(spellID):gmatch("(%d+%.?%d*) sec") do
		longest = math.max(longest, tonumber(n) or 0)
	end
	return longest
end
Spells.LongestDuration = LongestDuration

-- When you last cast a non-attack spell or used an item: buffs appearing right
-- then are probably that spell's own (Ice Barrier, Arcane Power, a potion).
Spells.lastHelpfulCastAt = 0

local function RememberCast(spellID)
	local now = GetTime()
	if not API.IsHarmfulSpell(spellID) then
		Spells.lastHelpfulCastAt = now
		Spells.lastHelpfulCastName = API.SpellInfo(spellID) or tostring(spellID)
	end
	if Spells.Heals(spellID) then
		local untilTime = now + math.max(HEAL_MOMENT, LongestDuration(spellID))
		Spells.healUntil = math.max(Spells.healUntil, untilTime)
	end
	recentById[spellID] = now
	local name = API.SpellInfo(spellID)
	if name then recentByName[name] = now end
	if name and Spells.active[name] then Spells.lastBookCast, Spells.lastBookCastAt = name, now end
	Spells.lastCast, Spells.lastCastAt = name or spellID, now -- anything: spells, items
end

ns.OnUnit("UNIT_SPELLCAST_SENT", "player", function(_, _, castGUID, spellID)
	if API.IsSecret(spellID) or type(spellID) ~= "number" then return end -- hidden in combat
	if API.IsSecret(castGUID) then castGUID = nil end
	RememberCast(spellID)
	if castGUID then
		local now = GetTime()
		sentCasts[castGUID] = now
		for guid, t in pairs(sentCasts) do
			if now - t > 30 then sentCasts[guid] = nil end
		end
	end
end)

-- A cast with a cast time lands well after it was sent; refresh it on success.
-- A "cast" that was never sent is one the game made for you: a proc.
ns.OnUnit("UNIT_SPELLCAST_SUCCEEDED", "player", function(_, castGUID, spellID)
	if API.IsSecret(spellID) or type(spellID) ~= "number" then return end -- hidden in combat
	if API.IsSecret(castGUID) then return end -- can't tell your casts from procs
	if castGUID and sentCasts[castGUID] then
		sentCasts[castGUID] = nil
		RememberCast(spellID)
	elseif ns.Casts then
		ns.Casts.Triggered(spellID)
	end
end)

-- The spell from your spellbook you cast a moment ago, or nil.
function Spells.RecentBookCast()
	if Spells.lastBookCast and GetTime() - (Spells.lastBookCastAt or 0) < RECENT_CAST then return Spells.lastBookCast end
	return nil
end

-- The spell from your spellbook you cast within `window` seconds, if it's the
-- last thing you cast or used (no item, no other spell since); else nil.
function Spells.LastBookCast(window)
	local name = Spells.lastCast
	if name and name == Spells.lastBookCast and GetTime() - (Spells.lastCastAt or 0) < window then return name end
	return nil
end

function Spells.WasRecentlyCast(name, spellID)
	local now = GetTime()
	if name and recentByName[name] and now - recentByName[name] < RECENT_CAST then return true end
	if spellID and recentById[spellID] and now - recentById[spellID] < RECENT_CAST then return true end
	return false
end

ns.On("PLAYER_LOGIN", Spells.Rebuild)
ns.On("SPELLS_CHANGED", RequestRebuild)
ns.On("LEARNED_SPELL_IN_TAB", RequestRebuild)
ns.On("UPDATE_SHAPESHIFT_FORMS", RequestRebuild)
ns.On("CHARACTER_POINTS_CHANGED", RequestRebuild)
ns.On("PLAYER_TALENT_UPDATE", RequestRebuild)
-- The talent tree: changed, or (at login) ready to be read.
ns.On("TRAIT_CONFIG_UPDATED", RequestRebuild)
ns.On("TRAIT_CONFIG_LIST_UPDATED", RequestRebuild)
