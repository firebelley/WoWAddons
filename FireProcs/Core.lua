-- Slash commands.
local _, ns = ...

-- Finds a key in tbl ignoring case, so "/fprocs unmute clearcasting" works.
local function FindName(tbl, text)
	local lower = text:lower()
	for name in pairs(tbl) do
		if name:lower() == lower then return name end
	end
end

local function Help()
	ns.Print("commands:")
	print("  /fprocs test - show a sample announcement")
	print("  /fprocs move - unlock/lock the announcement position")
	print("  /fprocs reset - put the announcements back in the default spot")
	print("  /fprocs sound - turn the sound on/off (now " .. (ns.db.sound and "on" or "off") .. ")")
	print("  /fprocs mute - stop announcing the last proc shown")
	print("  /fprocs mute <name> - stop announcing a proc by name")
	print("  /fprocs unmute <name> - announce it again")
	print("  /fprocs muted - list muted procs")
	print("  /fprocs debug - explain in chat why things are or aren't announced")
	print("  /fprocs status - what the game lets FireProcs see right now")
end

local function DebugStatus()
	local c = ns.Casts
	ns.Trace(("spells triggered without you casting them so far: %d"):format(c.seen))
	local d, p = ns.Drain, ns.Spells.drainPassive
	ns.Trace(("heals on you seen: %d (%d with hidden values); drain passive: %s"):format(
		d.heals, d.secret, p and (p.name .. " (id " .. p.id .. ")") or "none found"))
	ns.Trace(("spellbook: %d castable spells known, %d passives"):format(ns.Spells.count, #ns.Spells.passives))
	ns.Trace("your buffs right now:")
	ns.Auras.DescribeCurrent()
end

SLASH_FIREPROCS1 = "/fprocs"
SLASH_FIREPROCS2 = "/fireprocs"
SlashCmdList.FIREPROCS = function(input)
	local cmd, arg = strtrim(input or ""):match("^(%S*)%s*(.-)$")
	cmd = (cmd or ""):lower()
	local db = ns.db

	if cmd == "test" then
		ns.Display.Test()
	elseif cmd == "move" then
		local moving = ns.Display.ToggleMove()
		if moving then ns.Display.Test() end
		ns.Print(moving and "drag the blue box, then type /fprocs move again." or "position saved.")
	elseif cmd == "reset" then
		ns.Display.ResetPosition()
		ns.Print("position reset.")
	elseif cmd == "sound" then
		db.sound = not db.sound
		ns.Print(db.sound and "sound on." or "sound off.")
	elseif cmd == "mute" then
		local name = arg ~= "" and (FindName(db.seen, arg) or arg) or ns.lastProc
		if not name then
			ns.Print("nothing has been announced yet.")
			return
		end
		db.muted[name] = true
		ns.Glow.Set(name, false)
		ns.Auras.Update()
		ns.Print(("muted %s. Type /fprocs unmute %s to undo."):format(name, name))
	elseif cmd == "unmute" then
		local name = arg ~= "" and FindName(db.muted, arg)
		if not name then
			ns.Print(arg == "" and "unmute what? Type /fprocs muted for the list." or ("%s isn't muted."):format(arg))
			return
		end
		db.muted[name] = nil
		ns.ResetProcHistory(name)
		ns.Print(("%s will be announced again."):format(name))
	elseif cmd == "status" then
		-- /fprocs status [spell]: what the game reports right now, e.g. whether
		-- a proc has made a spell free or instant.
		ns.Print(("status: in combat %s, buffs hidden %s"):format(
			tostring(UnitAffectingCombat("player") and true or false), tostring(ns.API.AurasRestricted())))
		local names = arg ~= "" and { arg } or { "Arcane Missiles", "Shadow Bolt", "Frostbolt", "Fireball", "Healing Touch", "Lightning Bolt" }
		local any = false
		for _, name in ipairs(names) do
			local id = ns.Spells.active[FindName(ns.Spells.active, name) or name]
			if id then
				any = true
				print("  " .. ns.Changes.Describe(id))
			end
		end
		if not any then print("  (none of those spells are in your spellbook - try /fprocs status <spell name>)") end
	elseif cmd == "debug" then
		ns.tracing = not ns.tracing
		if ns.tracing then
			ns.Casts.ResetTrace()
			ns.Drain.ResetTrace()
			ns.Print("debug on. Each new buff and triggered spell is explained once. /fprocs debug again to stop.")
			DebugStatus()
		else
			ns.Print("debug off.")
		end
	elseif cmd == "muted" then
		local names = {}
		for name, how in pairs(db.muted) do
			names[#names + 1] = how == "auto" and (name .. " (too frequent)") or name
		end
		table.sort(names)
		ns.Print(#names == 0 and "nothing is muted." or ("muted: " .. table.concat(names, ", ")))
	else
		Help()
	end
end
