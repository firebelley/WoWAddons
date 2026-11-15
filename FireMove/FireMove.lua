-- FireMove: drag Blizzard's windows (character, spellbook, merchant, mail,
-- auction house...) by any empty spot. They stay where you put them, through
-- reloads. /firemove reset puts them all back.
--
-- Which windows: every one the game opens as a panel (UIPanelWindows, and any
-- shown with ShowUIPanel - including ones that load later). The game places
-- panels itself whenever one opens or closes; a moved one is put back where
-- you left it right after.
local DB -- FireMoveDB: [frame name] = { point, relativePoint, x, y }

local made, waiting = {}, {}

local function Locked(frame)
	return frame:IsProtected() and InCombatLockdown()
end

-- Put a moved window back where you left it.
local function Place(frame)
	local name = frame:GetName()
	local pos = DB and name and DB[name]
	if not pos or Locked(frame) then return end
	frame:ClearAllPoints()
	frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
end

local function PlaceShown()
	for frame in pairs(made) do
		if frame:IsShown() then Place(frame) end
	end
end

local function Make(frame)
	if made[frame] or not frame.GetName or not frame:GetName() then return end
	if frame.IsForbidden and frame:IsForbidden() then return end
	if Locked(frame) then
		waiting[frame] = true
		return
	end
	made[frame] = true
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:HookScript("OnDragStart", function(self)
		if not Locked(self) then self:StartMoving() end
	end)
	frame:HookScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		-- Ours to keep, not the game's layout file (it would fight the panel placement).
		self:SetUserPlaced(false)
		local point, _, relativePoint, x, y = self:GetPoint(1)
		if point then DB[self:GetName()] = { point, relativePoint, x, y } end
	end)
	frame:HookScript("OnShow", Place)
	if frame:IsShown() then Place(frame) end
end

local function MakeAll()
	if not UIPanelWindows then return end
	for name in pairs(UIPanelWindows) do
		local frame = _G[name]
		if type(frame) == "table" and frame.SetMovable then Make(frame) end
	end
end

-- The game just placed its panels: put the moved ones back.
if ShowUIPanel then
	hooksecurefunc("ShowUIPanel", function(frame)
		if frame then Make(frame) end
		PlaceShown()
	end)
end
if HideUIPanel then hooksecurefunc("HideUIPanel", PlaceShown) end
if UpdateUIPanelPositions then hooksecurefunc("UpdateUIPanelPositions", PlaceShown) end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function(_, event, addon)
	if event == "ADDON_LOADED" and addon == "FireMove" then
		FireMoveDB = FireMoveDB or {}
		DB = FireMoveDB
	elseif event == "PLAYER_REGEN_ENABLED" then
		-- Ones that couldn't be set up during combat.
		for frame in pairs(waiting) do
			waiting[frame] = nil
			Make(frame)
		end
		PlaceShown()
		return
	end
	-- Windows that load later (auction house, trainers...) register as they load.
	if DB then MakeAll() end
end)

SLASH_FIREMOVE1 = "/firemove"
SlashCmdList.FIREMOVE = function(msg)
	if msg and msg:lower():match("reset") then
		wipe(DB)
		if UpdateUIPanelPositions then UpdateUIPanelPositions() end
		print("|cffff8030FireMove|r: windows go back to their usual places as they open (a /reload puts back any open now).")
	else
		print("|cffff8030FireMove|r: drag any Blizzard window by an empty spot. /firemove reset puts them all back.")
	end
end
