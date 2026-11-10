-- Replaces Blizzard's bag and bank windows, and handles slash commands.
local _, ns = ...

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
	if not IsBlizzardInventoryOpen() then return end
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

local syncPending = false
local function SyncWithBlizzard()
	syncPending = false
	local open = IsBlizzardInventoryOpen()
	if open and not ns.inventory:IsShown() then
		ns.inventory:Show()
	elseif not open and ns.inventory:IsShown() then
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
end

---------------------------------------------------------------------------
-- Bank
--
-- Blizzard's bank window is stopped from reacting to banker visits; Bank.lua
-- listens for those itself.
---------------------------------------------------------------------------
local function HideBlizzardBank()
	if not BankFrame then return end
	BankFrame:UnregisterAllEvents()
	BankFrame:SetParent(hiddenParent)
end

ns.On("PLAYER_LOGIN", function()
	HideBlizzardBags()
	HookBlizzardBagFunctions()
	HideBlizzardBank()
end)

---------------------------------------------------------------------------
-- Trading: open the bags with the trade window, like vendors and the bank do.
-- Passing TradeFrame as the opener means closing the trade only closes the
-- bags if the trade opened them (not if they were already open).
---------------------------------------------------------------------------
ns.On("TRADE_SHOW", function()
	OpenAllBags(TradeFrame)
end)
ns.On("TRADE_CLOSED", function()
	CloseAllBags(TradeFrame)
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
		ToggleAllBags()
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
