-- One-off procs that leave no buff on you: spells that go off by themselves,
-- showing up as spells "you" cast that you never started casting (see the
-- UNIT_SPELLCAST_SUCCEEDED handler in Spells.lua).
--
-- What this client hides from addons, so FireProcs can't see:
--  * the combat log event (registering it is blocked outright), and
--  * the combat log chat tab's text, which is stored as opaque |K...|k codes.
-- Effects that only ever appear in the combat log (e.g. Touch of the Grave's
-- drain) are therefore out of reach.
local _, ns = ...
local API, Spells = ns.API, ns.Spells

local Casts = { seen = 0 }
ns.Casts = Casts

-- Debug lines are printed once per spell, or the chat would scroll away.
local traced = {}
local function Trace(name, spellID, msg)
	if not ns.tracing or traced[name] then return end
	traced[name] = true
	ns.Trace(("triggered spell %s (id %s): %s"):format(name, tostring(spellID), msg))
end
function Casts.ResetTrace() wipe(traced) end

-- Called from Spells.lua for each spell that went off without you casting it.
function Casts.Triggered(spellID)
	Casts.seen = Casts.seen + 1
	local name, icon = API.SpellInfo(spellID)
	if not name or name == "" then return end
	if Spells.count == 0 then return Trace(name, spellID, "skipped, spellbook not loaded yet") end

	-- Auto Shot, wand Shoot and effects of your own spells ("Charge Stun"...).
	local own = Spells.OwnSpellFor(name)
	if own then return Trace(name, spellID, "skipped, belongs to your spell " .. Spells.Describe(own)) end
	if Spells.WasRecentlyCast(name, spellID) then return Trace(name, spellID, "skipped, you just cast or used it") end

	Spells.RememberIcon(name, icon)
	if ns.Proc(name, icon or Spells.Icon(spellID, name), "event", "detectTriggered") then
		Trace(name, spellID, "announced")
	end
end
