-- Loot rolls (need or greed) and alerts ("you won", achievements...) in Edit
-- Mode: a "Loot Rolls" box and an "Alerts" box show where they come up; drag
-- one to move them. Kept with the Edit Mode layout, saved like the game's
-- frames (FireMove.lua). They stack up from there, or down when it's in the
-- top half of the screen.
--
-- Only the popups move, after the game places them: its own frames for them
-- (the rolls' place in its stack at the bottom, the alerts' base) stay as
-- they are, since setting anything on those from here would taint the stack.
local _, ns = ...

local Popups = {}
ns.Popups = Popups

local ROLLS = { key = "rolls", label = "Loot Rolls", width = 277, height = 67 }
local ALERTS = { key = "alerts", label = "Alerts", width = 276, height = 96 }
local ALL = { ROLLS, ALERTS }
local GAP = 10 -- between alerts, as the game has it

local editing, selected, dialog

local function Store()
	local all = FireMoveLayers and FireMoveLayers.popups
	local key = ns.Layout and ns.Layout()
	return all, key
end

local function Pos(e)
	local all, key = Store()
	return all and key and all[key] and all[key][e.key]
end

local function Down(e)
	local pos = Pos(e)
	return pos ~= nil and pos[2] > 0
end

---------------------------------------------------------------------------
-- Where the game puts them; and where they're moved to
---------------------------------------------------------------------------
-- The rolls showing, onto ours (the first one on the box); or back where the
-- game puts them.
local function PlaceRolls()
	local c = GroupLootContainer
	if not (c and c.rollFrames) then return end
	if InputUtil and InputUtil.IsGamepadUIEnabled and InputUtil.IsGamepadUIEnabled() then return end
	local moved, size = Pos(ROLLS), c.reservedSize or 100
	local step = Down(ROLLS) and -size or size
	for i = 1, c.maxIndex or 0 do
		local frame = c.rollFrames[i]
		if frame then
			frame:ClearAllPoints()
			if moved then
				frame:SetPoint("CENTER", ROLLS.box, "CENTER", 0, (i - 1) * step)
			else
				frame:SetPoint("CENTER", c, "BOTTOM", 0, size * (i - 0.5))
			end
		end
	end
end

-- The alerts showing, stacked from ours; or from the game's base, through
-- the frames it lines them up on (the rolls).
local function PlaceAlerts()
	local a = AlertFrame
	if not (a and a.alertFrameSubSystems) then return end
	local moved, down = Pos(ALERTS), Down(ALERTS)
	local relative, first = moved and ALERTS.box or a.baseAnchorFrame or a, moved
	local external = AlertFrameExternallyAnchoredMixin and AlertFrameExternallyAnchoredMixin.AdjustAnchors
	for _, sub in ipairs(a.alertFrameSubSystems) do
		if sub.alertFramePool then
			for frame in sub.alertFramePool:EnumerateActive() do
				frame:ClearAllPoints()
				if first then
					local side = down and "TOP" or "BOTTOM"
					frame:SetPoint(side, relative, side)
				elseif down then
					frame:SetPoint("TOP", relative, "BOTTOM", 0, -GAP)
				else
					frame:SetPoint("BOTTOM", relative, "TOP", 0, GAP)
				end
				relative, first = frame, false
			end
		elseif not moved and sub.anchorFrame and sub.anchorFrame:IsShown() and sub.AdjustAnchors == external then
			relative = sub.anchorFrame
		end
	end
end

ROLLS.place = PlaceRolls
ALERTS.place = PlaceAlerts

-- About where the game puts the first one.
function ROLLS.default(box)
	local base = BottomManagedFrameContainer
	if base then
		box:SetPoint("BOTTOM", base, "BOTTOM", 0, 16)
	else
		box:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 200)
	end
end

function ALERTS.default(box)
	if AlertFrame then
		box:SetPoint("BOTTOM", AlertFrame, "TOP", 0, GAP)
	else
		box:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 138)
	end
end

---------------------------------------------------------------------------
-- In Edit Mode: a box for each
---------------------------------------------------------------------------
local Select, SetPos

local function Paint(e)
	e.box:SetShown(editing == true)
	local s = e.box.selection
	local kit = selected == e and "editmode-actionbar-selected" or "editmode-actionbar-highlight"
	if s.kit ~= kit then
		NineSliceUtil.ApplyLayout(s, ns.SELECTION, kit)
		s.kit = kit
	end
end

local function PaintAll()
	for _, e in ipairs(ALL) do Paint(e) end
end

local function PlaceBox(e)
	local box = e.box
	box:ClearAllPoints()
	local pos = Pos(e)
	if pos then
		box:SetPoint("CENTER", UIParent, "CENTER", pos[1], pos[2])
	else
		e.default(box)
	end
end

for _, e in ipairs(ALL) do
	local box = CreateFrame("Frame", "FireMove" .. e.key:gsub("^%l", string.upper) .. "Box", UIParent)
	box:SetSize(e.width, e.height)
	box:SetMovable(true)
	box:SetClampedToScreen(true)
	box:SetFrameStrata("MEDIUM")
	if box.SetDontSavePosition then box:SetDontSavePosition(true) end
	box:Hide()
	e.box = box

	local s = CreateFrame("Frame", nil, box, "NineSliceCodeTemplate")
	s:SetAllPoints()
	s:EnableMouse(true)
	s:RegisterForDrag("LeftButton")
	s.hover = CreateFrame("Frame", nil, s, "NineSliceCodeTemplate")
	s.hover:SetAllPoints()
	NineSliceUtil.ApplyLayout(s.hover, ns.SELECTION, "editmode-actionbar-highlight")
	s.hover:SetAlpha(0.4)
	if s.hover.SetBlendMode then s.hover:SetBlendMode("ADD") end
	s.hover:Hide()
	local label = s:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
	label:SetPoint("CENTER")
	label:SetText(e.label)
	s:SetScript("OnMouseDown", function() Select(e) end)
	s:SetScript("OnDragStart", function()
		Select(e)
		box:StartMoving()
		FireEditMode.Preview(box)
	end)
	s:SetScript("OnDragStop", function()
		FireEditMode.StopPreview()
		box:StopMovingOrSizing()
		local dx, dy = FireEditMode.SnapMove(box)
		local x, y = box:GetCenter()
		local ux, uy = UIParent:GetCenter()
		if x and ux then SetPos(e, { math.floor(x - ux + dx + 0.5), math.floor(y - uy + dy + 0.5) }) end
	end)
	s:SetScript("OnEnter", function() s.hover:Show() end)
	s:SetScript("OnLeave", function() s.hover:Hide() end)
	box.selection = s
end

local function Same(a, b)
	if a == nil or b == nil then return a == b end
	return a[1] == b[1] and a[2] == b[2]
end

-- Laid out as the game's (EditModeSystemSettingsDialog): its title, Revert
-- Changes, a divider, Reset To Default Position.
local function DialogButton(width, y, text, onClick)
	local b = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
	b:SetSize(width, 28)
	b:SetPoint("TOPLEFT", 20, y)
	b:SetText(text)
	b:SetScript("OnClick", onClick)
	return b
end

local function CreateDialog()
	dialog = CreateFrame("Frame", "FireMovePopupDialog", UIParent)
	dialog:SetSize(383, 150)
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
	dialog.title = dialog:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
	dialog.title:SetPoint("TOP", 0, -15)
	local close = CreateFrame("Button", nil, dialog, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT")
	close:SetScript("OnClick", function() Popups.Deselect() end)
	-- Back where it was last saved.
	dialog.revert = DialogButton(180, -54, HUD_EDIT_MODE_REVERT_CHANGES or "Revert Changes", function()
		if not selected then return end
		local saved = ns.SavedPopup and ns.SavedPopup(selected.key)
		SetPos(selected, saved and { saved[1], saved[2] })
	end)
	local divider = dialog:CreateTexture(nil, "ARTWORK")
	divider:SetTexture("Interface\\FriendsFrame\\UI-FriendsFrame-OnlineDivider")
	divider:SetSize(330, 16)
	divider:SetPoint("TOPLEFT", 20, -84)
	dialog.reset = DialogButton(330, -102, HUD_EDIT_MODE_RESET_POSITION or "Reset To Default Position", function()
		if selected then SetPos(selected, nil) end
	end)
	dialog:Hide()
end

local function RefreshDialog()
	if not (dialog and selected) then return end
	dialog.title:SetText(selected.label)
	dialog.revert:SetEnabled(not Same(Pos(selected), ns.SavedPopup and ns.SavedPopup(selected.key)))
	dialog.reset:SetEnabled(Pos(selected) ~= nil)
end

function Select(e)
	if not editing then return end
	if selected ~= e then
		selected = e
		-- One selection at a time: the game's, the extra bars', ours.
		local manager, theirs = EditModeManagerFrame, EditModeSystemSettingsDialog
		if manager and manager.ClearSelectedSystem and theirs and theirs:IsShown() then
			manager:ClearSelectedSystem()
		end
		if ns.DeselectBar then ns.DeselectBar() end
		if FireEditMode and FireEditMode.Deselect then FireEditMode.Deselect() end
		PaintAll()
	end
	if not dialog then CreateDialog() end
	RefreshDialog()
	dialog:Show()
end

function Popups.Deselect()
	if dialog then dialog:Hide() end
	if not selected then return end
	selected = nil
	PaintAll()
end

---------------------------------------------------------------------------
-- Keeping up
---------------------------------------------------------------------------
local function ApplyOne(e)
	PlaceBox(e)
	e.place()
	Paint(e)
end

function Popups.Apply()
	for _, e in ipairs(ALL) do ApplyOne(e) end
	RefreshDialog()
end

Popups.Refresh = RefreshDialog -- saved: nothing to revert

function SetPos(e, pos)
	local all, key = Store()
	if not (all and key) then return end
	all[key] = all[key] or {}
	all[key][e.key] = pos
	if not next(all[key]) then all[key] = nil end
	ApplyOne(e)
	RefreshDialog()
	ns.Changed()
end

local function SetEditing(on)
	editing = on
	if not on then Popups.Deselect() end
	PaintAll()
end

local hookedRolls, hookedAlerts, hookedEdit
local function Hook()
	if not hookedRolls and GroupLootContainer_Update then
		hookedRolls = true
		hooksecurefunc("GroupLootContainer_Update", function()
			if Pos(ROLLS) then PlaceRolls() end
		end)
	end
	if not hookedAlerts and AlertFrame and AlertFrame.UpdateAnchors then
		hookedAlerts = true
		hooksecurefunc(AlertFrame, "UpdateAnchors", function()
			if Pos(ALERTS) then PlaceAlerts() end
		end)
	end
	local manager = EditModeManagerFrame
	if not hookedEdit and manager then
		hookedEdit = true
		if manager.SelectSystem then hooksecurefunc(manager, "SelectSystem", Popups.Deselect) end
		if manager.IsEditModeActive and manager:IsEditModeActive() then SetEditing(true) end
	end
end

if EventRegistry then
	EventRegistry:RegisterCallback("EditMode.Enter", function() SetEditing(true) end, {})
	EventRegistry:RegisterCallback("EditMode.Exit", function() SetEditing(false) end, {})
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(_, event, addon)
	if event == "PLAYER_LOGIN" or addon == "Blizzard_EditMode" then
		Hook()
		Popups.Apply()
	end
end)
