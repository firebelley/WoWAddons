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
