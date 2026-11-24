-- FireCooldowns: when Transmute and other cooldowns are ready, on every
-- character. Only what you turn on (db.on) is shown and announced. Found for
-- you to turn on (Options.lua), their timers kept meanwhile:
--   - crafts with a cooldown: the transmutes and Mooncloth on any character
--     that knows them, and any other recipe once it's on cooldown (used, or
--     seen in the profession window);
--   - anything else you've used this session with a cooldown.
-- Or add one yourself (/fcd track, or the options' box): a spell, or an item's use.
--
-- Times are saved as server time (when the cooldown ends), so an alt's
-- cooldown keeps counting down while you play someone else.
local ADDON, ns = ...

local DEFAULTS = {
	shown = true,      -- the list on screen (Display.lua)
	alts = true,       -- ...with other characters' cooldowns
	readyOnly = false, -- ...only the ready ones
	sound = true,
}

local REAL_MIN = 60 -- shorter cooldowns are the global cooldown, not worth tracking
local TICK = 5      -- seconds between checks
local RECENT_MAX = 6

-- Crafts with cooldowns, found on each character that knows them.
local KNOWN = {
	11479, -- Transmute: Iron to Gold
	11480, -- Transmute: Mithril to Truesilver
	17187, -- Transmute: Arcanite
	17559, -- Transmute: Air to Fire
	17560, -- Transmute: Fire to Earth
	17561, -- Transmute: Earth to Water
	17562, -- Transmute: Water to Air
	17563, -- Transmute: Undeath to Water
	17564, -- Transmute: Water to Undeath
	17565, -- Transmute: Life to Earth
	17566, -- Transmute: Earth to Life
	25146, -- Transmute: Elemental Fire
	18560, -- Mooncloth
}

local db, me -- FireCooldownsDB, and this character's entry in it

local function Print(msg)
	print("|cffff8030FireCooldowns|r: " .. msg)
end
ns.Print = Print

local function Now()
	return (GetServerTime and GetServerTime()) or time()
end
ns.Now = Now

local function Secret(v)
	return issecretvalue and issecretvalue(v)
end

---------------------------------------------------------------------------
-- Reading the game
---------------------------------------------------------------------------
local function SpellNameIcon(id)
	if C_Spell and C_Spell.GetSpellInfo then
		local ok, info = pcall(C_Spell.GetSpellInfo, id)
		if ok and info then return info.name, info.iconID end
	elseif GetSpellInfo then
		local name, _, icon = GetSpellInfo(id)
		return name, icon
	end
end
ns.SpellNameIcon = SpellNameIcon

local function Knows(id)
	if IsPlayerSpell then
		local ok, known = pcall(IsPlayerSpell, id)
		if ok and known then return true end
	end
	if C_SpellBook and C_SpellBook.IsSpellKnown then
		local ok, known = pcall(C_SpellBook.IsSpellKnown, id)
		if ok and known then return true end
	end
	return false
end

-- Seconds left and the cooldown's full length, or nil when the game won't say
-- (cooldowns are hidden from addons in combat). 0 = ready. Items' use
-- cooldowns read the same way, through the spell the item casts.
local function SpellCooldown(id)
	if InCombatLockdown() then return nil end
	local start, duration, enabled
	if C_Spell and C_Spell.GetSpellCooldown then
		local ok, info = pcall(C_Spell.GetSpellCooldown, id)
		if not ok or not info then return nil end
		start, duration, enabled = info.startTime, info.duration, info.isEnabled
	elseif GetSpellCooldown then
		start, duration, enabled = GetSpellCooldown(id)
	end
	if start == nil or duration == nil or Secret(start) or Secret(duration) then return nil end
	if enabled == false or enabled == 0 then return nil end -- starts once something else ends
	if start <= 0 or duration <= 0 then return 0, 0 end
	return math.max(0, start + duration - GetTime()), duration
end

---------------------------------------------------------------------------
-- Items, by key "item:<itemID>" (spells are keyed by their spell ID). An
-- item's use cooldown is its own: the spell it casts may show none (Soulstone).
---------------------------------------------------------------------------
local function ItemID(key)
	return type(key) == "string" and tonumber(key:match("^item:(%d+)$")) or nil
end

local function ItemNameIcon(itemID)
	local name, icon
	if C_Item and C_Item.GetItemNameByID then
		local ok, n = pcall(C_Item.GetItemNameByID, itemID)
		if ok then name = n end
	end
	if not name and GetItemInfo then name = GetItemInfo(itemID) end
	if C_Item and C_Item.GetItemIconByID then
		local ok, i = pcall(C_Item.GetItemIconByID, itemID)
		if ok then icon = i end
	end
	if not icon and GetItemIcon then icon = GetItemIcon(itemID) end
	-- (Names of items not seen lately can take a moment to load: keep them.)
	if name then db.itemNames[itemID] = name else name = db.itemNames[itemID] end
	return name, icon
end

local function ItemCooldown(itemID)
	if InCombatLockdown() then return nil end
	local fn = (C_Container and C_Container.GetItemCooldown) or (C_Item and C_Item.GetItemCooldown) or GetItemCooldown
	if not fn then return nil end
	local ok, start, duration, enabled = pcall(fn, itemID)
	if not ok or start == nil or duration == nil or Secret(start) or Secret(duration) then return nil end
	if enabled == false or enabled == 0 then return nil end
	if start <= 0 or duration <= 0 then return 0, 0 end
	return math.max(0, start + duration - GetTime()), duration
end

-- Remembers which spell an item casts (db.itemSpells), so casting it counts
-- as the item. Asks the game to load the item if it doesn't know it yet.
local function MapItemSpell(itemID)
	local fn = (C_Item and C_Item.GetItemSpell) or GetItemSpell
	if not fn then return end
	local ok, _, spellID = pcall(fn, itemID)
	if ok and type(spellID) == "number" and not Secret(spellID) then
		db.itemSpells[spellID] = itemID
		return spellID
	end
	if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, itemID) end
end

local function NameIcon(key)
	local item = ItemID(key)
	if item then return ItemNameIcon(item) end
	if type(key) == "number" then return SpellNameIcon(key) end
end
ns.NameIcon = NameIcon

local function Cooldown(key)
	local item = ItemID(key)
	if item then return ItemCooldown(item) end
	if type(key) == "number" then return SpellCooldown(key) end
end

-- Knows the spell, or has the item.
local function Has(key)
	local item = ItemID(key)
	if item then
		local fn = (C_Item and C_Item.GetItemCount) or GetItemCount
		local ok, n = pcall(fn, item)
		return ok and type(n) == "number" and n > 0
	end
	return type(key) == "number" and Knows(key)
end

-- From the profession window, when it's open.
local function RecipeCooldown(id)
	if not (C_TradeSkillUI and C_TradeSkillUI.GetRecipeCooldown) then return nil end
	local ok, left = pcall(C_TradeSkillUI.GetRecipeCooldown, id)
	if ok and type(left) == "number" and not Secret(left) then return left end
end

local recipes = {} -- [spellID] = true for every recipe seen in the profession window

local function IsCraft(id)
	if recipes[id] then return true end
	if C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo then
		local ok, info = pcall(C_TradeSkillUI.GetRecipeInfo, id)
		if ok and type(info) == "table" and info.recipeID then return true end
	end
	return false
end

---------------------------------------------------------------------------
-- Saved cooldowns: db.chars[GUID] = { name, class, cds = { [key] = entry } }
-- (key: spell ID, "item:<itemID>", or "test")
-- entry = { name, icon, readyAt (server time; 0 = ready), told (ready was
-- announced), test (the pretend one from /fcd test) }
-- db.custom[key] = true: added by you. db.on[name] = true: turned on.
-- Turning on goes by the name before any ":", so "Transmute" covers them all.
---------------------------------------------------------------------------
local function Prefix(name)
	return name:match("^(.-):") or name
end
ns.Prefix = Prefix

function ns.IsOn(e)
	return e.test or db.on[Prefix(e.name)] == true
end

-- The first time something is found, say where to turn it on.
local function Hint(key)
	if db.on[key] or db.hinted[key] then return end
	db.hinted[key] = true
	Print(("found %s. Turn it on in /fcd to track it."):format(key))
end

local function Track(id)
	local e = me.cds[id]
	if e then return e end
	local name, icon = NameIcon(id)
	if not name then return nil end
	e = { name = name, icon = icon, readyAt = 0, told = true }
	me.cds[id] = e
	Hint(Prefix(name))
	return e
end

-- A cooldown seen running: save when it ends. A new cooldown means its "ready"
-- hasn't been announced yet.
local function SetLeft(e, left, duration)
	if duration and duration >= REAL_MIN then e.duration = duration end -- (for when the game stops saying)
	local readyAt = Now() + math.floor(left + 0.5)
	if math.abs(readyAt - (e.readyAt or 0)) > REAL_MIN then
		e.readyAt = readyAt
		e.told = false
	end
end

-- Only running cooldowns are believed: right after logging in the game can
-- briefly report everything as ready, and saved times end on their own anyway.
-- Something you added shows on a character once it knows it or has used it.
local mappedItems = {} -- [itemID] = true once its spell is known this session

local function Refresh()
	if InCombatLockdown() then return end
	for _, id in ipairs(KNOWN) do
		if not me.cds[id] and Knows(id) then Track(id) end
	end
	for id in pairs(db.custom) do
		local item = ItemID(id)
		if item and not mappedItems[item] and MapItemSpell(item) then mappedItems[item] = true end
		if not me.cds[id] then
			if Has(id) then
				Track(id)
			else
				local left, duration = Cooldown(id)
				if left and duration >= REAL_MIN and left > 0 then Track(id) end
			end
		end
	end
	for id, e in pairs(me.cds) do
		if not e.test then
			local left, duration = Cooldown(id)
			if left and duration >= REAL_MIN and left > 0 then SetLeft(e, left, duration) end
		end
	end
end

---------------------------------------------------------------------------
-- Showing it
---------------------------------------------------------------------------
local function Left(s)
	s = math.max(0, s)
	local d, h, m = math.floor(s / 86400), math.floor(s % 86400 / 3600), math.floor(s % 3600 / 60)
	if d > 0 then return d .. "d " .. h .. "h" end
	if h > 0 then return h .. "h " .. m .. "m" end
	if m > 0 then return m .. "m" end
	return "<1m"
end
ns.Left = Left

-- Entries that end together read as one ("Transmute" rather than every
-- transmute the character knows). Returns { label, icon, ready, left } sorted
-- ready first, then soonest.
local function Group(entries, now)
	table.sort(entries, function(a, b)
		if a.readyAt ~= b.readyAt then return a.readyAt < b.readyAt end
		return a.name < b.name
	end)
	local groups = {}
	for _, e in ipairs(entries) do
		local ready, prefix = e.readyAt <= now, Prefix(e.name)
		local found
		for _, g in ipairs(groups) do
			if g.prefix == prefix and g.ready == ready and (ready or e.readyAt - g.readyAt <= REAL_MIN) then
				found = g
				break
			end
		end
		if not found then
			found = { prefix = prefix, ready = ready, readyAt = e.readyAt, icon = e.icon, names = {} }
			groups[#groups + 1] = found
		end
		found.names[#found.names + 1] = e.name
	end
	for _, g in ipairs(groups) do
		g.label = #g.names == 1 and g.names[1] or g.prefix
		g.left = g.readyAt - now
	end
	return groups
end
ns.Group = Group

local function ClassName(c)
	local color = c.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.class]
	if color and color.colorStr then return "|c" .. color.colorStr .. c.name .. "|r" end
	return c.name
end
ns.ClassName = ClassName

-- A character's cooldowns that are turned on.
local function Entries(c)
	local list = {}
	for _, e in pairs(c.cds) do
		if ns.IsOn(e) then list[#list + 1] = e end
	end
	return list
end
ns.Entries = Entries

local function List()
	local now = Now()
	local lines = {}
	local chars = {}
	for _, c in pairs(db.chars) do chars[#chars + 1] = c end
	table.sort(chars, function(a, b)
		if (a == me) ~= (b == me) then return a == me end
		return (a.name or "") < (b.name or "")
	end)
	for _, c in ipairs(chars) do
		local parts = {}
		for _, g in ipairs(Group(Entries(c), now)) do
			parts[#parts + 1] = g.label .. " " .. (g.ready and "|cff40ff40ready|r" or Left(g.left))
		end
		if #parts > 0 then lines[#lines + 1] = "  " .. ClassName(c) .. ": " .. table.concat(parts, ", ") end
	end
	if #lines == 0 then
		Print("nothing turned on. Pick what to track in /fcd.")
		return
	end
	Print("cooldowns:")
	for _, line in ipairs(lines) do print(line) end
end

local function PlaySoundSafe()
	if not PlaySound or not db.sound then return end
	local id = (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959
	pcall(PlaySound, id, "Master")
end

local function ScreenAlert(text, icon)
	if icon then text = "|T" .. icon .. ":0|t " .. text end
	local shown = false
	if RaidNotice_AddMessage and RaidWarningFrame then
		local color = ChatTypeInfo and ChatTypeInfo.RAID_WARNING or { r = 1, g = 0.82, b = 0 }
		shown = pcall(RaidNotice_AddMessage, RaidWarningFrame, text, color)
	end
	if not shown and UIErrorsFrame then
		UIErrorsFrame:AddMessage(text, 1, 0.82, 0)
	end
	PlaySoundSafe()
end

---------------------------------------------------------------------------
-- Announcing: once when a cooldown ends (on screen for this character, in
-- chat for alts), and on login a reminder of what's ready here.
---------------------------------------------------------------------------
local function Check(login)
	Refresh()
	local now = Now()
	for _, c in pairs(db.chars) do
		local fresh = {}
		for _, e in pairs(c.cds) do
			if not e.told and e.readyAt <= now then
				e.told = true
				if ns.IsOn(e) then fresh[#fresh + 1] = e end
			end
		end
		if #fresh > 0 then
			for _, g in ipairs(Group(fresh, now)) do
				if c == me then
					ScreenAlert(g.label .. " ready", g.icon)
					if not login then Print(g.label .. " ready.") end
				else
					Print(g.label .. " ready on " .. ClassName(c) .. ".")
					PlaySoundSafe()
				end
			end
		end
	end
	ns.Display.Refresh()
	if login and not db.shown then -- (on screen it's in the list)
		local labels = {}
		for _, g in ipairs(Group(Entries(me), now)) do
			if g.ready then labels[#labels + 1] = g.label end
		end
		if #labels > 0 then Print("ready: " .. table.concat(labels, ", ") .. ".") end
	end
end

-- Just turned on: if it's ready here, say so now (instead of only when a
-- cooldown ends).
function ns.AnnounceReady(key)
	local now = Now()
	for _, e in pairs(me.cds) do
		if Prefix(e.name) == key and e.readyAt <= now then e.told = false end
	end
	Check(false)
end

---------------------------------------------------------------------------
-- What you've used lately with a cooldown, to turn on in the options.
-- A craft is found (kept, its timer too) instead.
---------------------------------------------------------------------------
local recent = {} -- newest first: { id (key), name, icon }

-- A spell cast by an item counts as the item (its cooldown is the item's).
-- castAt: when it was cast (GetTime), if not just now (in combat).
local function CheckCast(spellID, castAt)
	local item = db.itemSpells[spellID]
	local id = item and ("item:" .. item) or spellID
	local left, duration = Cooldown(id)
	local running = left and duration >= REAL_MIN and left > 0
	if not running and item then
		-- Used up, the game may not say any more: the spell's cooldown, or
		-- the item's cooldown last time.
		local l2, d2 = SpellCooldown(spellID)
		local e = me.cds[id]
		if l2 and d2 >= REAL_MIN and l2 > 0 then
			left, duration, running = l2, d2, true
		else
			-- The item's cooldown last time, or the spell's listed cooldown.
			local length = (e and e.duration) or ns.BaseCooldown(spellID)
			if length and length >= REAL_MIN then
				left, duration = length - (GetTime() - (castAt or GetTime())), length
				running = left > 0
			end
		end
	end
	if not running then return end
	if me.cds[id] or (not item and IsCraft(id)) then
		local e = Track(id)
		if not e then return end
		SetLeft(e, left, duration)
		ns.Display.Refresh()
	else
		local name, icon = NameIcon(id)
		if not name then return end
		for i = #recent, 1, -1 do
			if recent[i].id == id then table.remove(recent, i) end
		end
		table.insert(recent, 1, { id = id, name = name, icon = icon })
		recent[RECENT_MAX + 1] = nil
	end
	ns.Options.Refresh()
end

-- With the profession window open: every recipe with a cooldown running.
local function ScanRecipes()
	if InCombatLockdown() or not (C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs) then return end
	local ok, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
	if not ok or type(ids) ~= "table" then return end
	local added = false
	for _, id in ipairs(ids) do
		recipes[id] = true
		local left = RecipeCooldown(id)
		if left and left > REAL_MIN then
			local e = Track(id)
			if e then
				SetLeft(e, left)
				added = true
			end
		end
	end
	if added then
		ns.Display.Refresh()
		ns.Options.Refresh()
	end
end

---------------------------------------------------------------------------
-- Turning on, adding and removing
---------------------------------------------------------------------------
-- The key for a spell ID, a spell's name, "item:<itemID>", or a shift-clicked
-- link: spell, recipe, or item (its own cooldown).
function ns.FindKey(text)
	text = strtrim(text or "")
	if text == "" then return nil end
	local id = tonumber(text) or tonumber(text:match("|Hspell:(%d+)")) or tonumber(text:match("|Henchant:(%d+)"))
	if id then return id end
	local item = tonumber(text:match("|Hitem:(%d+)")) or ItemID(text)
	if item then
		local name = text:match("|h%[(.-)%]|h")
		if name and name ~= "" then db.itemNames[item] = name end
		return "item:" .. item
	end
	if C_Spell and C_Spell.GetSpellInfo then
		local ok, info = pcall(C_Spell.GetSpellInfo, text)
		if ok and info then return info.spellID end
	elseif GetSpellInfo then
		return select(7, GetSpellInfo(text))
	end
end

-- Adds and turns on a spell or item. Returns its name, or nil and why not.
function ns.Add(text)
	local id = ns.FindKey(text)
	local name = id and NameIcon(id)
	if not name then return nil, "Not found. Try a spell ID or shift-click a link." end
	db.custom[id] = true
	db.on[Prefix(name)] = true
	local left, duration = Cooldown(id)
	local running = left and duration >= REAL_MIN and left > 0
	if ItemID(id) then MapItemSpell(ItemID(id)) end
	if me.cds[id] or Has(id) or running or ItemID(id) then
		local e = Track(id)
		if e and running then SetLeft(e, left, duration) end
	end
	ns.AnnounceReady(Prefix(name))
	ns.Options.Refresh()
	return name
end

---------------------------------------------------------------------------
-- Your abilities with a cooldown of a minute or more, to pick from.
---------------------------------------------------------------------------
local UNITS = { sec = 1, min = 60, hr = 3600, hour = 3600, day = 86400 }

-- Seconds, from the game or else from the spell's tooltip ("2 min cooldown").
local function BaseCooldown(id)
	return ns.BaseCooldown(id)
end
function ns.BaseCooldown(id)
	if GetSpellBaseCooldown then
		local ok, ms = pcall(GetSpellBaseCooldown, id)
		if ok and type(ms) == "number" and not Secret(ms) then return ms / 1000 end
	end
	if C_TooltipInfo and C_TooltipInfo.GetSpellByID then
		local ok, data = pcall(C_TooltipInfo.GetSpellByID, id)
		if ok and type(data) == "table" and data.lines then
			for _, line in ipairs(data.lines) do
				for _, text in ipairs({ line.leftText, line.rightText }) do
					if type(text) == "string" and not Secret(text) then
						local n, unit = text:match("([%d%.]+) (%a+) [Cc]ooldown")
						unit = unit and UNITS[unit:lower():gsub("s$", "")]
						if n and unit then return tonumber(n) * unit end
					end
				end
			end
		end
	end
	return 0
end

local abilities -- cached list, rebuilt when your spells change

local function ScanAbilities()
	abilities = {}
	if not (C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines and C_SpellBook.GetSpellBookItemInfo) then return end
	local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
	local spellType = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell or 1
	local seen = {}
	local ok, lines = pcall(C_SpellBook.GetNumSpellBookSkillLines)
	if not ok or type(lines) ~= "number" then return end
	for l = 1, lines do
		local okL, line = pcall(C_SpellBook.GetSpellBookSkillLineInfo, l)
		if okL and type(line) == "table" and not line.shouldHide and not line.offSpecID then
			for i = line.itemIndexOffset + 1, line.itemIndexOffset + line.numSpellBookItems do
				local okI, info = pcall(C_SpellBook.GetSpellBookItemInfo, i, bank)
				local id = okI and type(info) == "table" and info.itemType == spellType and not info.isPassive and info.spellID
				if id and not seen[id] and BaseCooldown(id) >= REAL_MIN then
					seen[id] = true
					abilities[#abilities + 1] = { id = id, name = info.name, icon = info.iconID }
				end
			end
		end
	end
	table.sort(abilities, function(a, b) return a.name < b.name end)
end

-- Your abilities not already in the list above them: { key, icon, addID }.
function ns.Abilities(found)
	if not abilities then ScanAbilities() end
	local taken = {}
	for _, t in ipairs(found) do taken[t.key] = true end
	local list = {}
	for _, a in ipairs(abilities) do
		local key = Prefix(a.name)
		if not taken[key] then
			taken[key] = true
			list[#list + 1] = { key = key, icon = a.icon, addID = a.id }
		end
	end
	return list
end

-- Everything found or added, by the name turning it on uses:
-- { key, icon, on, custom (added by you: can be removed), addID (only
-- used this session: turning it on adds it) }.
function ns.Found()
	local byKey, list = {}, {}
	local function Add(key, icon)
		local t = byKey[key]
		if not t then
			t = { key = key, icon = icon, on = db.on[key] == true }
			byKey[key] = t
			list[#list + 1] = t
		end
		return t
	end
	for _, c in pairs(db.chars) do
		for _, e in pairs(c.cds) do
			if not e.test then Add(Prefix(e.name), e.icon) end
		end
	end
	for id in pairs(db.custom) do
		local name, icon = NameIcon(id)
		if name then Add(Prefix(name), icon).custom = true end
	end
	table.sort(list, function(a, b) return a.key < b.key end)
	for _, r in ipairs(recent) do
		local key = Prefix(r.name)
		if not byKey[key] then Add(key, r.icon).addID = r.id end
	end
	return list
end

function ns.SetOn(key, on)
	db.on[key] = on or nil
	if on then ns.AnnounceReady(key) else ns.Display.Refresh() end
end

-- Removes something you added, from every character.
function ns.Remove(key)
	for id in pairs(db.custom) do
		local name = NameIcon(id)
		if name and Prefix(name) == key then db.custom[id] = nil end
	end
	for _, c in pairs(db.chars) do
		for id, e in pairs(c.cds) do
			local craft = type(id) == "number" and (IsCraft(id) or tContains(KNOWN, id))
			if Prefix(e.name) == key and not e.test and not db.custom[id] and not craft then
				c.cds[id] = nil
			end
		end
	end
	db.on[key] = nil
	ns.Display.Refresh()
	ns.Options.Refresh()
end

---------------------------------------------------------------------------
-- Which spell each item in your bags casts (db.itemSpells), so using one
-- counts as the item even once it's used up (a Soulstone). Something added as
-- the spell an item casts becomes the item.
---------------------------------------------------------------------------
local function MoveToItem(spellID, item)
	local key = "item:" .. item
	local spellName = SpellNameIcon(spellID)
	local itemName = NameIcon(key)
	if not (spellName and itemName) then return end
	db.custom[spellID] = nil
	db.custom[key] = true
	if db.on[Prefix(spellName)] then
		db.on[Prefix(spellName)] = nil
		db.on[Prefix(itemName)] = true
	end
	for _, c in pairs(db.chars) do c.cds[spellID] = nil end
	Print(("tracking %s (the item) instead of %s."):format(itemName, spellName))
	ns.Display.Refresh()
	ns.Options.Refresh()
end

local function ScanBags()
	local numSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
	local itemAt = (C_Container and C_Container.GetContainerItemID) or GetContainerItemID
	local itemSpell = (C_Item and C_Item.GetItemSpell) or GetItemSpell
	if not (numSlots and itemAt and itemSpell) then return end
	for bag = 0, NUM_BAG_SLOTS or 4 do
		local okN, n = pcall(numSlots, bag)
		for slot = 1, (okN and type(n) == "number") and n or 0 do
			local okI, item = pcall(itemAt, bag, slot)
			if okI and type(item) == "number" then
				local okS, _, spellID = pcall(itemSpell, item)
				if okS and type(spellID) == "number" and not Secret(spellID) then
					db.itemSpells[spellID] = item
					if db.custom[spellID] then MoveToItem(spellID, item) end
				end
			end
		end
	end
end

---------------------------------------------------------------------------
-- Testing without the crafts
---------------------------------------------------------------------------
local function Test(arg)
	if arg == "clear" then
		local n = 0
		for _, c in pairs(db.chars) do
			for id, e in pairs(c.cds) do
				if e.test then c.cds[id] = nil n = n + 1 end
			end
		end
		Print(n > 0 and "test removed." or "no test to remove.")
	else
		-- A pretend transmute that's ready in 10 seconds.
		local _, icon = SpellNameIcon(17187)
		me.cds.test = { name = "Transmute: Arcanite", icon = icon or "Interface\\Icons\\INV_Misc_StoneTablet_05",
			readyAt = Now() + 10, told = false, test = true }
		Print("test: a pretend Transmute: Arcanite, ready in 10 seconds.")
		C_Timer.After(10.5, function() Check(false) end)
	end
	ns.Display.Refresh()
	ns.Options.Refresh()
end

---------------------------------------------------------------------------
-- Setup and commands
---------------------------------------------------------------------------
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
if not pcall(frame.RegisterUnitEvent, frame, "UNIT_SPELLCAST_SUCCEEDED", "player") then
	frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
end
pcall(frame.RegisterEvent, frame, "TRADE_SKILL_LIST_UPDATE")
frame:RegisterEvent("SPELLS_CHANGED")
pcall(frame.RegisterEvent, frame, "BAG_UPDATE_DELAYED")

local scanQueued = false
local pendingCasts = {} -- [spellID] = GetTime() of casts in combat
frame:SetScript("OnEvent", function(_, event, unit, _, spellID)
	if event == "PLAYER_LOGIN" then
		FireCooldownsDB = type(FireCooldownsDB) == "table" and FireCooldownsDB or {}
		db = FireCooldownsDB
		db.chars = db.chars or {}
		db.custom = db.custom or {}
		db.hinted = db.hinted or {}
		db.itemNames = db.itemNames or {}   -- [itemID] = name
		db.itemSpells = db.itemSpells or {} -- [spellID] = itemID that casts it
		for k, v in pairs(DEFAULTS) do
			if db[k] == nil then db[k] = v end
		end
		ns.db = db
		local guid = UnitGUID("player")
		me = db.chars[guid] or { cds = {} }
		db.chars[guid] = me
		me.name = UnitName("player")
		me.class = select(2, UnitClass("player"))
		-- Earlier versions: spells tracked with "/fcd test <spell>" are yours
		-- now, and what you added stays on (everything else starts off).
		if not db.on then
			db.on = {}
			for _, c in pairs(db.chars) do
				for id, e in pairs(c.cds) do
					if e.test and type(id) == "number" then
						e.test = nil
						db.custom[id] = true
					end
				end
			end
			for id in pairs(db.custom) do
				local name = SpellNameIcon(id)
				if name and not (db.off and db.off[Prefix(name)]) then db.on[Prefix(name)] = true end
			end
			db.off = nil
		end
		ns.me = me
		ns.Display.Init()
		ns.EditMode.Init()
		ns.Options.Init()
		ScanBags()
		C_Timer.After(5, function() Check(true) end) -- once the game has sent the cooldowns
		C_Timer.NewTicker(TICK, function() Check(false) end)
	elseif not me then
		return
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		if Secret(unit) or unit ~= "player" or Secret(spellID) or type(spellID) ~= "number" then return end
		-- In combat cooldowns are hidden: something tracked is checked once it ends.
		if InCombatLockdown() then
			if db.itemSpells[spellID] or me.cds[spellID] then pendingCasts[spellID] = GetTime() end
			return
		end
		-- The cooldown starts a moment after the cast.
		C_Timer.After(1, function() CheckCast(spellID) end)
	elseif event == "TRADE_SKILL_LIST_UPDATE" then
		if scanQueued then return end
		scanQueued = true
		C_Timer.After(0.5, function()
			scanQueued = false
			ScanRecipes()
		end)
	elseif event == "BAG_UPDATE_DELAYED" then
		if not InCombatLockdown() then ScanBags() end
	elseif event == "SPELLS_CHANGED" then
		abilities = nil -- found again when next needed
		ns.Options.Refresh()
	elseif event == "PLAYER_REGEN_ENABLED" then
		for id, at in pairs(pendingCasts) do
			pendingCasts[id] = nil
			CheckCast(id, at)
		end
		Check(false)
	end
end)

-- /fcd debug: what's saved for this character and what the game says now.
local function Debug()
	local now = Now()
	local spellOf = {}
	for spellID, item in pairs(db.itemSpells) do spellOf[item] = spellID end
	local keys = {}
	for id in pairs(me.cds) do keys[id] = true end
	for id in pairs(db.custom) do keys[id] = true end
	Print(("debug, combat %s:"):format(tostring(InCombatLockdown() and true or false)))
	for id in pairs(keys) do
		local e = me.cds[id]
		local name = (e and e.name) or NameIcon(id) or "?"
		local left, duration = Cooldown(id)
		local line = ("  %s [%s] on=%s here=%s"):format(name, tostring(id), tostring(db.on[Prefix(name)] == true),
			tostring(e ~= nil))
		if e then
			line = line .. (" readyIn=%s told=%s lastDur=%s"):format(
				tostring(e.readyAt - now), tostring(e.told), tostring(e.duration))
		end
		line = line .. (" game: left=%s dur=%s has=%s"):format(tostring(left), tostring(duration), tostring(Has(id)))
		local item = ItemID(id)
		if item then
			local spellID = spellOf[item]
			local l2, d2 = spellID and SpellCooldown(spellID)
			line = line .. (" spell=%s spellLeft=%s spellDur=%s"):format(tostring(spellID), tostring(l2), tostring(d2))
		end
		print(line)
	end
end

local function Help()
	Print("commands:")
	print("  /fcd - options: what's tracked, what's shown")
	print("  /fcd list - tracked cooldowns on all your characters, in chat")
	print("  /fcd track <spell, ID or shift-click a link> - add and track it")
	print("  /fcd test - a pretend transmute, ready in 10 seconds (/fcd test clear)")
	print("  /fcd forget <character> - remove a character")
	print("  /fcd debug - what's saved and what the game reports, per cooldown")
end

SLASH_FIRECOOLDOWNS1 = "/fcd"
SLASH_FIRECOOLDOWNS2 = "/firecooldowns"
SlashCmdList.FIRECOOLDOWNS = function(input)
	if not me then return end
	local cmd, arg = strtrim(input or ""):match("^(%S*)%s*(.-)$")
	cmd = (cmd or ""):lower()
	if cmd == "" or cmd == "options" then
		ns.Options.Open()
	elseif cmd == "list" then
		Refresh()
		List()
	elseif cmd == "track" and arg ~= "" then
		local name, why = ns.Add(arg)
		Print(name and ("tracking %s."):format(name) or why)
	elseif cmd == "test" then
		Test(arg:lower())
	elseif cmd == "debug" then
		Debug()
	elseif cmd == "forget" and arg ~= "" then
		for guid, c in pairs(db.chars) do
			if c ~= me and c.name and c.name:lower() == arg:lower() then
				db.chars[guid] = nil
				Print(("forgot %s."):format(c.name))
				ns.Display.Refresh()
				ns.Options.Refresh()
				return
			end
		end
		Print(("no other character called %s."):format(arg))
	else
		Help()
	end
end
