-- The tracker in Edit Mode, like the game's own elements: a box under the Edit
-- Mode window turns it on or off; it shows blue, click to select it, drag to
-- move it, and drag the corner of the selected one to size it. Both line up
-- with the grid and other elements when "Snap to Elements" is on.
-- Like the game's, a change waits for Edit Mode's Save (its Save and Revert
-- buttons light up for it); Revert All Changes, or leaving without saving,
-- puts it back. Left with only the tracker's change unsaved (the game doesn't
-- ask then), our own box asks.
--
-- All ours, beside the game's: the game lays out what's in its Edit Mode
-- window, and anything of ours in there would taint that.
local _, ns = ...
local Tracker = ns.Tracker

local SNAP = 10
-- The game's look for an element in Edit Mode.
local SELECTION = {
	TopRightCorner = { atlas = "%s-NineSlice-Corner", mirrorLayout = true, x = 8, y = 8 },
	TopLeftCorner = { atlas = "%s-NineSlice-Corner", mirrorLayout = true, x = -8, y = 8 },
	BottomLeftCorner = { atlas = "%s-NineSlice-Corner", mirrorLayout = true, x = -8, y = -8 },
	BottomRightCorner = { atlas = "%s-NineSlice-Corner", mirrorLayout = true, x = 8, y = -8 },
	TopEdge = { atlas = "_%s-NineSlice-EdgeTop" },
	BottomEdge = { atlas = "_%s-NineSlice-EdgeBottom" },
	LeftEdge = { atlas = "!%s-NineSlice-EdgeLeft" },
	RightEdge = { atlas = "!%s-NineSlice-EdgeRight" },
	Center = { atlas = "%s-NineSlice-Center", x = -8, y = 8, x1 = 8, y1 = -8 },
}

local editing, selected, sizing
local selection, grip, box, check, ask
local saved -- the tracker's place and size as last saved

local function Manager() return EditModeManagerFrame end

local function Copy()
	local db = ns.db
	return { point = db.trackerPoint and { unpack(db.trackerPoint) }, width = db.trackerWidth, height = db.trackerHeight }
end

local function Same(a, b)
	local pa, pb = a.point or {}, b.point or {}
	for i = 1, 4 do
		if pa[i] ~= pb[i] then return false end
	end
	return a.width == b.width and a.height == b.height
end

local function Restore(s)
	local db = ns.db
	db.trackerPoint = s.point and { unpack(s.point) }
	db.trackerWidth, db.trackerHeight = s.width, s.height
	Tracker.Place()
	Tracker.Refresh()
end

---------------------------------------------------------------------------
-- Unsaved changes
---------------------------------------------------------------------------
-- The Fire addons' unsaved Edit Mode changes: { [addon] = true }. Shared, so
-- each one keeps the game's Save and Revert buttons on for the others' too.
FireEditModeUnsaved = FireEditModeUnsaved or {}

local function Dirty() return FireEditModeUnsaved.FireTodo == true end

local function SyncButtons()
	local m = Manager()
	if not (m and m.HasActiveChanges) then return end
	local on = m:HasActiveChanges() and true or false
	for _, v in pairs(FireEditModeUnsaved) do
		if v then on = true end
	end
	if m.SaveChangesButton then m.SaveChangesButton:SetEnabled(on) end
	if m.RevertAllChangesButton then m.RevertAllChangesButton:SetEnabled(on) end
end

local function SetDirty(on)
	FireEditModeUnsaved.FireTodo = on or nil
	SyncButtons()
end

-- Moved or sized: unsaved, unless it's back as saved.
local function Changed()
	SetDirty(saved ~= nil and not Same(Copy(), saved))
end

local function Commit()
	if not ns.db then return end
	saved = Copy()
	SetDirty(false)
end

-- Our own box, not the game's popups: writing to those taints the Escape key.
local function Ask(unsaved)
	if not ask then
		ask = CreateFrame("Frame", "FireTodoUnsaved", UIParent, "BackdropTemplate")
		ask:SetSize(330, 96)
		ask:SetPoint("TOP", 0, -240) -- below FireMove's, if both ask
		ask:SetFrameStrata("DIALOG")
		ask:EnableMouse(true)
		ask:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			tile = true, tileSize = 32, edgeSize = 32,
			insets = { left = 11, right = 12, top = 12, bottom = 11 },
		})
		local text = ask:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		text:SetPoint("TOP", 0, -22)
		text:SetWidth(290)
		text:SetText("Save your changes to the Todo Tracker?")
		local save = CreateFrame("Button", nil, ask, "UIPanelButtonTemplate")
		save:SetSize(120, 22)
		save:SetPoint("BOTTOMRIGHT", ask, "BOTTOM", -6, 18)
		save:SetText(SAVE or "Save")
		save:SetScript("OnClick", function()
			ask:Hide()
			Restore(ask.unsaved)
			Commit()
		end)
		local discard = CreateFrame("Button", nil, ask, "UIPanelButtonTemplate")
		discard:SetSize(120, 22)
		discard:SetPoint("BOTTOMLEFT", ask, "BOTTOM", 6, 18)
		discard:SetText("Discard")
		discard:SetScript("OnClick", function() ask:Hide() end)
	end
	ask.unsaved = unsaved
	ask:Show()
end

-- Revert All Changes, or leaving Edit Mode (the game reverts what's unsaved).
local function Reverted()
	if not (ns.db and saved) then return end
	local m = Manager()
	local exiting = not (m and m.IsEditModeActive and m:IsEditModeActive())
	local before = Dirty() and Copy()
	local theirs = EditModeUnsavedChangesDialog
	local asking = exiting and before and not (theirs and theirs:IsShown())
	SetDirty(false)
	Restore(saved)
	if asking then Ask(before) end
end

---------------------------------------------------------------------------
-- Snapping: to the screen's edges and middle, the grid's lines (when shown),
-- and the edges of the game's elements and FireMove's bars.
---------------------------------------------------------------------------
local function Elements(frame)
	local list = {}
	local m = Manager()
	for _, f in ipairs(m and m.registeredSystemFrames or {}) do
		if f ~= frame and f.IsVisible and f:IsVisible() then list[#list + 1] = f end
	end
	for i = 1, 40 do
		local f = _G["FireMoveBar" .. i]
		if f and f:IsVisible() then list[#list + 1] = f end
	end
	return list
end

-- A rect in frame's own coordinates.
local function Rect(f, frame)
	local l, b, w, h = f:GetRect()
	if not l then return nil end
	local k = f:GetEffectiveScale() / frame:GetEffectiveScale()
	return l * k, b * k, (l + w) * k, (b + h) * k
end

-- Lines anything lines up with: { x = {...}, y = {...} }.
local function Lines(frame)
	local xs, ys = {}, {}
	local k = UIParent:GetEffectiveScale() / frame:GetEffectiveScale()
	local w, h = UIParent:GetWidth() * k, UIParent:GetHeight() * k
	for _, v in ipairs({ 0, w / 2, w }) do xs[#xs + 1] = v end
	for _, v in ipairs({ 0, h / 2, h }) do ys[#ys + 1] = v end
	local grid = Manager() and Manager().Grid
	local spacing = grid and grid:IsShown() and grid.gridSpacing
	if spacing and spacing > 0 then
		local cx, cy = grid:GetCenter()
		if cx then
			local g = grid:GetEffectiveScale() / frame:GetEffectiveScale()
			cx, cy, spacing = cx * g, cy * g, spacing * g
			for i = -math.ceil(w / spacing), math.ceil(w / spacing) do xs[#xs + 1] = cx + i * spacing end
			for i = -math.ceil(h / spacing), math.ceil(h / spacing) do ys[#ys + 1] = cy + i * spacing end
		end
	end
	return xs, ys
end

-- The smallest move (under SNAP) that puts one of edges on one of values.
local function Best(best, edges, values)
	for _, e in ipairs(edges) do
		for _, v in ipairs(values) do
			local d = v - e
			if math.abs(d) < SNAP and (not best or math.abs(d) < math.abs(best)) then best = d end
		end
	end
	return best
end

local function SnapOn()
	local m = Manager()
	return m and m.IsSnapEnabled and m:IsSnapEnabled()
end

-- Moved: its edges or middle to a line; beside an element (touching, tops or
-- bottoms even) or above or below one (touching, sides even).
local function SnapMove(frame)
	if not SnapOn() then return 0, 0 end
	local l, b, w, h = frame:GetRect()
	if not l then return 0, 0 end
	local r, t = l + w, b + h
	local xs, ys = Lines(frame)
	local dx = Best(nil, { l, r, l + w / 2 }, xs)
	local dy = Best(nil, { b, t, b + h / 2 }, ys)
	for _, f in ipairs(Elements(frame)) do
		local fl, fb, fr, ft = Rect(f, frame)
		if fl then
			if b < ft + SNAP and t > fb - SNAP then -- side by side
				dx = Best(dx, { l, r }, { fr, fl })
				dy = Best(dy, { b, t }, { fb, ft })
			end
			if l < fr + SNAP and r > fl - SNAP then -- stacked
				dy = Best(dy, { b, t }, { ft, fb })
				dx = Best(dx, { l, r }, { fl, fr })
			end
		end
	end
	return dx or 0, dy or 0
end

-- Sized: its right and bottom edges to a line or an element's edge.
local function SnapSize(frame)
	if not SnapOn() then return 0, 0 end
	local l, b, w, h = frame:GetRect()
	if not l then return 0, 0 end
	local xs, ys = Lines(frame)
	for _, f in ipairs(Elements(frame)) do
		local fl, fb, fr, ft = Rect(f, frame)
		if fl then
			xs[#xs + 1], xs[#xs + 2] = fl, fr
			ys[#ys + 1], ys[#ys + 2] = fb, ft
		end
	end
	return Best(nil, { l + w }, xs) or 0, Best(nil, { b }, ys) or 0
end

---------------------------------------------------------------------------
-- The blue box
---------------------------------------------------------------------------
local function Paint()
	if not selection then return end
	local on = editing and Tracker.Enabled()
	selection:SetShown(on == true)
	grip:SetShown(on and selected == true)
	if not on then return end
	local kit = selected and "editmode-actionbar-selected" or "editmode-actionbar-highlight"
	if selection.kit ~= kit then
		NineSliceUtil.ApplyLayout(selection, SELECTION, kit)
		selection.kit = kit
	end
end

local function Select()
	if selected then return end
	selected = true
	-- The game's selection (and its settings) closes: one at a time.
	local m, theirs = Manager(), EditModeSystemSettingsDialog
	if m and m.ClearSelectedSystem and theirs and theirs:IsShown() then m:ClearSelectedSystem() end
	Paint()
end

local function Deselect()
	if not selected then return end
	selected = false
	Paint()
end

local function Bounds(frame)
	local T = Tracker
	if frame.SetResizeBounds then
		frame:SetResizeBounds(T.MIN_W, T.MIN_H, T.MAX_W, T.MAX_H)
	else
		if frame.SetMinResize then frame:SetMinResize(T.MIN_W, T.MIN_H) end
		if frame.SetMaxResize then frame:SetMaxResize(T.MAX_W, T.MAX_H) end
	end
end

local function SaveSize(frame)
	local T = Tracker
	ns.db.trackerWidth = math.max(T.MIN_W, math.min(T.MAX_W, math.floor(frame:GetWidth() + 0.5)))
	ns.db.trackerHeight = math.max(T.MIN_H, math.min(T.MAX_H, math.floor(frame:GetHeight() + 0.5)))
end

local function MakeSelection()
	local frame = Tracker.Frame()
	frame:SetResizable(true)
	Bounds(frame)
	selection = CreateFrame("Frame", nil, frame, "NineSliceCodeTemplate")
	selection:SetAllPoints()
	selection:SetFrameLevel(frame:GetFrameLevel() + 50)
	selection:EnableMouse(true)
	selection:RegisterForDrag("LeftButton")
	selection.hover = CreateFrame("Frame", nil, selection, "NineSliceCodeTemplate")
	selection.hover:SetAllPoints()
	NineSliceUtil.ApplyLayout(selection.hover, SELECTION, "editmode-actionbar-highlight")
	selection.hover:SetAlpha(0.4)
	if selection.hover.SetBlendMode then selection.hover:SetBlendMode("ADD") end
	selection.hover:Hide()
	local label = selection:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
	label:SetPoint("CENTER")
	label:SetText("Todo Tracker")
	selection:SetScript("OnMouseDown", Select)
	selection:SetScript("OnDragStart", function()
		Select()
		frame:StartMoving()
	end)
	selection:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		local dx, dy = SnapMove(frame)
		local x, y = frame:GetLeft(), frame:GetTop()
		frame:ClearAllPoints()
		frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x + dx, y + dy)
		Tracker.Pin()
		Changed()
	end)
	selection:SetScript("OnEnter", function() selection.hover:Show() end)
	selection:SetScript("OnLeave", function() selection.hover:Hide() end)

	grip = CreateFrame("Button", nil, selection)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", -2, 2)
	grip:SetFrameLevel(selection:GetFrameLevel() + 5)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	grip:SetScript("OnMouseDown", function()
		Tracker.Pin() -- sized from its top left
		sizing = true
		frame:StartSizing("BOTTOMRIGHT")
		grip:SetScript("OnUpdate", function()
			SaveSize(frame)
			Tracker.Refresh() -- its todos wrap to the new width as it goes
		end)
	end)
	grip:SetScript("OnMouseUp", function()
		if not sizing then return end
		sizing = false
		grip:SetScript("OnUpdate", nil)
		frame:StopMovingOrSizing()
		local dw, dh = SnapSize(frame)
		frame:SetSize(frame:GetWidth() + dw, frame:GetHeight() - dh)
		SaveSize(frame)
		Tracker.Pin()
		Tracker.Refresh()
		Changed()
	end)
	selection:Hide()
end

---------------------------------------------------------------------------
-- On or off: a box under the Edit Mode window (under FireMove's, if shown)
---------------------------------------------------------------------------
local function PlaceBox()
	if not box then return end
	local m, above = Manager(), _G.FireMoveNewBarBox
	box:ClearAllPoints()
	if above and above:IsShown() then
		box:SetPoint("TOP", above, "BOTTOM", 0, -2)
	elseif m then
		box:SetPoint("TOP", m, "BOTTOM", 0, -2)
	end
end

local function MakeBox()
	box = CreateFrame("Frame", "FireTodoEditModeBox", UIParent, "BackdropTemplate")
	box:SetSize(200, 40)
	box:SetFrameStrata("DIALOG")
	box:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	check = CreateFrame("CheckButton", nil, box, "UICheckButtonTemplate")
	check:SetSize(30, 30)
	check:SetPoint("LEFT", 12, 0)
	local label = box:CreateFontString(nil, "ARTWORK", "GameFontHighlightMedium")
	label:SetPoint("LEFT", check, "RIGHT", 4, 0)
	label:SetText("Todo Tracker")
	check:SetScript("OnClick", function(self)
		ns.db.trackerShown = self:GetChecked() and true or false
		if not ns.db.trackerShown then Deselect() end
		Tracker.Refresh()
		Paint()
	end)
	-- Like the game's: hovering it lights up the element.
	check:SetScript("OnEnter", function() if selection and selection:IsShown() then selection.hover:Show() end end)
	check:SetScript("OnLeave", function() if selection then selection.hover:Hide() end end)
	box:Hide()
end

---------------------------------------------------------------------------
-- Entering and leaving Edit Mode
---------------------------------------------------------------------------
local function SetEditing(on)
	if not ns.db then return end
	editing = on
	if on then
		if not selection then MakeSelection() end
		if not box then MakeBox() end
		if not saved then saved = Copy() end
		if ask then ask:Hide() end
		check:SetChecked(Tracker.Enabled())
		box:Show()
		C_Timer.After(0, PlaceBox) -- once FireMove's box is in place
	else
		Deselect()
		if box then box:Hide() end
	end
	Tracker.SetEditing(on)
	Paint()
end

local hooked
local function HookEditMode()
	local m = Manager()
	if hooked or not m then return end
	hooked = true
	if m.SelectSystem then hooksecurefunc(m, "SelectSystem", Deselect) end
	if m.RevertAllChanges then hooksecurefunc(m, "RevertAllChanges", Reverted) end
	if m.SaveLayouts then hooksecurefunc(m, "SaveLayouts", Commit) end
	-- The game turns its Save and Revert buttons off when it has nothing unsaved: on again for ours.
	if m.SetHasActiveChanges then hooksecurefunc(m, "SetHasActiveChanges", SyncButtons) end
	if m.IsEditModeActive and m:IsEditModeActive() then SetEditing(true) end
end

if EventRegistry then
	EventRegistry:RegisterCallback("EditMode.Enter", function() SetEditing(true) end, {})
	EventRegistry:RegisterCallback("EditMode.Exit", function() SetEditing(false) end, {})
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
pcall(events.RegisterEvent, events, "GLOBAL_MOUSE_DOWN")
events:SetScript("OnEvent", function(_, event, addon)
	if event == "GLOBAL_MOUSE_DOWN" then
		-- A click anywhere else lets go of it.
		if selected and not (selection:IsMouseOver() or (box and box:IsMouseOver())) then Deselect() end
	elseif event == "PLAYER_LOGIN" or addon == "Blizzard_EditMode" then
		if event == "PLAYER_LOGIN" and ns.db and not saved then saved = Copy() end
		HookEditMode()
	end
end)
