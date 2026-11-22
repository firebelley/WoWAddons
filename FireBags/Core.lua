-- Replaces Blizzard's bag and bank windows, and handles slash commands.
local ADDON_NAME, ns = ...

local hiddenParent = CreateFrame("Frame")
hiddenParent:Hide()

---------------------------------------------------------------------------
-- Bags
--
-- Blizzard's bag frames keep running (every "open bags" path still goes through
-- them: the B key, bag bar, vendors, mail, bank...), but they live under a hidden
-- parent so they never draw. After any open/close call we mirror their state:
-- if Blizzard thinks a carried bag is open, our window is shown.
---------------------------------------------------------------------------
local function BlizzardBagFrames()
	local list = {}
	for i = 1, NUM_CONTAINER_FRAMES or 13 do
		local f = _G["ContainerFrame" .. i]
		if f then table.insert(list, f) end
	end
	return list
end

local function HideBlizzardBags()
	for _, f in ipairs(BlizzardBagFrames()) do
		f:SetParent(hiddenParent)
	end
	if ContainerFrameCombinedBags then
		ContainerFrameCombinedBags:SetParent(hiddenParent)
	end
end

-- "Shown" here is the frame's own flag; they're never visible under the hidden parent.
local function IsBlizzardInventoryOpen()
	if ContainerFrameCombinedBags and ContainerFrameCombinedBags:IsShown() then
		return true
	end
	for _, f in ipairs(BlizzardBagFrames()) do
		if f:IsShown() and ns.IsInventoryBag(f:GetID()) then
			return true
		end
	end
	return false
end

function ns.CloseBlizzardBags()
	if ns.blizzardBank or not IsBlizzardInventoryOpen() then return end
	CloseAllBags()
	-- CloseAllBags only closes bags it opened for a given frame on some
	-- clients; make sure carried bags are closed too.
	if IsBlizzardInventoryOpen() and CloseBag then
		for _, f in ipairs(BlizzardBagFrames()) do
			local id = f:GetID()
			if f:IsShown() and ns.IsInventoryBag(id) then CloseBag(id) end
		end
	end
end

-- Our window open without Blizzard's (opened over the game menu or settings,
-- below).
local detached = false

local syncPending = false
local function SyncWithBlizzard()
	syncPending = false
	local open = IsBlizzardInventoryOpen()
	if open then detached = false end
	if open and not ns.inventory:IsShown() then
		ns.inventory:Show()
	elseif not open and ns.inventory:IsShown() and not detached then
		ns.inventory:Hide()
	end
end

-- Several open/close functions can call each other in one keypress; wait a frame
-- and look at the end result.
local function RequestSync()
	if syncPending then return end
	syncPending = true
	C_Timer.After(0, SyncWithBlizzard)
end

-- While the game menu or settings are up, Blizzard won't open bags (no other
-- window over a "center" panel), so the bag key did nothing. Ours open
-- anyway, on their own; once the menu's gone, the next toggle closes them.
local function BlockedByPanel()
	if not ContainerFrame_AllowedToOpenBags or ContainerFrame_AllowedToOpenBags() then return false end
	-- (Not where the game turns bags off altogether.)
	local rule = Enum.GameRule and Enum.GameRule.BagsUIDisabled
	if rule and C_GameRules and C_GameRules.IsGameRuleActive and C_GameRules.IsGameRuleActive(rule) then
		return false
	end
	return true
end

local function OnToggle()
	if ns.blizzardBank then return end
	if BlockedByPanel() then
		if ns.inventory:IsShown() then
			ns.inventory:Hide()
		else
			detached = true
			ns.inventory:Show()
		end
	elseif detached then
		-- Blizzard's bags were closed, so this toggle opened them: it's
		-- meant to close ours (which closes Blizzard's again).
		ns.inventory:Hide()
	end
end

local function HookBlizzardBagFunctions()
	for _, name in ipairs({
		"OpenBag", "CloseBag", "ToggleBag",
		"OpenBackpack", "CloseBackpack", "ToggleBackpack",
		"OpenAllBags", "CloseAllBags", "ToggleAllBags",
	}) do
		if type(_G[name]) == "function" then
			hooksecurefunc(name, RequestSync)
		end
	end
	for _, name in ipairs({ "ToggleAllBags", "ToggleBackpack" }) do
		if type(_G[name]) == "function" then
			hooksecurefunc(name, function() ns.SafeCall(OnToggle) end)
		end
	end
	ns.inventory:HookScript("OnHide", function() detached = false end)
end

---------------------------------------------------------------------------
-- Bank
--
-- Blizzard's bank window still opens at every banker visit (the game's own
-- code does it), but under a hidden parent it never shows; Bank.lua listens
-- for the visits itself.
--
-- Only Blizzard's window can buy bank slots, and only untouched by us: it
-- opens the bags as it opens, and once we've opened or closed bags ourselves
-- that taints it. So for that, after asking (Bank.lua), the next session
-- (you type /reload) leaves Blizzard's bags and bank alone until a bank
-- visit ends; then we take over again.
---------------------------------------------------------------------------
local function HideBlizzardBank()
	if not BankFrame then return end
	BankFrame:UnregisterAllEvents()
	BankFrame:SetParent(hiddenParent)
end

local hooked
local function TakeOver()
	ns.blizzardBank = false
	HideBlizzardBags()
	if not hooked then
		hooked = true
		HookBlizzardBagFunctions()
	end
	HideBlizzardBank()
	RequestSync()
end
ns.TakeOver = TakeOver

ns.On("PLAYER_LOGIN", function()
	if ns.db and ns.db.blizzardOnce then
		ns.db.blizzardOnce = nil
		ns.blizzardBank = true
		ns.Print("Blizzard's bags and bank until you close the bank.")
	else
		TakeOver()
	end
end)

-- When the game blocks one of our calls, say which (its popup doesn't).
local function Blocked(addon, func)
	if addon == ADDON_NAME then ns.Print("blocked: " .. tostring(func)) end
end
ns.On("ADDON_ACTION_FORBIDDEN", Blocked)
ns.On("ADDON_ACTION_BLOCKED", Blocked)

---------------------------------------------------------------------------
-- Trading: open the bags with the trade window, like vendors and the bank do.
-- Passing TradeFrame as the opener means closing the trade only closes the
-- bags if the trade opened them (not if they were already open).
---------------------------------------------------------------------------
ns.On("TRADE_SHOW", function()
	if not ns.blizzardBank then OpenAllBags(TradeFrame) end
end)
ns.On("TRADE_CLOSED", function()
	if not ns.blizzardBank then CloseAllBags(TradeFrame) end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local function Help()
	ns.Print("commands (settings are in Options > AddOns > FireBags):")
	print("  /fbags - toggle bags")
	print("  /fbags bank - toggle the bank window")
	print("  /fbags sort - sort bags")
	print("  /fbags junk - sell grey items (at a vendor)")
	print("  /fbags reset - reset window positions")
	print("  /fbags options - open the settings")
end

SLASH_FIREBAGS1 = "/fbags"
SLASH_FIREBAGS2 = "/firebags"
SlashCmdList.FIREBAGS = function(input)
	local cmd = strtrim(input or ""):lower():match("^(%S*)")

	if cmd == "" then
		if not ns.blizzardBank then ToggleAllBags() end
	elseif cmd == "bank" then
		ns.ToggleBank()
	elseif cmd == "debugbank" then
		ns.DebugBank()
	elseif cmd == "sort" then
		ns.SortBags("inventory")
	elseif cmd == "reset" then
		wipe(ns.db.positions)
		for _, w in ipairs(ns.windows) do w:ApplyPosition() end
		ns.Print("positions reset.")
	elseif cmd == "junk" then
		ns.Junk.Sell()
	elseif cmd == "options" or cmd == "config" or cmd == "settings" then
		ns.Options.Open()
	else
		Help()
	end
end
