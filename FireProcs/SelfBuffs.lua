-- Buff reminders: your own long buffs (Water Shield, Lightning Shield, Demon
-- Armor, Ice Armor, Inner Fire...) are announced when they're gone, and/or
-- keep an icon up until you cast them again.
--
-- Which buffs: any buff you cast on yourself from your spellbook that lasts a
-- minute or more. They're learned as you cast them, and each can be turned off
-- in Options > AddOns > FireProcs > Buffs (or /fprocs buffs).
--
-- Everything is driven by the game's buff updates (it sends one when a buff
-- runs out, too) - nothing runs on a timer. In combat your buffs are hidden
-- from addons, but a buff seen before the fight can still be checked for by
-- its ID, and its end time is known (estimated from the cast when recast
-- mid-fight), so losing it mid-fight (expired, dispelled, charges used up)
-- is caught. Anything the game wouldn't tell us is caught when combat ends.
--
-- Not reminded: recasting it (refresh), swapping it for an alternative (Water
-- Shield for Lightning Shield - these get linked so either one counts),
-- cancelling it yourself out of combat, or losing it by dying (that one is
-- reminded once you're alive again).
local _, ns = ...
local API, Spells = ns.API, ns.Spells

local MIN_DURATION = 60  -- seconds; shorter buffs aren't worth reminding about
local CANCEL_WINDOW = 1  -- a buff gone this soon after you right-click one off = cancelled on purpose
local ANNOUNCE_THROTTLE = 3
local LOGIN_CHECK = 5    -- seconds after login before checking what's missing
local END_MARGIN = 1     -- in combat, a hidden buff this close to its end time counts as gone

local SelfBuffs = {}
ns.SelfBuffs = SelfBuffs

local present = {}  -- [name] = { instance, expires, icon } for tracked buffs on you now
local missing = {}  -- [group] = name of the buff to show for it
local diedWith = {} -- [name] = true for buffs lost by dying
local lastIDs       -- aura instance IDs at the last update
local live = false
local announcedAt = {}
local cancelledAt = -100 -- when you last right-clicked a buff off
local traceIDs = false   -- debug: said whether IDs are readable this fight
local updateSource       -- debug: what triggered the current look at your buffs

-- Right-clicking a buff (and /cancelaura macros via the buff frame) goes
-- through these; a buff that vanishes right after was cancelled, not lost.
local function OnCancel() cancelledAt = GetTime() end
for _, fn in ipairs({ "CancelUnitBuff", "CancelSpellByName" }) do
	if type(_G[fn]) == "function" then hooksecurefunc(fn, OnCancel) end
end
if C_UnitAuras and C_UnitAuras.CancelAuraByInstanceID then
	pcall(hooksecurefunc, C_UnitAuras, "CancelAuraByInstanceID", OnCancel)
end

-- Seconds until a buff runs out, or nil when its timer can't be trusted.
local function TimeLeft(info)
	local e = info.expires or 0
	if e <= 0 then return nil end
	local left = e - GetTime()
	if left < -60 or left > 7200 then return nil end -- not on the same clock
	return left
end

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
-- Returns true, or false plus the reason.
local function IsCandidate(a)
	-- (Some buffs carry no caster; one named after your own spell is yours.)
	if a.source ~= "player" and a.source ~= nil then return false, "not cast by you (from " .. tostring(a.source) .. ")" end
	if (a.duration or 0) < MIN_DURATION then return false, ("lasts %ss (under %ss)"):format(tostring(a.duration), MIN_DURATION) end
	if Spells.active[a.name] == nil then
		return false, ("no spell named %q in your spellbook (%d spells read)"):format(a.name, Spells.count)
	end
	return true
end

local function Learn(a)
	local db = ns.db
	local e = db.selfBuffs[a.name]
	if e then
		e.icon = a.icon or e.icon
		e.duration = a.duration or e.duration -- to time it when recast in combat
		return
	end
	db.selfBuffs[a.name] = { icon = a.icon, on = true, duration = a.duration }
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
	if not Enabled(name) then return ns.Trace(name .. " is gone, but its reminder is turned off") end
	if GroupPresent(GroupOf(name)) then return ns.Trace(name .. " is gone, but an alternative to it is up") end
	missing[GroupOf(name)] = name
	if announce and ns.db.remindAnnounce ~= false then
		local now = GetTime()
		if now - (announcedAt[name] or -100) >= ANNOUNCE_THROTTLE then
			announcedAt[name] = now
			ns.Display.Alert(name .. " is gone", Entry(name).icon)
		end
	end
	ns.Trace(("%s is gone: reminding (noticed by the %s)"):format(name, updateSource or "game"))
end

-- Called after present has been updated; old: the tracked buffs before.
local function Lost(name, info, old)
	if Spells.WasRecentlyCast(name) then
		return ns.Trace(name .. " went away as you recast it (refreshed)")
	end
	-- Replaced by another buff of yours that appeared at the same moment.
	for other in pairs(present) do
		if other ~= name and not old[other] and Spells.WasRecentlyCast(other) then
			Link(other, name)
			return
		end
	end
	if UnitIsDeadOrGhost("player") then
		diedWith[name] = true
		return
	end
	if GetTime() - cancelledAt < CANCEL_WINDOW and not UnitAffectingCombat("player") then
		if not SelfBuffs.remindCancelled then
			return ns.Trace(name .. " was cancelled by you out of combat: not reminding")
		end
		ns.Trace(name .. " was cancelled by you, but /fprocs testcancel is on: reminding anyway")
	end
	Remind(name, true)
end

-- source: what triggered this look, for debug output.
function SelfBuffs.Update(source)
	if not ns.db then return end
	updateSource = source
	local restricted = API.AurasRestricted()
	local now = {}
	API.ForEachAura("player", "HELPFUL", function(a)
		if IsCandidate(a) then
			Learn(a)
			local info = { instance = a.instance, expires = a.expires, icon = a.icon }
			-- Still listed a moment after its end time: it's gone, the list is stale.
			local left = TimeLeft(info)
			if not (left and left < -1) then now[a.name] = info end
		end
	end)

	local ids = API.AuraInstanceIDs("player", "HELPFUL")
	if restricted and ns.tracing and not traceIDs then
		traceIDs = true
		local n = 0
		for _ in pairs(ids or {}) do n = n + 1 end
		ns.Trace(ids and ("in combat: %d buff IDs readable"):format(n) or "in combat: buff IDs not readable")
	elseif not restricted then
		traceIDs = false
	end
	if restricted then
		-- Hidden buffs: still there unless their ID says otherwise (the full ID
		-- list, or asking for that one ID) - and not at their end time. The
		-- game's update for a buff running out can come a moment before the end
		-- time we have for it (especially one estimated from a cast), hence the
		-- margin.
		for name, info in pairs(present) do
			local left = TimeLeft(info)
			local there = not (left ~= nil and left <= END_MARGIN)
			if there and info.instance then
				if ids then
					there = ids[info.instance] and true or false
				else
					local exists = API.AuraInstanceExists("player", info.instance)
					if exists ~= nil then there = exists end
				end
			end
			if not now[name] and there then now[name] = info end
		end
		-- A hidden buff you just cast (or recast): it's up for its full duration.
		-- Its new ID, if one clearly appeared with it, lets us watch it closely.
		local new = {}
		if ids and lastIDs then
			for id in pairs(ids) do
				if not lastIDs[id] then new[#new + 1] = id end
			end
		end
		for name, e in pairs(ns.db.selfBuffs) do
			local info = now[name]
			if Spells.WasRecentlyCast(name) and not (info and info.recastAt and GetTime() - info.recastAt < 3) then
				local t = GetTime()
				now[name] = {
					instance = (#new == 1 and new[1]) or (info and info.instance) or nil,
					expires = (e.duration or 0) > 0 and t + e.duration or 0,
					icon = e.icon, recastAt = t,
				}
				ns.Trace(("%s cast in combat: counted as up for %ss"):format(name, tostring(e.duration)))
			end
		end
	end
	lastIDs = ids

	-- Swap in the new list first: the reminder checks what's up *now*.
	local old = present
	present = now
	for name, info in pairs(old) do
		if not now[name] then
			if live then
				Lost(name, info, old)
			else
				ns.Trace(name .. " not seen right after a loading screen: checking again shortly")
			end
		end
	end

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
		local left = TimeLeft(info)
		up[#up + 1] = name .. (info.instance and "" or " (no ID)")
			.. (left and (" %dm%02ds left"):format(math.floor(left / 60), math.floor(left % 60))
				or (" (timer unreadable: ends %s, now %.0f)"):format(tostring(info.expires), GetTime()))
	end
	for _, name in pairs(missing) do gone[#gone + 1] = name end
	table.sort(up)
	table.sort(gone)
	local known = {}
	for name, e in pairs(ns.db.selfBuffs) do known[#known + 1] = name .. (e.on == false and " (off)" or "") end
	table.sort(known)
	return ("watching: %s; up: %s; missing: %s; buff IDs readable: %s"):format(
		#known > 0 and table.concat(known, ", ") or "none",
		#up > 0 and table.concat(up, ", ") or "none", #gone > 0 and table.concat(gone, ", ") or "none",
		API.AuraInstanceIDs("player", "HELPFUL") and "yes" or "no")
end

-- For /fprocs status: why each buff you have is or isn't watched.
function SelfBuffs.DescribeCurrent()
	local any = false
	local hidden = API.ForEachAura("player", "HELPFUL", function(a)
		any = true
		local ok, why = IsCandidate(a)
		print(("    %s (%ss, from %s): %s"):format(a.name, tostring(a.duration), tostring(a.source),
			ok and "|cff40ff40watched|r" or ("not watched - " .. why)))
	end)
	if not any then print("    (no readable buffs)") end
	if (hidden or 0) > 0 then print(("    + %d buff(s) hidden from addons right now"):format(hidden)) end
end

ns.OnUnit("UNIT_AURA", "player", function() SelfBuffs.Update("game's buff update") end)

-- Buffs can stay hidden for a moment after combat ends; look again shortly
-- after, so anything lost in the fight is caught even if no buff changes.
ns.On("PLAYER_REGEN_ENABLED", function()
	SelfBuffs.Update("end of combat")
	C_Timer.After(1, function() ns.SafeCall(SelfBuffs.Update, "end of combat") end)
	C_Timer.After(3, function() ns.SafeCall(SelfBuffs.Update, "end of combat") end)
end)

-- After a loading screen your buffs can take a moment to come back, so look
-- silently first - then remind about anything from before it that didn't.
ns.On("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
	local before = {}
	for name in pairs(present) do before[name] = true end
	live = false
	SelfBuffs.Update()
	live = true
	if isLogin or isReload then
		C_Timer.After(LOGIN_CHECK, function() ns.SafeCall(CheckAtLogin) end)
	else
		C_Timer.After(LOGIN_CHECK, function()
			ns.SafeCall(function()
				SelfBuffs.Update()
				for name in pairs(before) do
					if not present[name] then
						if UnitIsDeadOrGhost("player") then
							diedWith[name] = true
						else
							Remind(name, true)
						end
					end
				end
				Show()
			end)
		end)
	end
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
