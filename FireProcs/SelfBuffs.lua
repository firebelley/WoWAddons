-- Buff reminders: your own long buffs (Water Shield, Lightning Shield, Demon
-- Armor, Ice Armor, Inner Fire...) are announced when they're gone, and/or
-- keep an icon up until you cast them again.
--
-- Which buffs: any buff you cast on yourself from your spellbook that lasts a
-- minute or more. They're learned as you cast them, and each can be turned off
-- in Options > AddOns > FireProcs > Buffs (or /fprocs buffs).
--
-- In combat your buffs are hidden from addons, but each buff's ID number
-- isn't: a buff seen before the fight can still be checked for by its ID, so
-- losing it mid-fight (charges used up, dispelled, expired) is caught.
--
-- Not reminded: recasting it (refresh), swapping it for an alternative (Water
-- Shield for Lightning Shield - these get linked so either one counts),
-- cancelling it yourself out of combat, or losing it by dying (that one is
-- reminded once you're alive again).
local _, ns = ...
local API, Spells = ns.API, ns.Spells

local MIN_DURATION = 60  -- seconds; shorter buffs aren't worth reminding about
local CANCEL_LEFT = 5    -- gone out of combat with this much time left = cancelled on purpose
local ANNOUNCE_THROTTLE = 3
local LOGIN_CHECK = 5    -- seconds after login before checking what's missing

local SelfBuffs = {}
ns.SelfBuffs = SelfBuffs

local present = {}  -- [name] = { instance, expires, icon } for tracked buffs on you now
local missing = {}  -- [group] = name of the buff to show for it
local diedWith = {} -- [name] = true for buffs lost by dying
local lastIDs       -- aura instance IDs at the last update
local live = false
local announcedAt = {}

local function Entry(name) return ns.db.selfBuffs[name] end

local function Enabled(name)
	local e = Entry(name)
	return e and e.on ~= false and ns.db.remindBuffs ~= false
end

-- Alternatives (the shaman shields...) share a group; either one counts.
local function GroupOf(name)
	local e = Entry(name)
	return e and e.group or name
end

local function Link(a, b)
	local ga, gb = GroupOf(a), GroupOf(b)
	if ga == gb then return end
	for name, e in pairs(ns.db.selfBuffs) do
		if GroupOf(name) == gb then e.group = ga end
	end
	Entry(a).group = ga
	ns.Trace(("%s and %s replace each other: either one counts"):format(a, b))
end

local function GroupPresent(group)
	for name in pairs(present) do
		if GroupOf(name) == group then return true end
	end
	return false
end

-- A buff worth reminding about: yours, from a spell in your spellbook, long.
local function IsCandidate(a)
	return a.source == "player" and (a.duration or 0) >= MIN_DURATION
		and Spells.active[a.name] ~= nil
end

local function Learn(a)
	local db = ns.db
	if db.selfBuffs[a.name] then
		db.selfBuffs[a.name].icon = a.icon or db.selfBuffs[a.name].icon
		return
	end
	db.selfBuffs[a.name] = { icon = a.icon, on = true }
	ns.Print(("I'll let you know when |cffffd100%s|r is gone. Turn that off in /fprocs buffs."):format(a.name))
end

local function Show()
	local list = {}
	if ns.db.remindIcon ~= false then
		for group, name in pairs(missing) do
			if Enabled(name) then
				list[#list + 1] = { name = name, icon = Entry(name).icon }
			else
				missing[group] = nil
			end
		end
	end
	table.sort(list, function(a, b) return a.name < b.name end)
	ns.Display.SetMissing(list)
end

-- name is gone and should be recast.
local function Remind(name, announce)
	if not Enabled(name) or GroupPresent(GroupOf(name)) then return end
	missing[GroupOf(name)] = name
	if announce and ns.db.remindAnnounce ~= false then
		local now = GetTime()
		if now - (announcedAt[name] or -100) >= ANNOUNCE_THROTTLE then
			announcedAt[name] = now
			ns.Display.Alert(name .. " is gone", Entry(name).icon)
		end
	end
	ns.Trace(name .. " is gone: reminding")
end

-- now: the tracked buffs after this update (present still holds the old ones).
local function Lost(name, info, now)
	if Spells.WasRecentlyCast(name) then
		return ns.Trace(name .. " went away as you recast it (refreshed)")
	end
	-- Replaced by another buff of yours that appeared at the same moment.
	for other in pairs(now) do
		if other ~= name and not present[other] and Spells.WasRecentlyCast(other) then
			Link(other, name)
			return
		end
	end
	if UnitIsDeadOrGhost("player") then
		diedWith[name] = true
		return
	end
	if not UnitAffectingCombat("player") and not API.AurasRestricted()
		and (info.expires or 0) - GetTime() > CANCEL_LEFT then
		return ns.Trace(name .. " went away out of combat with time left: assumed cancelled on purpose")
	end
	Remind(name, true)
end

function SelfBuffs.Update()
	if not ns.db then return end
	local restricted = API.AurasRestricted()
	local now = {}
	API.ForEachAura("player", "HELPFUL", function(a)
		if IsCandidate(a) then
			Learn(a)
			now[a.name] = { instance = a.instance, expires = a.expires, icon = a.icon }
		end
	end)

	local ids = API.AuraInstanceIDs("player", "HELPFUL")
	if restricted then
		-- Hidden buffs: still there if their ID is (or assumed so, without an ID).
		for name, info in pairs(present) do
			if not now[name] and (not (info.instance and ids) or ids[info.instance]) then
				now[name] = info
			end
		end
		-- A hidden buff you just cast: the new ID that appeared with it.
		if ids and lastIDs then
			local new = {}
			for id in pairs(ids) do
				if not lastIDs[id] then new[#new + 1] = id end
			end
			if #new > 0 then
				for name, e in pairs(ns.db.selfBuffs) do
					if not now[name] and Spells.WasRecentlyCast(name) then
						now[name] = { instance = #new == 1 and new[1] or nil, expires = 0, icon = e.icon }
						break
					end
				end
			end
		end
	end
	lastIDs = ids

	if live then
		for name, info in pairs(present) do
			if not now[name] then Lost(name, info, now) end
		end
	end
	present = now

	for group in pairs(missing) do
		if GroupPresent(group) then missing[group] = nil end
	end
	Show()
end

-- After logging in: anything you usually have up that isn't.
local function CheckAtLogin()
	if UnitIsDeadOrGhost("player") then return end
	SelfBuffs.Update() -- the spellbook may not have been ready at the first look
	local groups = {}
	for name in pairs(ns.db.selfBuffs) do
		local g = GroupOf(name)
		if Enabled(name) and not GroupPresent(g) and not groups[g] then
			groups[g] = true
			Remind(name, false)
		end
	end
	Show()
end

-- For the options page.
function SelfBuffs.Refresh()
	for group, name in pairs(missing) do
		if not Enabled(name) then missing[group] = nil end
	end
	SelfBuffs.Update()
end

function SelfBuffs.GroupOf(name) return GroupOf(name) end

-- For /fprocs status: what's up, what's missing, and whether IDs can be read.
function SelfBuffs.Describe()
	local up, gone = {}, {}
	for name, info in pairs(present) do
		up[#up + 1] = name .. (info.instance and "" or " (no ID)")
	end
	for _, name in pairs(missing) do gone[#gone + 1] = name end
	table.sort(up)
	table.sort(gone)
	return ("up: %s; missing: %s; buff IDs readable: %s"):format(
		#up > 0 and table.concat(up, ", ") or "none", #gone > 0 and table.concat(gone, ", ") or "none",
		API.AuraInstanceIDs("player", "HELPFUL") and "yes" or "no")
end

ns.OnUnit("UNIT_AURA", "player", function() SelfBuffs.Update() end)
ns.On("PLAYER_REGEN_ENABLED", function() SelfBuffs.Update() end)

ns.On("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
	live = false
	SelfBuffs.Update()
	live = true
	if isLogin or isReload then C_Timer.After(LOGIN_CHECK, function() ns.SafeCall(CheckAtLogin) end) end
end)

local function Revived()
	if UnitIsDeadOrGhost("player") then return end
	C_Timer.After(1, function()
		ns.SafeCall(function()
			for name in pairs(diedWith) do Remind(name, true) end
			wipe(diedWith)
			Show()
		end)
	end)
end
ns.On("PLAYER_ALIVE", Revived)
ns.On("PLAYER_UNGHOST", Revived)
