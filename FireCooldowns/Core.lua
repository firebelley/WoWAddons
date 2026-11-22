-- FireCooldowns: when Transmute and other cooldowns are ready, on every
-- character. What's tracked:
--   - crafts with a cooldown: the transmutes and Mooncloth on any character
--     that knows them, and any other recipe once it's on cooldown (used, or
--     seen in the profession window);
--   - anything you add (Options.lua, /fcd track): a spell, or an item's use;
-- and each can be turned off (db.off).
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
-- Saved cooldowns: db.chars[GUID] = { name, class, cds = { [spellID] = entry } }
-- entry = { name, icon, readyAt (server time; 0 = ready), told (ready was
-- announced), test (the pretend one from /fcd test) }
-- db.custom[spellID] = true: added by you. db.off[name] = true: turned off.
-- Turning off goes by the name before any ":", so "Transmute" covers them all.
---------------------------------------------------------------------------
local function Prefix(name)
	return name:match("^(.-):") or name
end
ns.Prefix = Prefix

function ns.IsOff(e)
	return db.off[Prefix(e.name)] == true
end

local function Track(id)
	local e = me.cds[id]
	if e then return e end
	local name, icon = SpellNameIcon(id)
	if not name then return nil end
	e = { name = name, icon = icon, readyAt = 0, told = true }
	me.cds[id] = e
	return e
end

-- A cooldown seen running: save when it ends. A new cooldown means its "ready"
-- hasn't been announced yet.
local function SetLeft(e, left)
	local readyAt = Now() + math.floor(left + 0.5)
	if math.abs(readyAt - (e.readyAt or 0)) > REAL_MIN then
		e.readyAt = readyAt
		e.told = false
	end
end

-- Only running cooldowns are believed: right after logging in the game can
-- briefly report everything as ready, and saved times end on their own anyway.
-- Something you added shows on a character once it knows it or has used it.
local function Refresh()
	if InCombatLockdown() then return end
	for _, id in ipairs(KNOWN) do
		if not me.cds[id] and Knows(id) then Track(id) end
	end
	for id in pairs(db.custom) do
		if not me.cds[id] then
			if Knows(id) then
				Track(id)
			else
				local left, duration = SpellCooldown(id)
				if left and duration >= REAL_MIN and left > 0 then Track(id) end
			end
		end
	end
	for id, e in pairs(me.cds) do
		if type(id) == "number" then
			local left, duration = SpellCooldown(id)
			if left and duration >= REAL_MIN and left > 0 then SetLeft(e, left) end
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

-- A character's cooldowns that aren't turned off.
local function Entries(c)
	local list = {}
	for _, e in pairs(c.cds) do
		if not ns.IsOff(e) then list[#list + 1] = e end
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
		Print("nothing tracked yet.")
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
				if not ns.IsOff(e) then fresh[#fresh + 1] = e end
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

---------------------------------------------------------------------------
-- What you've used lately with a cooldown, to pick from in the options.
-- A craft is tracked straight away instead.
---------------------------------------------------------------------------
local recent = {} -- newest first: { id, name, icon }

function ns.Recent()
	local list = {}
	for _, r in ipairs(recent) do
		if not me.cds[r.id] and not db.custom[r.id] then list[#list + 1] = r end
	end
	return list
end

local function CheckCast(id)
	local left, duration = SpellCooldown(id)
	if not (left and duration >= REAL_MIN and left > 0) then return end
	if me.cds[id] then
		SetLeft(me.cds[id], left)
	elseif IsCraft(id) then
		local e = Track(id)
		if not e then return end
		SetLeft(e, left)
		Print(("tracking %s (ready in %s)."):format(e.name, Left(left)))
	else
		local name, icon = SpellNameIcon(id)
		if not name then return end
		for i = #recent, 1, -1 do
			if recent[i].id == id then table.remove(recent, i) end
		end
		table.insert(recent, 1, { id = id, name = name, icon = icon })
		recent[RECENT_MAX + 1] = nil
		ns.Options.Refresh()
		return
	end
	ns.Display.Refresh()
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
			local e = me.cds[id] or Track(id)
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
-- Adding and removing your own
---------------------------------------------------------------------------
-- A spell ID, a spell's name, or a shift-clicked link: spell, recipe, or an
-- item (its use).
function ns.FindSpell(text)
	text = strtrim(text or "")
	if text == "" then return nil end
	local id = tonumber(text) or tonumber(text:match("|Hspell:(%d+)")) or tonumber(text:match("|Henchant:(%d+)"))
	if id then return id end
	local item = tonumber(text:match("|Hitem:(%d+)"))
	if item then
		local fn = (C_Item and C_Item.GetItemSpell) or GetItemSpell
		if fn then
			local ok, _, spellID = pcall(fn, item)
			if ok then return spellID end
		end
		return nil
	end
	if C_Spell and C_Spell.GetSpellInfo then
		local ok, info = pcall(C_Spell.GetSpellInfo, text)
		if ok and info then return info.spellID end
	elseif GetSpellInfo then
		return select(7, GetSpellInfo(text))
	end
end

-- Returns the name tracked, or nil and why not.
function ns.Add(text)
	local id = ns.FindSpell(text)
	local name = id and SpellNameIcon(id)
	if not name then return nil, "Not found. Try a spell ID or shift-click a link." end
	db.custom[id] = true
	db.off[Prefix(name)] = nil
	local left, duration = SpellCooldown(id)
	if Knows(id) or (left and duration >= REAL_MIN and left > 0) then
		local e = Track(id)
		if e and left and left > 0 and duration >= REAL_MIN then SetLeft(e, left) end
	end
	ns.Display.Refresh()
	ns.Options.Refresh()
	return name
end

-- Everything tracked on any character, by the name turning it off uses:
-- { key, icon, off, custom (added by you: can be removed) }.
function ns.Tracked()
	local byKey, list = {}, {}
	local function Add(key, icon, custom)
		local t = byKey[key]
		if not t then
			t = { key = key, icon = icon, off = db.off[key] == true }
			byKey[key] = t
			list[#list + 1] = t
		end
		if custom then t.custom = true end
	end
	for _, c in pairs(db.chars) do
		for id, e in pairs(c.cds) do Add(Prefix(e.name), e.icon, db.custom[id]) end
	end
	for id in pairs(db.custom) do
		local name, icon = SpellNameIcon(id)
		if name then Add(Prefix(name), icon, true) end
	end
	table.sort(list, function(a, b) return a.key < b.key end)
	return list
end

function ns.SetOff(key, off)
	db.off[key] = off or nil
	ns.Display.Refresh()
end

-- Removes something you added (and the pretend test), from every character.
function ns.Remove(key)
	for id in pairs(db.custom) do
		local name = SpellNameIcon(id)
		if name and Prefix(name) == key then db.custom[id] = nil end
	end
	for _, c in pairs(db.chars) do
		for id, e in pairs(c.cds) do
			if Prefix(e.name) == key and (e.test or (type(id) == "number" and not db.custom[id] and not IsCraft(id)
				and not tContains(KNOWN, id))) then
				c.cds[id] = nil
			end
		end
	end
	ns.Display.Refresh()
	ns.Options.Refresh()
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

local scanQueued = false
frame:SetScript("OnEvent", function(_, event, unit, _, spellID)
	if event == "PLAYER_LOGIN" then
		FireCooldownsDB = type(FireCooldownsDB) == "table" and FireCooldownsDB or {}
		db = FireCooldownsDB
		db.chars = db.chars or {}
		db.custom = db.custom or {}
		db.off = db.off or {}
		for k, v in pairs(DEFAULTS) do
			if db[k] == nil then db[k] = v end
		end
		ns.db = db
		local guid = UnitGUID("player")
		me = db.chars[guid] or { cds = {} }
		db.chars[guid] = me
		me.name = UnitName("player")
		me.class = select(2, UnitClass("player"))
		-- Earlier versions tracked any spell with "/fcd test <spell>": those are yours now.
		for _, c in pairs(db.chars) do
			for id, e in pairs(c.cds) do
				if e.test and type(id) == "number" then
					e.test = nil
					db.custom[id] = true
				end
			end
		end
		ns.me = me
		ns.Display.Init()
		ns.EditMode.Init()
		ns.Options.Init()
		C_Timer.After(5, function() Check(true) end) -- once the game has sent the cooldowns
		C_Timer.NewTicker(TICK, function() Check(false) end)
	elseif not me then
		return
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		-- Out of combat only (in combat the cast details are hidden anyway).
		if InCombatLockdown() or Secret(unit) or unit ~= "player" then return end
		if Secret(spellID) or type(spellID) ~= "number" then return end
		-- The cooldown starts a moment after the cast.
		C_Timer.After(1, function() CheckCast(spellID) end)
	elseif event == "TRADE_SKILL_LIST_UPDATE" then
		if scanQueued then return end
		scanQueued = true
		C_Timer.After(0.5, function()
			scanQueued = false
			ScanRecipes()
		end)
	elseif event == "PLAYER_REGEN_ENABLED" then
		Check(false)
	end
end)

local function Help()
	Print("commands:")
	print("  /fcd - options: what's tracked, what's shown")
	print("  /fcd list - cooldowns on all your characters, in chat")
	print("  /fcd track <spell, ID or shift-click a link> - track it too")
	print("  /fcd test - a pretend transmute, ready in 10 seconds (/fcd test clear)")
	print("  /fcd forget <character> - remove a character")
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
