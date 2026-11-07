-- Abilities that light up: Overpower after a dodge, Revenge after a block,
-- Riposte after a parry, Execute below 20%...
--
-- No list needed: in a fight, any spell of yours that goes from "can't be used"
-- to usable *without* you changing anything (stance, target, combo points,
-- gear, buffs) became usable because of something that happened - a proc.
local _, ns = ...
local API, Spells, Glow = ns.API, ns.Spells, ns.Glow

local Reactive = {}
ns.Reactive = Reactive

local QUIET_TIME = 0.5   -- seconds after a "you changed something" event to ignore
local CHECK_DELAY = 0.05 -- let all of a frame's events land before checking
local TICK = 0.25        -- backup check rate while in combat

-- Per spell: 0 = conditions not met, 1 = met but not enough rage/mana/energy, 2 = usable
local states = {}
local pending = {}   -- conditions just became met; announce once actually usable
local announced = {}
local quietUntil = 0
local checkQueued = false
local ticker

function Reactive.Quiet()
	quietUntil = GetTime() + QUIET_TIME
end

local function OnCooldown(spellID)
	local start, duration = API.SpellCooldown(spellID)
	if not start or start == 0 or not duration or duration <= 1.5 then return false end -- 1.5 = global cooldown
	return start + duration - GetTime() > 0.1
end

local function InFight()
	return UnitAffectingCombat("player") and UnitExists("target")
		and UnitCanAttack("player", "target") and not UnitIsDead("target")
end

local function Check()
	checkQueued = false
	local fight = InFight()
	local quiet = GetTime() < quietUntil
	for _, s in ipairs(Spells.reactive) do
		local usable, noPower = API.IsUsable(s.id)
		local state = usable and 2 or (noPower and 1 or 0)
		local prev = states[s.name]
		states[s.name] = state

		if fight and state > 0 then
			if prev == 0 and not quiet then pending[s.name] = true end
			if pending[s.name] and state == 2 and not OnCooldown(s.id) then
				pending[s.name] = nil
				if ns.Proc(s.name, s.icon, "ready", "detectAbilities") then
					announced[s.name] = true
					Glow.Set(s.name, ns.db.glowButtons ~= false)
				end
			end
		else
			pending[s.name] = nil
			if announced[s.name] then
				announced[s.name] = nil
				Glow.Set(s.name, false)
			end
		end
	end
end

function Reactive.RequestCheck()
	if checkQueued then return end
	checkQueued = true
	C_Timer.After(CHECK_DELAY, function() ns.SafeCall(Check) end)
end

local function QuietAndCheck()
	Reactive.Quiet()
	Reactive.RequestCheck()
end

-- Things that change what you can use without anything having "procced".
for _, event in ipairs({
	"PLAYER_TARGET_CHANGED", "UPDATE_SHAPESHIFT_FORM", "PLAYER_EQUIPMENT_CHANGED",
	"SPELLS_CHANGED", "PLAYER_ENTERING_WORLD", "PLAYER_DEAD",
	"PLAYER_ALIVE", "PLAYER_UNGHOST", "ZONE_CHANGED_INDOORS", "PLAYER_COMBO_POINTS",
}) do
	ns.On(event, QuietAndCheck)
end
ns.OnUnit("UNIT_POWER_UPDATE", "player", function(_, powerType)
	if powerType == "COMBO_POINTS" then Reactive.Quiet() end
end)

ns.On("SPELL_UPDATE_USABLE", Reactive.RequestCheck)
ns.On("ACTIONBAR_UPDATE_USABLE", Reactive.RequestCheck)
ns.On("SPELL_UPDATE_COOLDOWN", Reactive.RequestCheck)
ns.OnUnit("UNIT_HEALTH", "target", Reactive.RequestCheck)

ns.On("PLAYER_REGEN_DISABLED", function()
	QuietAndCheck()
	if not ticker then ticker = C_Timer.NewTicker(TICK, Reactive.RequestCheck) end
end)
ns.On("PLAYER_REGEN_ENABLED", function()
	if ticker then ticker:Cancel() end
	ticker = nil
	QuietAndCheck()
end)

-- Where the client flags procs itself, take its word for it.
-- These are never hidden from addons, even in combat, so they're the most
-- reliable signal there is - when the client uses them for a proc.
ns.On("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", function(spellID)
	local name, icon = API.SpellInfo(spellID)
	ns.Trace(("Blizzard proc glow on %s (id %s)"):format(tostring(name), tostring(spellID)))
	ns.Proc(name, icon, "ready", "detectAbilities")
end)
ns.On("SPELL_ACTIVATION_OVERLAY_SHOW", function(spellID)
	local name, icon = API.SpellInfo(spellID)
	ns.Trace(("Blizzard proc art for %s (id %s)"):format(tostring(name), tostring(spellID)))
	ns.Proc(name, icon, "aura", "detectBuffs")
end)
