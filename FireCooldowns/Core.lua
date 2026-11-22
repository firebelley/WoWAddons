-- FireCooldowns: when Transmute (and other crafting cooldowns) are ready, on
-- every character. Nothing to set up: the crafts it knows about are found on
-- each character, and any other craft you use with a cooldown of hours is
-- picked up the moment you use it.
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

local LEARN_MIN = 3 * 3600 -- a craft with a cooldown this long is tracked once used (Hearthstone is 1h)
local REAL_MIN = 60        -- shorter readings are the global cooldown, not the craft's
local TICK = 5             -- seconds between checks

-- Crafts with long cooldowns, found by default.
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
-- (cooldowns are hidden from addons in combat). 0 = ready.
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

-- From the profession window, when it's open (C_TradeSkillUI.GetRecipeCooldown).
local function RecipeCooldown(id)
	if not (C_TradeSkillUI and C_TradeSkillUI.GetRecipeCooldown) then return nil end
	local ok, left = pcall(C_TradeSkillUI.GetRecipeCooldown, id)
	if ok and type(left) == "number" and not Secret(left) then return left end
end

---------------------------------------------------------------------------
-- Saved cooldowns: db.chars[GUID] = { name, class, cds = { [spellID] = entry } }
-- entry = { name, icon, readyAt (server time; 0 = ready), told (ready was
-- announced), test (added by /fcd test) }
---------------------------------------------------------------------------
local function Track(id, test)
	local e = me.cds[id]
	if e then return e end
	local name, icon = SpellNameIcon(id)
	if not name then return nil end
	e = { name = name, icon = icon, readyAt = 0, told = true, test = test or nil }
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
local function Refresh()
	if InCombatLockdown() then return end
	for _, id in ipairs(KNOWN) do
		if not me.cds[id] and Knows(id) then Track(id) end
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

local function Prefix(name)
	return name:match("^(.-):") or name
end

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

local function Describe(groups)
	local parts = {}
	for _, g in ipairs(groups) do
		parts[#parts + 1] = g.label .. " " .. (g.ready and "|cff40ff40ready|r" or Left(g.left))
	end
	return table.concat(parts, ", ")
end

local function ClassName(c)
	local color = c.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.class]
	if color and color.colorStr then return "|c" .. color.colorStr .. c.name .. "|r" end
	return c.name
end
ns.ClassName = ClassName

local function Entries(c)
	local list = {}
	for _, e in pairs(c.cds) do list[#list + 1] = e end
	return list
end
ns.Entries = Entries

local function List()
	local now = Now()
	local chars = {}
	for _, c in pairs(db.chars) do
		if next(c.cds) then chars[#chars + 1] = c end
	end
	if #chars == 0 then
		Print("no crafting cooldowns yet.")
		return
	end
	table.sort(chars, function(a, b)
		if (a == me) ~= (b == me) then return a == me end
		return a.name < b.name
	end)
	Print("cooldowns:")
	for _, c in ipairs(chars) do
		print("  " .. ClassName(c) .. ": " .. Describe(Group(Entries(c), now)))
	end
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
	for guid, c in pairs(db.chars) do
		local fresh = {}
		for _, e in pairs(c.cds) do
			if not e.told and e.readyAt <= now then
				e.told = true
				fresh[#fresh + 1] = e
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
		local ready = {}
		for _, e in pairs(me.cds) do
			if e.readyAt <= now then ready[#ready + 1] = e end
		end
		if #ready > 0 then
			local labels = {}
			for _, g in ipairs(Group(ready, now)) do labels[#labels + 1] = g.label end
			Print("ready: " .. table.concat(labels, ", ") .. ".")
		end
	end
end

---------------------------------------------------------------------------
-- Picking up other crafts: anything you use that then has a cooldown of hours.
---------------------------------------------------------------------------
local function CheckCast(id)
	if me.cds[id] then return end
	local left, duration = SpellCooldown(id)
	if left and duration >= LEARN_MIN and left > 0 then
		local e = Track(id)
		if e then
			SetLeft(e, left)
			Print(("tracking %s (ready in %s)."):format(e.name, Left(left)))
			ns.Display.Refresh()
		end
	end
end

-- With the profession window open: every recipe with a cooldown running.
local function ScanRecipes()
	if InCombatLockdown() or not (C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs) then return end
	local ok, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
	if not ok or type(ids) ~= "table" then return end
	for _, id in ipairs(ids) do
		local left = RecipeCooldown(id)
		if left and left > REAL_MIN and (me.cds[id] or left >= LEARN_MIN) then
			local e = Track(id)
			if e then SetLeft(e, left) end
		end
	end
	ns.Display.Refresh()
end

---------------------------------------------------------------------------
-- Testing without the crafts
---------------------------------------------------------------------------
local TestCommand

local function FindSpell(text)
	local id = tonumber(text)
	if id then return id end
	if C_Spell and C_Spell.GetSpellInfo then
		local ok, info = pcall(C_Spell.GetSpellInfo, text)
		if ok and info then return info.spellID end
	elseif GetSpellInfo then
		return select(7, GetSpellInfo(text))
	end
end

local function Test(arg)
	TestCommand(arg)
	ns.Display.Refresh()
end

TestCommand = function(arg)
	if arg == "" then
		-- A pretend transmute that's ready in 10 seconds.
		local _, icon = SpellNameIcon(17187)
		me.cds.test = { name = "Transmute: Arcanite", icon = icon or "Interface\\Icons\\INV_Misc_StoneTablet_05",
			readyAt = Now() + 10, told = false, test = true }
		Print("test: a pretend Transmute: Arcanite, ready in 10 seconds.")
		C_Timer.After(10.5, function() Check(false) end)
		return
	end
	if arg == "clear" then
		local n = 0
		for _, c in pairs(db.chars) do
			for id, e in pairs(c.cds) do
				if e.test then c.cds[id] = nil n = n + 1 end
			end
		end
		Print(("removed %d test cooldown(s)."):format(n))
		return
	end
	local id = FindSpell(arg)
	if not id then
		Print(("can't find a spell called %s. Try its spell ID."):format(arg))
		return
	end
	local name = SpellNameIcon(id) or arg
	local left, duration = SpellCooldown(id)
	if not left then
		Print("can't read cooldowns in combat.")
		return
	end
	if duration < REAL_MIN or left <= 0 then
		Print(("%s isn't on a cooldown over a minute. Use it, then try again."):format(name))
		return
	end
	local e = me.cds[id] or Track(id, true)
	if not e then return end
	SetLeft(e, left)
	Print(("test: tracking %s (ready in %s). /fcd test clear to stop."):format(e.name, Left(left)))
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
		for k, v in pairs(DEFAULTS) do
			if db[k] == nil then db[k] = v end
		end
		ns.db = db
		local guid = UnitGUID("player")
		me = db.chars[guid] or { cds = {} }
		db.chars[guid] = me
		me.name = UnitName("player")
		me.class = select(2, UnitClass("player"))
		ns.me = me
		ns.Display.Init()
		ns.EditMode.Init()
		ns.Options.Init()
		C_Timer.After(5, function() Check(true) end) -- once the game has sent the cooldowns
		C_Timer.NewTicker(TICK, function() Check(false) end)
	elseif not me then
		return
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		-- Crafts aren't made in combat (where the cast details are hidden anyway).
		if InCombatLockdown() or Secret(unit) or unit ~= "player" then return end
		if Secret(spellID) or type(spellID) ~= "number" then return end
		-- The cooldown starts a moment after the cast.
		C_Timer.After(1, function() CheckCast(spellID) end)
		C_Timer.After(3, function() CheckCast(spellID) end)
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
	print("  /fcd - options")
	print("  /fcd list - cooldowns on all your characters, in chat")
	print("  /fcd test - a pretend transmute, ready in 10 seconds")
	print("  /fcd test <spell name or ID> - track one of your spells' cooldowns like a craft")
	print("  /fcd test clear - remove test cooldowns")
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
	elseif cmd == "test" then
		Test(arg)
	elseif cmd == "forget" and arg ~= "" then
		for guid, c in pairs(db.chars) do
			if c ~= me and c.name and c.name:lower() == arg:lower() then
				db.chars[guid] = nil
				Print(("forgot %s."):format(c.name))
				ns.Display.Refresh()
				return
			end
		end
		Print(("no other character called %s."):format(arg))
	else
		Help()
	end
end
