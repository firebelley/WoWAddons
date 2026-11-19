-- Loot rolls (need or greed) in Edit Mode: "Loot Rolls" shows where they
-- come up; drag it to move them. Kept with the Edit Mode layout, saved like
-- the game's frames (FireMove.lua). They stack up from there, or down when
-- it's in the top half of the screen.
--
-- Only the roll windows move, after the game places them: its own frame for
-- them stays in the game's stack at the bottom (alerts line up on that),
-- since setting anything on it from here would taint the stack.
local _, ns = ...

local Loot = {}
ns.Loot = Loot

local editing, selected, dialog

local function Store()
	local all = FireMoveLayers and FireMoveLayers.loot
	local key = ns.Layout and ns.Layout()
	return all, key
end

local function Pos()
	local all, key = Store()
	return all and key and all[key]
end

local function SetPos(pos)
	local all, key = Store()
	if not (all and key) then return end
	all[key] = pos
	Loot.Apply()
	ns.Changed()
end

-- Where the rolls go: one roll's size, the first one on it.
local anchor = CreateFrame("Frame", "FireMoveLootAnchor", UIParent)
anchor:SetSize(277, 67)
anchor:SetMovable(true)
anchor:SetClampedToScreen(true)
anchor:SetFrameStrata("MEDIUM")
if anchor.SetDontSavePosition then anchor:SetDontSavePosition(true) end

local function PlaceAnchor()
	anchor:ClearAllPoints()
	local pos = Pos()
	if pos then
		anchor:SetPoint("CENTER", UIParent, "CENTER", pos[1], pos[2])
	else
		-- About where the game puts the first one.
		local base = BottomManagedFrameContainer
		if base then
			anchor:SetPoint("BOTTOM", base, "BOTTOM", 0, 16)
		else
			anchor:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 200)
		end
	end
end

-- The rolls showing, onto ours; or back where the game puts them.
local function PlaceRolls()
	local c = GroupLootContainer
	if not (c and c.rollFrames) then return end
	if InputUtil and InputUtil.IsGamepadUIEnabled and InputUtil.IsGamepadUIEnabled() then return end
	local pos, size = Pos(), c.reservedSize or 100
	local down = pos and pos[2] > 0
	for i = 1, c.maxIndex or 0 do
		local frame = c.rollFrames[i]
		if frame then
			frame:ClearAllPoints()
			if pos then
				frame:SetPoint("CENTER", anchor, "CENTER", 0, (i - 1) * size * (down and -1 or 1))
			else
				frame:SetPoint("CENTER", c, "BOTTOM", 0, size * (i - 0.5))
			end
		end
	end
end

---------------------------------------------------------------------------
-- In Edit Mode
---------------------------------------------------------------------------
local s = CreateFrame("Frame", nil, anchor, "NineSliceCodeTemplate")
s:SetAllPoints()
s:EnableMouse(true)
s:RegisterForDrag("LeftButton")
s.hover = CreateFrame("Frame", nil, s, "NineSliceCodeTemplate")
s.hover:SetAllPoints()
NineSliceUtil.ApplyLayout(s.hover, ns.SELECTION, "editmode-actionbar-highlight")
s.hover:SetAlpha(0.4)
if s.hover.SetBlendMode then s.hover:SetBlendMode("ADD") end
s.hover:Hide()
s.label = s:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
s.label:SetPoint("CENTER")
s.label:SetText("Loot Rolls")

local function Paint()
	anchor:SetShown(editing == true)
	local kit = selected and "editmode-actionbar-selected" or "editmode-actionbar-highlight"
	if s.kit ~= kit then
		NineSliceUtil.ApplyLayout(s, ns.SELECTION, kit)
		s.kit = kit
	end
end

local function CreateDialog()
	dialog = CreateFrame("Frame", "FireMoveLootDialog", UIParent)
	dialog:SetSize(300, 96)
	dialog:SetFrameStrata("DIALOG")
	dialog:SetFrameLevel(200)
	dialog:SetClampedToScreen(true)
	dialog:SetMovable(true)
	dialog:EnableMouse(true)
	dialog:RegisterForDrag("LeftButton")
	dialog:SetScript("OnDragStart", dialog.StartMoving)
	dialog:SetScript("OnDragStop", dialog.StopMovingOrSizing)
	dialog:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -250, 200) -- where the game puts its own
	local ok, border = pcall(CreateFrame, "Frame", nil, dialog, "DialogBorderTranslucentTemplate")
	if ok and border then
		border:SetAllPoints()
	else
		border = CreateFrame("Frame", nil, dialog, "BackdropTemplate")
		border:SetAllPoints()
		border:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			tile = true, tileSize = 32, edgeSize = 32,
			insets = { left = 11, right = 12, top = 12, bottom = 11 },
		})
	end
	local title = dialog:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
	title:SetPoint("TOP", 0, -15)
	title:SetText("Loot Rolls")
	local close = CreateFrame("Button", nil, dialog, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT")
	close:SetScript("OnClick", function() Loot.Deselect() end)
	dialog.reset = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
	dialog.reset:SetSize(250, 22)
	dialog.reset:SetPoint("TOP", 0, -50)
	dialog.reset:SetText("Reset To Default Position")
	dialog.reset:SetScript("OnClick", function() SetPos(nil) end)
	dialog:Hide()
end

local function Select()
	if not editing then return end
	if not selected then
		selected = true
		-- One selection at a time: the game's, the extra bars', ours.
		local manager, theirs = EditModeManagerFrame, EditModeSystemSettingsDialog
		if manager and manager.ClearSelectedSystem and theirs and theirs:IsShown() then
			manager:ClearSelectedSystem()
		end
		if ns.DeselectBar then ns.DeselectBar() end
		Paint()
	end
	if not dialog then CreateDialog() end
	dialog.reset:SetEnabled(Pos() ~= nil)
	dialog:Show()
end

function Loot.Deselect()
	if dialog then dialog:Hide() end
	if not selected then return end
	selected = nil
	Paint()
end

s:SetScript("OnMouseDown", Select)
s:SetScript("OnDragStart", function()
	Select()
	anchor:StartMoving()
end)
s:SetScript("OnDragStop", function()
	anchor:StopMovingOrSizing()
	local x, y = anchor:GetCenter()
	local ux, uy = UIParent:GetCenter()
	if x and ux then SetPos({ math.floor(x - ux + 0.5), math.floor(y - uy + 0.5) }) end
end)
s:SetScript("OnEnter", function() s.hover:Show() end)
s:SetScript("OnLeave", function() s.hover:Hide() end)

---------------------------------------------------------------------------
-- Keeping up
---------------------------------------------------------------------------
function Loot.Apply()
	PlaceAnchor()
	PlaceRolls()
	Paint()
	if dialog and dialog:IsShown() then dialog.reset:SetEnabled(Pos() ~= nil) end
end

local function SetEditing(on)
	editing = on
	if not on then Loot.Deselect() end
	Paint()
end

local hookedRolls, hookedEdit
local function Hook()
	if not hookedRolls and GroupLootContainer_Update then
		hookedRolls = true
		hooksecurefunc("GroupLootContainer_Update", function()
			if Pos() then PlaceRolls() end
		end)
	end
	local manager = EditModeManagerFrame
	if not hookedEdit and manager then
		hookedEdit = true
		if manager.SelectSystem then hooksecurefunc(manager, "SelectSystem", Loot.Deselect) end
		if manager.IsEditModeActive and manager:IsEditModeActive() then SetEditing(true) end
	end
end

if EventRegistry then
	EventRegistry:RegisterCallback("EditMode.Enter", function() SetEditing(true) end, {})
	EventRegistry:RegisterCallback("EditMode.Exit", function() SetEditing(false) end, {})
end

anchor:Hide()
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(_, event, addon)
	if event == "PLAYER_LOGIN" or addon == "Blizzard_EditMode" then
		Hook()
		Loot.Apply()
	end
end)
