-- FireRoll: group rolls for chests and anything else that isn't a loot roll.
--
-- Someone clicks the dice button (or types /froll <what>), and everyone with
-- FireRoll gets a window with Roll and Pass. Once the whole group has rolled or
-- passed, the window shows who won; ties roll off automatically.
--
-- The numbers come from ordinary /rolls read from chat, so nobody can fake one
-- and players without the addon can still join in by typing /roll. Addon
-- messages only carry "a roll started", "I pass", "I have FireRoll" and the
-- final result, which the player who started the roll decides.
local _, ns = ...

local PREFIX = "FireRoll"
local TIMEOUT = 60      -- seconds before a roll ends without waiting for everyone
local HELLO_WAIT = 2    -- seconds for other FireRolls to say they're there
local GRACE = 5         -- extra seconds the others wait for the starter's result
local ROLLOFF_DELAY = 3 -- seconds between a tie and its roll-off
local MAX_MESSAGE = 250

local DEFAULTS = { button = true, chat = true }

local me
ns.roll = nil
ns.mine = {} -- ids of rolls this client started, to skip our own messages coming back

-- Shows chat text with its hidden codes visible.
local function Raw(text)
	return type(text) == "string" and (text:gsub("|", "||")) or tostring(text)
end

function ns.Print(msg) print("|cffff8000FireRoll|r: " .. msg) end

local function IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) and true or false end

---------------------------------------------------------------------------
-- Names and the group
---------------------------------------------------------------------------

-- Everyone is keyed by name, with the realm only for other realms - the same
-- way roll results and addon messages name them once passed through here.
local function Key(name)
	if not name or name == "" or IsSecret(name) then return nil end
	if Ambiguate then return Ambiguate(name, "none") end
	return name
end
ns.Key = Key

-- On Forever names have two parts ("First Last"), and UnitName gives the
-- surname where other clients give the realm - the game's own NameUtil joins
-- them with a space, and that full name is what chat and rolls use.
local function SurnameSeparator()
	local enabled = RegionalUniqueNamesEnabled and RegionalUniqueNamesEnabled()
	if not enabled then return nil end
	local c = Constants and Constants.CharacterNameSeparatorConsts
	return c and c.CHARACTERNAME_SURNAME_SEPARATOR or " "
end

local function UnitKey(unit)
	local name, second = UnitName(unit)
	if not name or IsSecret(name) then return nil end
	if second and second ~= "" and not IsSecret(second) then
		local sep = SurnameSeparator()
		if sep then name = name .. sep .. second
		else name = name .. "-" .. second:gsub("%s", "") end
	end
	return Key(name)
end

local function GroupUnits()
	local units = {}
	if IsInRaid() then
		for i = 1, GetNumGroupMembers() do units[#units + 1] = "raid" .. i end
	else
		units[1] = "player"
		for i = 1, GetNumSubgroupMembers() do units[#units + 1] = "party" .. i end
	end
	return units
end

local function Channel()
	if not IsInGroup() then return nil end
	local home, instance = LE_PARTY_CATEGORY_HOME, LE_PARTY_CATEGORY_INSTANCE
	if instance and IsInGroup(instance) and not (home and IsInGroup(home)) then return "INSTANCE_CHAT" end
	return IsInRaid() and "RAID" or "PARTY"
end

-- True while the game blocks addon chat (boss fights in instances).
local function Locked()
	local C = C_ChatInfo
	if not (C and C.InChatMessagingLockdown) then return false end
	local ok, locked = pcall(C.InChatMessagingLockdown)
	return ok and locked and true or false
end
ns.Locked = Locked

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

local function Send(...)
	local r = ns.roll
	if r and r.test then return end
	local channel = Channel()
	if not channel then return end
	local send = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
	if send then pcall(send, PREFIX, table.concat({ ... }, "\t"), channel) end
end

-- A line in group chat, for the players who don't have FireRoll.
local function Say(text)
	local channel = Channel()
	if not channel or Locked() or not ns.db.chat then return end
	local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
	if send then pcall(send, text, channel) end
end

-- Item links shown as plain [Name], for messages that would be too long.
local function PlainLabel(label)
	return (label:gsub("|c%x+|H.-|h(.-)|h|r", "%1"):gsub("|H.-|h(.-)|h", "%1"))
end

---------------------------------------------------------------------------
-- The roll in progress
---------------------------------------------------------------------------

local ticker

local function IsMember(r, key)
	return key ~= nil and r.isMember[key] or false
end
ns.IsMember = IsMember

-- Who has left or gone offline since the roll started; they aren't waited for.
local function CheckRoster(r)
	if r.test then return end
	local present = {}
	for _, unit in ipairs(GroupUnits()) do
		local key = UnitKey(unit)
		if key then present[key] = UnitIsConnected(unit) and "here" or "offline" end
	end
	for _, key in ipairs(r.members) do
		if r.status[key] == nil then
			local p = present[key]
			r.gone[key] = (not p and "left") or (p == "offline" and "offline") or nil
		end
	end
end

function ns.Waiting(r)
	local n = 0
	for _, key in ipairs(r.members) do
		if r.status[key] == nil and not r.gone[key] then n = n + 1 end
	end
	return n
end

local function Describe(key)
	return key == me and "You" or key
end

-- One line for group chat about how a roll ended.
local function ResultText(r)
	if #r.winners == 0 then return "Nobody rolled" .. (r.label and (" for " .. r.label) or "") .. "." end
	if #r.winners > 1 then
		return ("Tie at %d: %s roll off."):format(r.best, table.concat(r.winners, " and "))
	end
	return ("%s wins%s with %d."):format(r.winners[1], r.label and (" " .. r.label) or "", r.best)
end

local function StopTicker()
	if ticker then ticker:Cancel() ticker = nil end
end

local function SetResult(r, winners, best)
	r.done, r.winners, r.best = true, winners, best
	r.finishedAt = GetTime()
	StopTicker()
	ns.UI.Update()
	ns.UI.CloseLater(r)
	if #winners > 1 and (r.by == me or r.test) then
		C_Timer.After(ROLLOFF_DELAY, function()
			if ns.roll ~= r then return end
			ns.Start(r.label, winners, r.test, true)
			-- The group was told about the tie in chat, so tell them how it ends.
			if ns.roll ~= r and r.callOut then ns.roll.callOut = true end
		end)
	end
end

function ns.Finish()
	local r = ns.roll
	if not r or r.done then return end
	local best, winners = nil, {}
	for _, key in ipairs(r.members) do
		local v = r.status[key]
		if type(v) == "number" then
			if not best or v > best then best, winners = v, { key }
			elseif v == best then winners[#winners + 1] = key end
		end
	end
	SetResult(r, winners, best)
	if r.by == me then
		Send("E", r.id, table.concat(winners, ","), best and tostring(best) or "")
		if r.callOut then Say(ResultText(r)) end
	end
end

local function CheckDone(r)
	if r.done or ns.Waiting(r) > 0 then return end
	ns.Finish()
end

local function Tick()
	local r = ns.roll
	if not r or r.done then StopTicker() return end
	-- The starter decides; the others only give up on them after a grace period.
	local deadline = r.endsAt + ((r.by == me or r.test) and 0 or GRACE)
	if GetTime() >= deadline then ns.Finish() return end
	ns.UI.Update()
end

-- The same player can be named differently in different places: with or
-- without a realm, or with only part of a "First Last" name. Finds which
-- member a name means, or nil.
local function Norm(name) return (name:gsub("%-[^%-]*$", "")):lower() end -- drops a realm

local function FindMember(r, name)
	name = Key(name)
	if not name then return nil end
	if r.isMember[name] then return name end
	local n = Norm(name)
	for _, key in ipairs(r.members) do
		if Norm(key) == n then return key end
	end
	-- Part of a name (first name alone, or something in front): only if it
	-- fits exactly one member.
	local found
	for _, key in ipairs(r.members) do
		local k = Norm(key)
		if k:sub(1, #n + 1) == n .. " " or k:sub(-#n - 1) == " " .. n or n:sub(-#k - 1) == " " .. k then
			if found then return nil end
			found = key
		end
	end
	return found
end

-- Records a roll or a pass ("pass") for one player.
function ns.Record(name, value)
	local r = ns.roll
	if not r or r.done then return end
	local key = FindMember(r, name)
	if ns.debug then ns.Print(("  -> %s %s"):format(tostring(name), key and ("is " .. key) or "isn't in this roll")) end
	if not key or r.status[key] ~= nil then return end
	r.status[key] = value
	r.gone[key] = nil
	if key == me then r.rolling = nil end
	ns.UI.Update()
	CheckDone(r)
end

-- Sample group for /froll test, who roll (or pass) by themselves.
local TEST_GROUP = { { "Brakka", "WARRIOR" }, { "Lyssa", "PRIEST" }, { "Odric", "PALADIN" }, { "Tamsin", "ROGUE" } }

local function TestPlayers(r)
	for _, key in ipairs(r.members) do
		if key ~= me then
			C_Timer.After(1 + math.random() * 5, function()
				if ns.roll ~= r then return end
				ns.Record(key, (not r.rolloff and math.random() < 0.2) and "pass" or math.random(1, 100))
			end)
		end
	end
end

local function Begin(by, id, label, only, test, rolloff)
	local members, class = {}, {}
	if test then
		if not only or only[me] then members[1] = me; class[me] = select(2, UnitClass("player")) end
		for _, p in ipairs(TEST_GROUP) do
			if not only or only[p[1]] then members[#members + 1] = p[1]; class[p[1]] = p[2] end
		end
	else
		for _, unit in ipairs(GroupUnits()) do
			local key = UnitKey(unit)
			if key and (not only or only[key]) then
				members[#members + 1] = key
				class[key] = select(2, UnitClass(unit))
			end
		end
	end
	local isMember = {}
	for _, key in ipairs(members) do isMember[key] = true end
	local r = {
		by = by, id = id, label = (label and label ~= "") and label or nil,
		test = test, rolloff = rolloff,
		started = GetTime(), endsAt = GetTime() + TIMEOUT,
		members = members, isMember = isMember, class = class,
		status = {}, gone = {}, addon = { [me] = true, [by] = true },
	}
	ns.roll = r
	CheckRoster(r)
	StopTicker()
	ticker = C_Timer.NewTicker(1, Tick)
	C_Timer.After(HELLO_WAIT, function()
		if ns.roll ~= r then return end
		r.helloDone = true
		ns.UI.Update()
	end)
	ns.UI.Show(by ~= me)
	if test then TestPlayers(r) end
	CheckDone(r)
	return r
end

-- After everyone's FireRoll has had time to answer: if some players don't
-- have it, the starter tells them in group chat to type /roll.
local function CallOut(r)
	if ns.roll ~= r or r.done then return end
	local missing = {}
	for _, key in ipairs(r.members) do
		if not r.addon[key] and not r.gone[key] and r.status[key] == nil then missing[#missing + 1] = key end
	end
	if #missing == 0 then return end
	r.callOut = true
	local what = r.label and (" for " .. r.label) or ""
	if r.rolloff then
		Say(("Roll-off%s between %s: type /roll"):format(what, table.concat(r.members, ", ")))
	else
		Say(("Rolling%s: type /roll within %d seconds"):format(what, TIMEOUT))
	end
end

-- Starts a roll for the group. only = list of names for a roll-off.
function ns.Start(label, only, test, rolloff)
	local r = ns.roll
	if r and not r.done and not r.test and not test then
		ns.UI.Show()
		return
	end
	if not test then
		if not Channel() then
			ns.Print("you need to be in a group to start a roll. Type /froll test to try it alone.")
			return
		end
		if Locked() then
			ns.Print("the game blocks addon messages right now (boss fight?) - try again afterwards.")
			return
		end
	end
	label = label and strtrim(label) or ""
	local onlySet, onlyText
	if only then
		onlySet = {}
		for _, key in ipairs(only) do onlySet[key] = true end
		onlyText = table.concat(only, ",")
	end
	local id = tostring(math.random(100000, 999999))
	local function Message()
		return table.concat({ "S", id, label, onlyText or "", rolloff and "1" or "" }, "\t")
	end
	if #Message() > MAX_MESSAGE then label = PlainLabel(label) end
	if #Message() > MAX_MESSAGE then label = label:sub(1, math.max(0, #label - (#Message() - MAX_MESSAGE))) end

	ns.mine[id] = true
	r = Begin(me, id, label, onlySet, test, rolloff)
	Send("S", id, label, onlyText or "", rolloff and "1" or "")
	if not test then C_Timer.After(HELLO_WAIT, function() CallOut(r) end) end
end

function ns.Roll()
	local r = ns.roll
	if not r or r.done or not IsMember(r, me) or r.status[me] ~= nil then return end
	r.rolling = true
	ns.UI.Update()
	if r.test and not RandomRoll then ns.Record(me, math.random(1, 100)) return end
	RandomRoll(1, 100)
end

function ns.Pass()
	local r = ns.roll
	if not r or r.done or not IsMember(r, me) or r.status[me] ~= nil then return end
	Send("P", r.id)
	ns.Record(me, "pass")
end

function ns.Me() return me end
function ns.Describe(key) return Describe(key) end

---------------------------------------------------------------------------
-- Incoming
---------------------------------------------------------------------------

local function Split(text)
	local list = {}
	for name in (text or ""):gmatch("[^,]+") do list[#list + 1] = name end
	return list
end

local function OnAddonMessage(prefix, text, _, sender)
	if prefix ~= PREFIX then return end
	if IsSecret(text) or IsSecret(sender) then
		if ns.debug then ns.Print("addon message hidden by the game") end
		return
	end
	local kind, id, a, b, c = strsplit("\t", text)
	local from = Key(sender)
	-- Our own start and result coming back, even if the game names us oddly.
	-- (Replies to our roll carry its id too, so only S and E count.)
	local own = (from and me and Norm(from) == Norm(me)) or ((kind == "S" or kind == "E") and id and ns.mine[id])
	if ns.debug then ns.Print(("addon message %s from %s%s"):format(Raw(kind), Raw(sender), own and " (mine)" or "")) end
	if not from or own then return end
	local r = ns.roll
	-- Name them the way the group list does, if they're in this roll.
	if r and r.id == id then from = FindMember(r, from) or from end

	if kind == "S" then
		-- Two rolls started at the same moment: everyone keeps the one whose
		-- starter's name sorts first, so all windows agree.
		if r and not r.done and not r.test and r.by ~= from and r.by < from then return end
		local only
		if b and b ~= "" then
			only = {}
			for _, key in ipairs(Split(b)) do only[key] = true end
		end
		local nr = Begin(from, id, a, only, false, c == "1")
		local key = FindMember(nr, from)
		if key and key ~= from then
			nr.by = key
			nr.addon[key] = true
			ns.UI.Update()
		end
		Send("H", id)
		return
	end

	if not (r and r.id == id) then return end
	if kind == "H" then
		r.addon[from] = true
		ns.UI.Update()
	elseif kind == "P" then
		r.addon[from] = true
		ns.Record(from, "pass")
	elseif kind == "E" and from == r.by then
		-- The starter's result is the one that counts.
		local best = tonumber(b)
		local winners = Split(a)
		for i, name in ipairs(winners) do winners[i] = FindMember(r, name) or name end
		StopTicker()
		r.done = false
		SetResult(r, winners, best)
	end
end

-- "%s rolls %d (%d-%d)" as a pattern.
local ROLL_PATTERN
local function RollPattern()
	local s = RANDOM_ROLL_RESULT or "%s rolls %d (%d-%d)"
	s = s:gsub("%%%d%$", "%%") -- "%1$s" -> "%s"
	s = s:gsub("([%(%)%.%[%]%*%+%-%?%^%$])", "%%%1")
	s = s:gsub("%%s", "(.+)"):gsub("%%d", "(%%d+)")
	return "^" .. s .. "$"
end

local function OnSystemMessage(text)
	local r = ns.roll
	if not r or r.done then return end
	if IsSecret(text) or type(text) ~= "string" then
		if ns.debug then ns.Print("system message hidden by the game") end
		return
	end
	if ns.debug then ns.Print("system message: " .. Raw(text)) end
	-- Drop colours and links: "|cff...|Hplayer:Name|h[Name]|h|r rolls..."
	text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h(.-)|h", "%1")
	ROLL_PATTERN = ROLL_PATTERN or RollPattern()
	local name, value, low, high = text:match(ROLL_PATTERN)
	if not name then return end
	name = name:gsub("^%[(.*)%]$", "%1")
	if tonumber(low) ~= 1 or tonumber(high) ~= 100 then
		if ns.debug then ns.Print(("  -> a %s-%s roll, only 1-100 counts"):format(low, high)) end
		return
	end
	ns.Record(name, tonumber(value))
end

local function OnRoster()
	local r = ns.roll
	if r and not r.done and not r.test then
		if not IsInGroup() then
			StopTicker()
			ns.roll = nil
			ns.UI.Hide()
		else
			CheckRoster(r)
			ns.UI.Update()
			CheckDone(r)
		end
	end
	ns.UI.UpdateButton()
end

---------------------------------------------------------------------------
-- Events and slash command
---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("CHAT_MSG_ADDON")
events:RegisterEvent("CHAT_MSG_SYSTEM")
pcall(events.RegisterEvent, events, "UNIT_CONNECTION")
events:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" then
		if ... ~= "FireRoll" then return end
		FireRollDB = FireRollDB or {}
		ns.db = FireRollDB
		for k, v in pairs(DEFAULTS) do
			if ns.db[k] == nil then ns.db[k] = v end
		end
		local register = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
		if register then pcall(register, PREFIX) end
	elseif event == "PLAYER_LOGIN" then
		me = UnitKey("player")
		ns.UI.UpdateButton()
	elseif event == "CHAT_MSG_ADDON" then
		OnAddonMessage(...)
	elseif event == "CHAT_MSG_SYSTEM" then
		OnSystemMessage(...)
	elseif event == "GROUP_ROSTER_UPDATE" or event == "UNIT_CONNECTION" then
		OnRoster()
	end
end)

SLASH_FIREROLL1 = "/froll"
SLASH_FIREROLL2 = "/fireroll"
SlashCmdList.FIREROLL = function(input)
	input = strtrim(input or "")
	local cmd = input:lower()
	if cmd == "test" then
		ns.Start("Test chest", nil, true)
	elseif cmd == "debug" then
		ns.debug = not ns.debug
		ns.Print(ns.debug and ("debug on: you are \"%s\". Messages are shown during a roll. /froll debug again to stop."):format(Raw(me))
			or "debug off.")
		if ns.debug then
			for _, unit in ipairs(GroupUnits()) do
				local name, realm = UnitName(unit)
				print(("  %s: %s / %s -> %s"):format(unit, Raw(name), Raw(realm), Raw(UnitKey(unit))))
			end
		end
	elseif cmd == "options" or cmd == "config" then
		ns.Options.Open()
	elseif cmd == "end" then
		local r = ns.roll
		if r and not r.done and (r.by == me or r.test) then ns.Finish()
		else ns.Print("you don't have a roll going.") end
	elseif cmd == "help" or cmd == "?" then
		ns.Print("commands:")
		print("  /froll - start a roll for the group (same as clicking the dice)")
		print("  /froll <what> - roll for something, e.g. /froll chest, or shift-click an item")
		print("  /froll end - end your roll now, with whoever has rolled")
		print("  /froll test - try the window alone, with a pretend group")
		print("  /froll options - open the options")
	else
		ns.Start(input)
	end
end
