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
-- Slash commands
---------------------------------------------------------------------------
local function Help()
	local db = ns.db
	ns.Print("commands:")
	print("  /fbags - toggle bags")
	print("  /fbags bank - toggle the bank window")
	print("  /fbags sort - sort bags")
	print("  /fbags lock - lock/unlock window positions")
	print("  /fbags reset - reset window positions")
	print("  /fbags cols <6-24> - bag slots per row (now " .. db.columns .. ")")
	print("  /fbags bankcols <6-24> - bank slots per row (now " .. db.bankColumns .. ")")
	print("  /fbags scale <0.5-2> - window scale (now " .. db.scale .. ")")
	print("  /fbags keyring - show/hide the keyring section")
	print("  /fbags glow - turn the new item glow on/off")
	print("  /fbags junk - sell grey items (at a vendor)")
	print("  /fbags counts - turn bag/bank counts in tooltips on/off")
	print("  /fbags background <default|rock|marble|dark> - window background (now " .. db.background .. ")")
	print("  /fbags sortmode <auto|blizzard|custom> - sorter to use (now " .. db.sortMode .. ")")
end

local function SetColumns(key, arg)
	local n = tonumber(arg)
	if n and n >= 6 and n <= 24 then
		ns.db[key] = math.floor(n)
		for _, w in ipairs(ns.windows) do w:RequestRefresh() end
	else
		ns.Print("columns must be between 6 and 24.")
	end
end

SLASH_FIREBAGS1 = "/fbags"
SLASH_FIREBAGS2 = "/firebags"
SlashCmdList.FIREBAGS = function(input)
	local cmd, arg = strtrim(input or ""):lower():match("^(%S*)%s*(.-)$")
	local db = ns.db

	if cmd == "" then
		ToggleAllBags()
	elseif cmd == "bank" then
		ns.ToggleBank()
	elseif cmd == "debugbank" then
		ns.DebugBank()
	elseif cmd == "sort" then
		ns.SortBags("inventory")
	elseif cmd == "lock" then
		db.locked = not db.locked
		ns.Print(db.locked and "windows locked." or "windows unlocked.")
	elseif cmd == "reset" then
		wipe(db.positions)
		for _, w in ipairs(ns.windows) do w:ApplyPosition() end
		ns.Print("positions reset.")
	elseif cmd == "cols" then
		SetColumns("columns", arg)
	elseif cmd == "bankcols" then
		SetColumns("bankColumns", arg)
	elseif cmd == "scale" then
		local n = tonumber(arg)
		if n and n >= 0.5 and n <= 2 then
			db.scale = n
			ns.ApplyWindowSettings()
		else
			ns.Print("scale must be between 0.5 and 2.")
		end
	elseif cmd == "keyring" then
		db.showKeyring = not db.showKeyring
		ns.inventory:RequestRefresh()
		ns.Print(db.showKeyring and "keyring shown." or "keyring hidden.")
	elseif cmd == "glow" then
		db.newItemGlow = not db.newItemGlow
		ns.inventory:RequestRefresh()
		ns.Print(db.newItemGlow and "new item glow on." or "new item glow off.")
	elseif cmd == "junk" then
		ns.Junk.Sell()
	elseif cmd == "counts" then
		db.tooltipCounts = not db.tooltipCounts
		ns.Print(db.tooltipCounts and "tooltip counts on." or "tooltip counts off.")
	elseif cmd == "background" then
		if ns.BACKGROUNDS[arg] or arg == "default" then
			db.background = arg
			for _, w in ipairs(ns.windows) do w:ApplyBackground() end
		else
			ns.Print("background must be default, rock, marble or dark.")
		end
	elseif cmd == "sortmode" then
		if arg == "auto" or arg == "blizzard" or arg == "custom" then
			db.sortMode = arg
			ns.Print("sort mode: " .. arg)
		else
			ns.Print("sort mode must be auto, blizzard or custom.")
		end
	else
		Help()
	end
end
