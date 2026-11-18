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
local home = {} -- [frame] = its points before any moving, for a reset
-- Never moved: the Escape menu (too easy to drag by accident).
local SKIP = { GameMenuFrame = true }

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

-- A child laid over the whole window (like the group finder's tabs) takes the
-- clicks, so it drags the window too.
local function Covers(child, frame)
	if not child:IsObjectType("Frame") or child:IsObjectType("Button") or child:IsObjectType("ScrollFrame") then return false end
	if not child:IsMouseEnabled() then return false end
	local n = child:GetNumPoints()
	if n == 2 then
		local p1, r1, _, x1, y1 = child:GetPoint(1)
		local p2, r2, _, x2, y2 = child:GetPoint(2)
		if r1 == frame and r2 == frame and x1 == 0 and y1 == 0 and x2 == 0 and y2 == 0
			and ((p1 == "TOPLEFT" and p2 == "BOTTOMRIGHT") or (p1 == "BOTTOMRIGHT" and p2 == "TOPLEFT")) then
			return true
		end
	end
	local w, h, fw, fh = child:GetWidth(), child:GetHeight(), frame:GetWidth(), frame:GetHeight()
	return w > 0 and h > 0 and math.abs(w - fw) < 2 and math.abs(h - fh) < 2
end

local function Grip(handle, frame)
	handle:RegisterForDrag("LeftButton")
	handle:HookScript("OnDragStart", function()
		if not Locked(frame) then frame:StartMoving() end
	end)
	handle:HookScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		-- Ours to keep, not the game's layout file (it would fight the panel placement).
		frame:SetUserPlaced(false)
		local point, _, relativePoint, x, y = frame:GetPoint(1)
		if point then DB[frame:GetName()] = { point, relativePoint, x, y } end
	end)
	for _, child in ipairs({ handle:GetChildren() }) do
		if not (child.IsForbidden and child:IsForbidden()) and Covers(child, handle) then Grip(child, frame) end
	end
end

local function Make(frame)
	if made[frame] or not frame.GetName or not frame:GetName() or SKIP[frame:GetName()] then return end
	if frame.IsForbidden and frame:IsForbidden() then return end
	if Locked(frame) then
		waiting[frame] = true
		return
	end
	made[frame] = true
	local points = {}
	for i = 1, frame:GetNumPoints() do points[i] = { frame:GetPoint(i) } end
	home[frame] = points
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	Grip(frame, frame)
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
		for name in pairs(SKIP) do DB[name] = nil end
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

-- Every window back where the game puts it, open ones too.
local function Reset()
	if not DB then return end
	wipe(DB)
	for frame, points in pairs(home) do
		if #points > 0 and not Locked(frame) then
			frame:ClearAllPoints()
			for _, p in ipairs(points) do frame:SetPoint(unpack(p)) end
		end
	end
	if UpdateUIPanelPositions then UpdateUIPanelPositions() end
	print("|cffff8030FireMove|r: windows are back in their usual places.")
end

-- Options > AddOns > FireMove.
local function BuildOptions()
	if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then return end
	local panel = CreateFrame("Frame")
	panel:Hide()
	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("FireMove")
	local about = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	about:SetPoint("TOPLEFT", 16, -40)
	about:SetPoint("RIGHT", -16, 0)
	about:SetJustifyH("LEFT")
	about:SetText("Drag any Blizzard window by an empty spot. It stays where you put it.")
	local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	reset:SetSize(180, 22)
	reset:SetPoint("TOPLEFT", 20, -70)
	reset:SetText("Reset window positions")
	reset:SetScript("OnClick", Reset)
	local category = Settings.RegisterCanvasLayoutCategory(panel, "FireMove")
	Settings.RegisterAddOnCategory(category)
end

local options = CreateFrame("Frame")
options:RegisterEvent("PLAYER_LOGIN")
options:SetScript("OnEvent", BuildOptions)

SLASH_FIREMOVE1 = "/firemove"
SlashCmdList.FIREMOVE = function(msg)
	if msg and msg:lower():match("reset") then
		Reset()
	else
		print("|cffff8030FireMove|r: drag any Blizzard window by an empty spot. /firemove reset puts them all back.")
	end
end
