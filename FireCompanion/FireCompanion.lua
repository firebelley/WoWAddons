-- FireCompanion: summons a companion pet when you log in (and after you die),
-- unless one is already out.
--
-- Which one: the last companion you had out (default), a random favorite, a
-- random one, or one you pick in Options > AddOns > FireCompanion.
-- If you dismiss your companion yourself, it stays dismissed until next login.
local ADDON, ns = ...

local PJ = C_PetJournal
local LOGIN_DELAY = 3    -- the game puts your last pet back on its own; give it time first
local RETRY_EVERY = 2
local MAX_TRIES = 8      -- summon attempts (not counting time spent busy)
local SUMMON_SETTLE = 3  -- after a summon, wait this long before trying again

local DEFAULTS = {
	enabled = true,    -- summon at login
	afterDeath = true, -- and after you die
	mode = "last",     -- "last" | "favorite" | "random" | "pet"
	-- petID: the picked companion (mode "pet")
	-- last:  the last companion you had out
}

local db

function ns.Print(msg)
	print("|cffff7f3fFireCompanion|r: " .. msg)
end

---------------------------------------------------------------------------
-- Pet journal
---------------------------------------------------------------------------
local function Summoned()
	if not (PJ and PJ.GetSummonedPetGUID) then return nil end
	local ok, id = pcall(PJ.GetSummonedPetGUID)
	return ok and id or nil
end

-- { id, name, species, icon, favorite, summonable } or nil.
function ns.PetInfo(petID)
	if not (petID and PJ and PJ.GetPetInfoByPetID) then return nil end
	local ok, speciesID, customName, _, _, _, _, favorite, name, icon = pcall(PJ.GetPetInfoByPetID, petID)
	if not ok or not speciesID then return nil end
	local summonable = true
	if PJ.PetIsSummonable then
		local ok2, s = pcall(PJ.PetIsSummonable, petID)
		summonable = not ok2 or s and true or false
	end
	return {
		id = petID,
		name = customName or name or "?",
		species = customName and name or nil,
		icon = icon,
		favorite = favorite and true or false,
		summonable = summonable,
	}
end

-- Every companion you own, sorted by name.
function ns.OwnedPets()
	local list = {}
	local ids
	if PJ and PJ.GetOwnedPetIDs then
		local ok, result = pcall(PJ.GetOwnedPetIDs)
		ids = ok and result or nil
	end
	if not ids and PJ and PJ.GetNumPets and PJ.GetPetInfoByIndex then
		-- Older journals: the index list (follows the journal's filters).
		ids = {}
		for i = 1, (PJ.GetNumPets()) or 0 do
			local petID, _, owned = PJ.GetPetInfoByIndex(i)
			if petID and owned then ids[#ids + 1] = petID end
		end
	end
	for _, id in ipairs(ids or {}) do
		local info = ns.PetInfo(id)
		if info then list[#list + 1] = info end
	end
	table.sort(list, function(a, b)
		if a.name ~= b.name then return a.name < b.name end
		return tostring(a.id) < tostring(b.id)
	end)
	return list
end

local function Usable(petID)
	local info = ns.PetInfo(petID)
	return info and info.summonable and info or nil
end

local function RandomFrom(pets, favoritesOnly)
	local pool = {}
	for _, p in ipairs(pets) do
		if p.summonable and (p.favorite or not favoritesOnly) then pool[#pool + 1] = p end
	end
	if #pool > 0 then return pool[math.random(#pool)] end
end

-- The companion to summon, per the settings. Falls back sensibly when the
-- choice isn't available (never had one out yet, pet caged, wrong faction...).
local function Choose()
	if db.mode == "pet" and Usable(db.petID) then return db.petID end
	if (db.mode == "last" or db.mode == "pet") and Usable(db.last) then return db.last end
	local pets = ns.OwnedPets()
	local p = (db.mode ~= "random" and RandomFrom(pets, true)) or RandomFrom(pets, false)
	return p and p.id
end

-- Shown in the options: what "last" currently means.
function ns.LastPet()
	return db and ns.PetInfo(db.last)
end

---------------------------------------------------------------------------
-- Summoning
---------------------------------------------------------------------------
local lastSummonAt = -100

-- Times the game wouldn't let a companion out (or it'd look odd).
local function Busy()
	if InCombatLockdown() or UnitIsDeadOrGhost("player") then return "busy" end
	if UnitOnTaxi and UnitOnTaxi("player") then return "busy" end
	if UnitInVehicle and UnitInVehicle("player") then return "busy" end
	if IsStealthed and IsStealthed() then return "busy" end
	if UnitCastingInfo("player") or UnitChannelInfo("player") then return "busy" end
	if C_PetBattles and C_PetBattles.IsInBattle and C_PetBattles.IsInBattle() then return "busy" end
end

-- Summon petID unless it's already out (summoning the pet that's out dismisses it).
function ns.Summon(petID)
	if not (petID and PJ and PJ.SummonPetByGUID) then return false end
	if Summoned() == petID then return true end
	if PJ.IsCurrentlySummoned then
		local ok, out = pcall(PJ.IsCurrentlySummoned, petID)
		if ok and out then return true end
	end
	lastSummonAt = GetTime()
	local ok, err = pcall(PJ.SummonPetByGUID, petID)
	if not ok then ns.Print("couldn't summon: " .. tostring(err)) end
	return ok
end

local pending, tries, ticker = false, 0, nil

local function Stop()
	pending = false
	if ticker then ticker:Cancel(); ticker = nil end
end

local function Try()
	if not pending then return end
	if Summoned() then return Stop() end
	if Busy() or GetTime() - lastSummonAt < SUMMON_SETTLE then return end
	tries = tries + 1
	if tries > MAX_TRIES then return Stop() end
	local petID = Choose()
	if petID then ns.Summon(petID) end
end

local function Want(delay)
	pending, tries = true, 0
	if not ticker then ticker = C_Timer.NewTicker(RETRY_EVERY, Try) end
	C_Timer.After(delay or 0, Try)
end

---------------------------------------------------------------------------
-- Watching your companion: remember the last one, and notice when you
-- dismiss it yourself (so we don't keep putting it back).
---------------------------------------------------------------------------
local current         -- the companion out right now
local userDismissed = false
local loadingAt, diedAt, died = 0, -100, false

local function OnCompanionUpdate()
	local now = Summoned()
	if now == current then return end
	local previous = current
	current = now
	if now then
		db.last = now
		userDismissed = false
		Stop()
		if ns.OnPetChanged then ns.OnPetChanged() end
	elseif previous then
		-- Gone. If you're alive and nothing else explains it, you dismissed it.
		C_Timer.After(1.5, function()
			if current or UnitIsDeadOrGhost("player") or (UnitOnTaxi and UnitOnTaxi("player")) then return end
			if GetTime() - loadingAt < 5 or GetTime() - diedAt < 5 then return end
			userDismissed = true
		end)
		if ns.OnPetChanged then ns.OnPetChanged() end
	end
end

function ns.Status()
	local out = ns.PetInfo(Summoned())
	local last = ns.LastPet()
	local pick = db.mode == "pet" and ns.PetInfo(db.petID)
	ns.Print(("out: %s, mode: %s%s, last: %s, owned: %d"):format(
		out and out.name or "none", db.mode, pick and (" (" .. pick.name .. ")") or "",
		last and last.name or "none", #ns.OwnedPets()))
	print(("  login: %s, after death: %s, you dismissed it: %s, busy: %s, api: %s"):format(
		tostring(db.enabled), tostring(db.afterDeath), tostring(userDismissed), tostring(Busy() or "no"),
		(PJ and PJ.SummonPetByGUID) and "ok" or "missing"))
end

---------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(self, event, arg1, arg2)
	if event == "ADDON_LOADED" then
		if arg1 ~= ADDON then return end
		FireCompanionCharDB = FireCompanionCharDB or {}
		db = FireCompanionCharDB
		for k, v in pairs(DEFAULTS) do
			if db[k] == nil then db[k] = v end
		end
		ns.db = db
	elseif event == "PLAYER_LOGIN" then
		for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "COMPANION_UPDATE", "PET_JOURNAL_LIST_UPDATE",
			"PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST", "PLAYER_REGEN_ENABLED",
			"ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }) do
			pcall(self.RegisterEvent, self, e)
		end
	elseif event == "PLAYER_ENTERING_WORLD" then
		loadingAt = GetTime()
		local isLogin, isReload = arg1, arg2
		current = Summoned()
		if (isLogin or isReload) and db.enabled and not current then Want(LOGIN_DELAY) end
	elseif event == "COMPANION_UPDATE" then
		if arg1 == nil or arg1 == "CRITTER" then OnCompanionUpdate() end
	elseif event == "PLAYER_DEAD" then
		died, diedAt = true, GetTime()
	elseif event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
		-- PLAYER_ALIVE also fires on releasing (still a ghost) and sometimes at login.
		if not died or UnitIsDeadOrGhost("player") then return end
		died, diedAt = false, GetTime() -- the pet vanishing around now isn't a dismissal
		if db.afterDeath and not userDismissed and not Summoned() then Want(1) end
	elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
		if arg1 == ADDON then
			ns.Print("the game blocked " .. tostring(arg2) .. " - it may only allow summoning from a click here.")
			Stop()
		end
	else -- the journal finished loading, or combat ended
		Try()
	end
end)

SLASH_FIRECOMPANION1 = "/fcomp"
SLASH_FIRECOMPANION2 = "/firecompanion"
SlashCmdList.FIRECOMPANION = function(input)
	local cmd = strtrim(input or ""):lower()
	if cmd == "summon" then
		local petID = Choose()
		if petID then ns.Summon(petID) else ns.Print("you don't have a companion that can be summoned.") end
	elseif cmd == "status" or cmd == "debug" then
		ns.Status()
	elseif ns.OpenOptions then
		ns.OpenOptions()
	else
		ns.Print("/fcomp summon, /fcomp status")
	end
end
