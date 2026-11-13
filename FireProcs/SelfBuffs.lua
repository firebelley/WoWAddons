-- Buff reminders: your own long buffs (Water Shield, Lightning Shield, Demon
-- Armor, Ice Armor, Inner Fire...) are announced when they're gone, and/or
-- keep an icon up until you cast them again.
--
-- Which buffs: any buff you cast on yourself from your spellbook that lasts a
-- minute or more, plus spells of yours the game credits to your pet (Soul
-- Link, which has no timer and drops when the pet dies or is dismissed). They're learned as you cast them, and each can be turned off
-- in Options > AddOns > FireProcs > Buffs (or /fprocs buffs).
--
-- Tracking (Find Minerals, Find Herbs, Track Beasts...) counts too: it's read
-- from the minimap's tracking menu, and reminded when it goes off on its own
-- (dying, mostly) - not when you switch it off or to another one yourself.
--
-- Temporary weapon enchants (Firestone, poisons, sharpening stones, a
-- shaman's weapon imbues...) count too: they're on the weapon, not buffs, and
-- readable even in combat. Learned the first time you have one; reminded when
-- it runs out - not when you swap that weapon out or right-click it off.
--
-- Short buffs you keep up yourself (seals, Slice and Dice): under a minute,
-- from a spell with no cooldown of its own. These are combat-only: when one
-- drops during a fight, an alert and an icon until you recast it or the fight
-- ends; nothing out of combat. Short buffs
-- from spells with a cooldown (Sprint, Evasion, Shield Wall) are left alone -
-- they're meant to run out.
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
local GCD = 2            -- a cooldown this short right after casting is just the global cooldown
local JUDGEMENT = "Judgement" -- uses up a paladin's seal on purpose

local SelfBuffs = {}
ns.SelfBuffs = SelfBuffs

local present = {}  -- [name] = { instance, expires, icon } for tracked buffs on you now
local missing = {}  -- [group] = name of the buff to show for it
local missingSince = {} -- [group] = when it went missing, for hiding the icon after a while
local hideTimer     -- hides the next icon whose time is up (Options: "Hide the icon after")
local dismissed = {} -- [group] = true: icon right-clicked away, until the buff is back (this session)
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
-- Right-clicking a weapon enchant off.
if C_Spell and C_Spell.CancelItemTempEnchantment then
	pcall(hooksecurefunc, C_Spell, "CancelItemTempEnchantment", OnCancel)
end
if type(CancelItemTempEnchantment) == "function" then hooksecurefunc("CancelItemTempEnchantment", OnCancel) end
-- Turning tracking off (or switching it) on the minimap's tracking menu.
if type(CancelTrackingBuff) == "function" then hooksecurefunc("CancelTrackingBuff", OnCancel) end
if C_Minimap then
	for _, fn in ipairs({ "SetTracking", "ClearAllTracking" }) do
		if C_Minimap[fn] then pcall(hooksecurefunc, C_Minimap, fn, OnCancel) end
	end
end

-- Tracking abilities (Find Minerals, Find Herbs, Find Treasure, a hunter's
-- Track Beasts...) aren't buffs here but switches on the minimap's tracking
-- menu, so they're read from there. Calls fn(name, icon) for each one that's on.
local trackingKnown = {} -- [name] = true for tracking abilities you have, on or off
local function ForEachTracking(fn)
	local M = C_Minimap
	if not (M and M.GetNumTrackingTypes and M.GetTrackingInfo) then return end
	wipe(trackingKnown)
	for i = 1, M.GetNumTrackingTypes() or 0 do
		local ok, info, texture, active, kind = pcall(M.GetTrackingInfo, i)
		if ok and type(info) == "string" then -- older form: separate values
			info = { name = info, texture = texture, active = active, type = kind }
		end
		if ok and type(info) == "table" and info.type == "spell" and type(info.name) == "string"
			and not API.IsSecret(info.name) and not API.IsSecret(info.active) then
			trackingKnown[info.name] = true
			if info.active then fn(info.name, info.texture) end
		end
	end
end

-- Temporary weapon enchants. Calls fn(inventory slot, enchant info) for each.
local WEAPON_INV_SLOT = { [0] = 16, [1] = 17, [2] = 18 } -- Enum.WeaponSlot -> main hand, off hand, ranged
local SLOT_LABEL = { [16] = "Main hand", [17] = "Off hand", [18] = "Ranged" }
local function ForEachEnchant(fn)
	if not (C_Item and C_Item.GetWeaponEnchantInfo and Enum and Enum.WeaponSlot) then return end
	for _, slot in pairs(Enum.WeaponSlot) do
		local inv = WEAPON_INV_SLOT[slot]
		local ok, enchants = pcall(C_Item.GetWeaponEnchantInfo, slot)
		if inv and ok and type(enchants) == "table" then
			for _, e in pairs(enchants) do
				if type(e) == "table" and not API.IsSecret(e.hasEnchant) and e.hasEnchant then fn(inv, e) end
			end
		end
	end
end

-- An enchant's name, from the weapon's tooltip: the green line like
-- "Firestone 1 (2 hrs)" -> "Firestone". Remembered by enchant ID; if the
-- tooltip can't be read, "Main hand enchant".
local function EnchantName(inv, enchantID)
	if API.IsSecret(enchantID) then enchantID = nil end
	local names = ns.db.enchantNames
	if enchantID and names[enchantID] then return names[enchantID] end
	local T = C_TooltipInfo
	local ok, data = false, nil
	if T and T.GetInventoryItem then ok, data = pcall(T.GetInventoryItem, "player", inv) end
	if ok and type(data) == "table" and type(data.lines) == "table" then
		for _, line in ipairs(data.lines) do
			local text, c = line.leftText, line.leftColor
			if type(text) == "string" and not API.IsSecret(text) and type(c) == "table" and type(c.r) == "number"
				and not API.IsSecret(c.r) and c.r < 0.2 and c.g > 0.8 and c.b < 0.2 then
				local name = text:match("^(.-)%s*%(%d[^%)]*%)$")
				if name and name ~= "" then
					name = name:gsub("%s+%d+$", "")
					if enchantID then names[enchantID] = name end
					return name
				end
			end
		end
	end
	return (SLOT_LABEL[inv] or "Weapon") .. " enchant"
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

-- A short buff you keep up yourself (a seal): its spell has no cooldown. Only
-- decided right after you cast it out of combat, when the cooldown it started
-- can be read (in combat cooldowns are hidden); remembered once learned.
local maintained = {} -- [name] = true/false, decided this session
local function IsMaintained(name)
	local e = Entry(name)
	if e then return e.combat == true end
	if maintained[name] ~= nil then return maintained[name] end
	if API.AurasRestricted() or not Spells.WasRecentlyCast(name) then return false end
	local _, cooldown = API.SpellCooldown(Spells.active[name])
	maintained[name] = cooldown <= GCD
	return maintained[name]
end

-- A buff worth reminding about: yours, from a spell in your spellbook, long -
-- or short and kept up by you (combat-only reminders).
-- Returns true plus "combat" for those, or false plus the reason.
local function IsCandidate(a)
	local inBook = Spells.active[a.name] ~= nil
	-- Your spell that the game says your pet applied, like Soul Link: it lasts
	-- until the pet dies or is dismissed (no timer), and is worth recasting.
	if a.source == "pet" and inBook then return true end
	-- (Some buffs carry no caster; one named after your own spell is yours.)
	if a.source ~= "player" and a.source ~= nil then return false, "not cast by you (from " .. tostring(a.source) .. ")" end
	if not inBook then
		return false, ("no spell named %q in your spellbook (%d spells read)"):format(a.name, Spells.count)
	end
	local duration = a.duration or 0
	if duration >= MIN_DURATION then return true end
	if duration > 0 and IsMaintained(a.name) then return true, "combat" end
	if duration > 0 and maintained[a.name] == false then
		return false, ("lasts %ss and its spell has a cooldown, so it's meant to run out"):format(tostring(duration))
	end
	return false, ("lasts %ss (under %ss; short buffs from spells without a cooldown, like seals, are watched "
		.. "in combat once you cast them out of combat)"):format(tostring(duration), MIN_DURATION)
end

local function Learn(a, kind)
	local db = ns.db
	local e = db.selfBuffs[a.name]
	if e then
		e.icon = a.icon or e.icon
		e.duration = a.duration or e.duration -- to time it when recast in combat
		e.spellId = a.spellId or e.spellId     -- to ask whether it's hidden in combat
		if kind == "tracking" then e.tracking = true end
		if kind == "enchant" then e.enchant = true end
		return
	end
	db.selfBuffs[a.name] = { icon = a.icon, on = true, duration = a.duration, spellId = a.spellId,
		combat = kind == "combat" or nil,
		tracking = kind == "tracking" or nil, enchant = kind == "enchant" or nil }
	if a.quiet then return end
	if kind == "tracking" then
		ns.Print(("I'll let you know when |cffffd100%s|r is turned off. Turn that off in /fprocs buffs."):format(a.name))
	elseif kind == "combat" then
		ns.Print(("I'll let you know if |cffffd100%s|r drops during a fight. Turn that off in /fprocs buffs."):format(a.name))
	else
		ns.Print(("I'll let you know when |cffffd100%s|r is gone. Turn that off in /fprocs buffs."):format(a.name))
	end
end

-- Icons for what's missing. With a time limit set, an icon goes once it's been
-- up that long (the buff still counts as missing, so it isn't announced again
-- until you've recast it and lost it again).
local function Show()
	local list = {}
	local limit = (ns.db.remindIconMinutes or 0) * 60
	local soonest -- seconds until the next icon's time is up
	-- Combat-only buffs (seals): their icon goes when the fight ends.
	if not UnitAffectingCombat("player") then
		for group, name in pairs(missing) do
			if Entry(name) and Entry(name).combat then missing[group], missingSince[group] = nil, nil end
		end
	end
	if ns.db.remindIcon ~= false then
		for group, name in pairs(missing) do
			if dismissed[group] then
				-- right-clicked away: stays missing (no new reminder), just not shown
			elseif Enabled(name) then
				missingSince[group] = missingSince[group] or GetTime()
				local left = limit > 0 and (missingSince[group] + limit - GetTime()) or nil
				if not left or left > 0 then
					list[#list + 1] = { name = name, icon = Entry(name).icon }
					if left and (not soonest or left < soonest) then soonest = left end
				end
			else
				missing[group] = nil
			end
		end
	end
	if hideTimer then hideTimer:Cancel() hideTimer = nil end
	if soonest then
		hideTimer = C_Timer.NewTimer(soonest + 0.05, function()
			hideTimer = nil
			ns.SafeCall(Show)
		end)
	end
	table.sort(list, function(a, b) return a.name < b.name end)
	ns.Display.SetMissing(list)
end

-- name is gone and should be recast.
local function Remind(name, announce)
	if not Enabled(name) then return ns.Trace(name .. " is gone, but its reminder is turned off") end
	if GroupPresent(GroupOf(name)) then return ns.Trace(name .. " is gone, but an alternative to it is up") end
	if Entry(name).combat then
		-- Combat-only: an alert when it drops mid-fight, nothing else.
		if not (announce and UnitAffectingCombat("player")) then
			return ns.Trace(name .. " is gone, but it's only reminded when it drops during a fight")
		end
		if Spells.WasRecentlyCast(JUDGEMENT) then
			return ns.Trace(name .. " is gone: used up by Judgement, not reminding")
		end
		local now = GetTime()
		if ns.db.remindAnnounce ~= false and now - (announcedAt[name] or -100) >= ANNOUNCE_THROTTLE then
			announcedAt[name] = now
			ns.Display.Alert(name .. " is gone", Entry(name).icon)
		end
		-- ...and its icon until you recast it or the fight ends (see Show).
		missing[GroupOf(name)] = name
		missingSince[GroupOf(name)] = now
		return ns.Trace(name .. " dropped during a fight: alerting")
	end
	missing[GroupOf(name)] = name
	missingSince[GroupOf(name)] = GetTime()
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
	if info.enchant then
		if GetInventoryItemID("player", info.enchant) ~= info.item then
			return ns.Trace(name .. " went with the weapon you swapped out: not reminding")
		end
		-- Another enchant on that weapon now: a different poison/stone (either
		-- one counts from now on) - or the same one, whose name couldn't be read
		-- the first time (then the stand-in name is dropped).
		for other, o in pairs(present) do
			if o.enchant == info.enchant then
				if name == (SLOT_LABEL[info.enchant] or "Weapon") .. " enchant" then
					ns.db.selfBuffs[name] = nil
					return ns.Trace(name .. " is " .. other)
				end
				Link(other, name)
				return
			end
		end
	end
	if UnitIsDeadOrGhost("player") then
		diedWith[name] = true
		return
	end
	-- (Tracking is only ever switched off from its menu, and a weapon enchant
	-- from its icon, so that's on purpose even mid-fight.)
	if GetTime() - cancelledAt < CANCEL_WINDOW and (info.tracking or info.enchant or not UnitAffectingCombat("player")) then
		if not SelfBuffs.remindCancelled then
			return ns.Trace(name .. (info.tracking and " was turned off by you"
				or info.enchant and " was cancelled by you" or " was cancelled by you out of combat") .. ": not reminding")
		end
		ns.Trace(name .. " was cancelled by you, but /fprocs testcancel is on: reminding anyway")
	end
	Remind(name, true)
end

-- In combat: is a hidden buff still up, going by its IDs? true, false, or nil
-- when the game won't say. ids: every buff ID on you now, or nil if unknown.
-- A buff recast mid-fight can have several possible IDs; ones that are gone
-- are dropped, and it's up while any is left.
local function StillUp(info, ids)
	local set = info.instances
	if not set then
		if not info.instance then return nil end
		set = { [info.instance] = true }
	end
	if not next(set) then return nil end
	local any = false
	for id in pairs(set) do
		local exists
		if ids then
			exists = ids[id] and true or false
		else
			exists = API.AuraInstanceExists("player", id)
		end
		if exists == nil then return nil end
		if exists then any = true else set[id] = nil end
	end
	return any
end

-- source: what triggered this look, for debug output.
function SelfBuffs.Update(source)
	if not ns.db then return end
	updateSource = source
	local restricted = API.AurasRestricted()
	local now = {}
	local read = {} -- [name] = true for buffs readable right now
	API.ForEachAura("player", "HELPFUL", function(a)
		local ok, kind = IsCandidate(a)
		if ok then
			Learn(a, kind)
			read[a.name] = true
			local info = { instance = a.instance, expires = a.expires, icon = a.icon, spellId = a.spellId }
			-- Still listed a moment after its end time: it's gone, the list is stale.
			local left = TimeLeft(info)
			if not (left and left < -1) then now[a.name] = info end
		end
	end)
	-- Tracking: readable in combat too, so always taken as it is.
	ForEachTracking(function(name, icon)
		Learn({ name = name, icon = icon }, "tracking")
		now[name] = { icon = icon, tracking = true }
	end)
	-- Weapon enchants: readable in combat too.
	ForEachEnchant(function(inv, e)
		local name = EnchantName(inv, e.enchantID)
		local icon = e.enchantIconID
		if API.IsSecret(icon) or not icon or icon == 0 then icon = GetInventoryItemTexture("player", inv) end
		-- (A stand-in name is learned quietly: it's normally renamed a moment later.)
		Learn({ name = name, icon = icon, quiet = name == (SLOT_LABEL[inv] or "Weapon") .. " enchant" }, "enchant")
		local left = not API.IsSecret(e.timeLeft) and tonumber(e.timeLeft) or 0
		now[name] = { icon = icon, enchant = inv, item = GetInventoryItemID("player", inv),
			expires = left > 0 and GetTime() + left / 1000 or 0 }
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
		-- Buffs not in the readable list: gone if the game shows that buff even
		-- in combat; otherwise hidden, so still there unless their IDs say
		-- otherwise - and not at their end time. The game's update for a buff
		-- running out can come a moment before the end time we have for it
		-- (especially one estimated from a cast), hence the margin.
		for name, info in pairs(present) do
			if not now[name] then
				local left = TimeLeft(info)
				local there = not (info.tracking or info.enchant) and not (left ~= nil and left <= END_MARGIN)
				if there and API.SpellAuraHidden(info.spellId) == false then
					there = false
				elseif there then
					local up = StillUp(info, ids)
					if up ~= nil then
						there = up
					elseif ns.tracing and not info.unsure then
						info.unsure = true
						ns.Trace(name .. ": can't tell in combat if it's still up, so it counts until it runs out")
					end
				end
				if there then now[name] = info end
			end
		end
		-- A hidden buff you just cast (or recast): it's up for its full duration.
		-- IDs that appear right after the cast are watched: it's up while any of
		-- them is (another buff can appear at the same moment, like Flurry).
		local new = {}
		if ids and lastIDs then
			for id in pairs(ids) do
				if not lastIDs[id] then new[#new + 1] = { id = id, name = API.AuraNameByInstance("player", id) } end
			end
		end
		for name, e in pairs(ns.db.selfBuffs) do
			if not (e.tracking or e.enchant or read[name]) and Spells.WasRecentlyCast(name) then
				local info, t = now[name], GetTime()
				if not (info and info.recastAt and t - info.recastAt < 3) then
					local old = info
					info = {
						instances = {}, spellId = e.spellId, icon = e.icon, recastAt = t,
						expires = (e.duration or 0) > 0 and t + e.duration or 0,
					}
					-- Refreshed: the buff may keep its ID.
					if old and ids then
						for id in pairs(old.instances or { [old.instance or false] = true }) do
							if ids[id] then info.instances[id] = true end
						end
					end
					now[name] = info
					ns.Trace(("%s cast in combat: counted as up for %ss"):format(name, tostring(e.duration)))
				end
				for _, n in ipairs(new) do
					if not n.name or n.name == name then info.instances[n.id] = true end
				end
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
		if GroupPresent(group) then missing[group], missingSince[group] = nil, nil end
	end
	for group in pairs(dismissed) do
		if GroupPresent(group) then dismissed[group] = nil end
	end
	Show()
end

-- Right-clicking a reminder icon: hide it until the buff is back.
function SelfBuffs.Dismiss(name)
	local group = GroupOf(name)
	dismissed[group] = true
	ns.Trace(name .. " reminder dismissed until you recast it")
	Show()
end

-- After logging in: anything you usually have up that isn't.
local function CheckAtLogin()
	if UnitIsDeadOrGhost("player") then return end
	SelfBuffs.Update() -- the spellbook may not have been ready at the first look
	local groups = {}
	for name in pairs(ns.db.selfBuffs) do
		local g = GroupOf(name)
		-- Only your own spells: settings copied from another character can list theirs.
		local yours = Spells.active[name] or (Entry(name).tracking and trackingKnown[name]) or Entry(name).enchant
		if Enabled(name) and yours and not GroupPresent(g) and not groups[g] then
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
		local idCount = 0
		for _ in pairs(info.instances or {}) do idCount = idCount + 1 end
		up[#up + 1] = name .. ((info.instance or idCount == 1) and ""
				or idCount > 1 and (" (%d possible IDs)"):format(idCount) or " (no ID)")
			.. (left and (" %dm%02ds left"):format(math.floor(left / 60), math.floor(left % 60))
				or ((info.expires or 0) == 0 and " (no timer)")
				or (" (timer unreadable: ends %s, now %.0f)"):format(tostring(info.expires), GetTime()))
	end
	for _, name in pairs(missing) do gone[#gone + 1] = name end
	table.sort(up)
	table.sort(gone)
	local known = {}
	for name, e in pairs(ns.db.selfBuffs) do
		known[#known + 1] = name .. (e.combat and " (in combat)" or "") .. (e.on == false and " (off)" or "")
	end
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
ns.On("MINIMAP_UPDATE_TRACKING", function() SelfBuffs.Update("tracking change") end)
ns.On("WEAPON_ENCHANT_CHANGED", function() SelfBuffs.Update("weapon enchant change") end)
ns.On("WEAPON_SLOT_CHANGED", function() SelfBuffs.Update("weapon change") end)
ns.OnUnit("UNIT_INVENTORY_CHANGED", "player", function() SelfBuffs.Update("equipment change") end)

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
