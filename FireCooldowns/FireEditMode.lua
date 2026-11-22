-- FireEditMode: the Fire addons' on-screen elements in the game's Edit Mode,
-- working like its own. Each addon carries a copy of this file; the newest
-- loaded is the one used (FireEditMode.version), shared by all of them.
--
--   In Edit Mode each element shows blue: click it to select it (its settings
--   open, like the game's), drag it to move it, drag the corner of a sizable
--   one to size it. Both line up with the grid, the screen and other elements
--   when "Snap to Elements" is on, with red lines where they will, like the
--   game's. A box under the Edit Mode window turns them on or off.
--   Like the game's, changes wait for Edit Mode's Save (its Save and Revert
--   buttons light up for them); Revert All Changes, or leaving without saving,
--   puts them back. Left with only ours unsaved (the game doesn't ask then),
--   our own box asks.
--
-- All of it beside the game's, never in it: the game lays out what's in its
-- Edit Mode windows, and anything of ours in there would taint that. Nor its
-- popups (writing to those taints the Escape key).
--
-- An addon registers each element once its settings are loaded:
--   local e = FireEditMode.Register({
--     name = "FireProcs",                  -- unique
--     label = "Proc Announcements",        -- on its blue box, dialog and toggle
--     frame = frame,
--     GetState = function() return {...} end, -- what Save keeps and Revert puts back (plain data)
--     SetState = function(state) end,      -- put it back (a copy of what GetState gave)
--     Moved = function(frame) end,         -- dropped: frame is at its new place; keep it
--     Toggle = { get = fn, set = fn(on) }, -- optional: on/off in the box
--     resize = { minW, minH, maxW, maxH }, -- optional: sizable from its corner...
--     Sizing = function(w, h) end,         -- ...called as it's sized
--     settings = { { label, min, max, step, get, set, format } }, -- optional sliders
--     Default = function() end,            -- optional: "Reset To Default Position"...
--     IsDefault = function() end,          -- ...greyed out while this is true
--     Editing = function(on) end,          -- optional: Edit Mode opened or closed
--   })
--   FireEditMode.Changed(e) -- after changing its state another way
--
-- Other frames can snap the same way (FireMove's bars):
--   FireEditMode.Preview(frame) as it starts moving, FireEditMode.StopPreview()
--   when it stops, then FireEditMode.SnapMove(frame) for how far to move it.
local VERSION = 3
local lib = _G.FireEditMode
if lib and (lib.version or 0) >= VERSION then return end
lib = lib or {}
_G.FireEditMode = lib
lib.version = VERSION
lib.elements = lib.elements or {}

-- The Fire addons' unsaved Edit Mode changes: { [name] = true }. Shared with
-- FireMove, so each keeps the game's Save and Revert buttons on for the others'.
FireEditModeUnsaved = FireEditModeUnsaved or {}

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
local BACKDROP = {
	bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
	edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
	tile = true, tileSize = 32, edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local function Manager() return EditModeManagerFrame end

local function Copy(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do out[k] = Copy(v) end
	return out
end

local function Same(a, b)
	if type(a) ~= "table" or type(b) ~= "table" then return a == b end
	for k, v in pairs(a) do
		if not Same(v, b[k]) then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

local function Report(err)
	print("|cffff8030FireEditMode|r: |cffff4040error:|r " .. tostring(err))
end
local function Call(fn, ...)
	if fn then
		local ok, err = pcall(fn, ...)
		if not ok then Report(err) end
	end
end

local function Shown(e) return not e.Toggle or e.Toggle.get() ~= false end

---------------------------------------------------------------------------
-- Unsaved changes
---------------------------------------------------------------------------
function lib.SyncButtons()
	for _, e in ipairs(lib.elements) do FireEditModeUnsaved[e.name] = e.dirty or nil end
	local m = Manager()
	if not (m and m.HasActiveChanges) then return end
	local on = m:HasActiveChanges() and true or false
	for _, v in pairs(FireEditModeUnsaved) do
		if v then on = true end
	end
	if m.SaveChangesButton then m.SaveChangesButton:SetEnabled(on) end
	if m.RevertAllChangesButton then m.RevertAllChangesButton:SetEnabled(on) end
end

-- Its state changed: unsaved in Edit Mode (unless it's back as saved), else kept.
function lib.Changed(e)
	if lib.editing then
		e.dirty = not Same(e.GetState(), e.saved)
	else
		e.saved = Copy(e.GetState())
		e.dirty = false
	end
	lib.SyncButtons()
	if lib.selected == e and lib.dialog and lib.dialog:IsShown() then lib.RefreshDialog() end
end

function lib.Commit()
	for _, e in ipairs(lib.elements) do
		e.saved = Copy(e.GetState())
		e.dirty = false
	end
	lib.SyncButtons()
	if lib.dialog and lib.dialog:IsShown() then lib.RefreshDialog() end
end

function lib.Ask(unsaved)
	local ask = lib.ask
	if not ask then
		ask = CreateFrame("Frame", "FireEditModeUnsavedBox", UIParent, "BackdropTemplate")
		lib.ask = ask
		ask:SetSize(330, 110)
		ask:SetPoint("TOP", 0, -240) -- below FireMove's, if both ask
		ask:SetFrameStrata("DIALOG")
		ask:EnableMouse(true)
		ask:SetBackdrop({
			bgFile = BACKDROP.bgFile, edgeFile = BACKDROP.edgeFile, tile = true, tileSize = 32, edgeSize = 32,
			insets = { left = 11, right = 12, top = 12, bottom = 11 },
		})
		ask.text = ask:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		ask.text:SetPoint("TOP", 0, -22)
		ask.text:SetWidth(290)
		local save = CreateFrame("Button", nil, ask, "UIPanelButtonTemplate")
		save:SetSize(120, 22)
		save:SetPoint("BOTTOMRIGHT", ask, "BOTTOM", -6, 18)
		save:SetText(SAVE or "Save")
		save:SetScript("OnClick", function()
			ask:Hide()
			for e, state in pairs(ask.unsaved) do Call(e.SetState, Copy(state)) end
			lib.Commit()
		end)
		local discard = CreateFrame("Button", nil, ask, "UIPanelButtonTemplate")
		discard:SetSize(120, 22)
		discard:SetPoint("BOTTOMLEFT", ask, "BOTTOM", 6, 18)
		discard:SetText("Discard")
		discard:SetScript("OnClick", function() ask:Hide() end)
	end
	local names = {}
	for _, e in ipairs(lib.elements) do
		if unsaved[e] then names[#names + 1] = e.label end
	end
	ask.text:SetText("Save your changes to " .. table.concat(names, ", ") .. "?")
	ask.unsaved = unsaved
	ask:Show()
end

-- Revert All Changes, or leaving Edit Mode (the game reverts what's unsaved).
function lib.Reverted()
	local m = Manager()
	local exiting = not (m and m.IsEditModeActive and m:IsEditModeActive())
	local unsaved
	for _, e in ipairs(lib.elements) do
		if e.dirty then
			unsaved = unsaved or {}
			unsaved[e] = Copy(e.GetState())
			e.dirty = false
			Call(e.SetState, Copy(e.saved))
		end
	end
	lib.SyncButtons()
	if lib.dialog and lib.dialog:IsShown() then lib.RefreshDialog() end
	local theirs = EditModeUnsavedChangesDialog
	if exiting and unsaved and not (theirs and theirs:IsShown()) then lib.Ask(unsaved) end
end

---------------------------------------------------------------------------
-- Snapping: to the screen's edges and middle, the grid's lines (when shown),
-- and the edges of the game's elements, FireMove's bars and each other.
---------------------------------------------------------------------------
local function Others(frame)
	local list = {}
	local m = Manager()
	for _, f in ipairs(m and m.registeredSystemFrames or {}) do
		if f ~= frame and f.IsVisible and f:IsVisible() then list[#list + 1] = f end
	end
	for i = 1, 40 do
		local f = _G["FireMoveBar" .. i]
		if f and f:IsVisible() then list[#list + 1] = f end
	end
	for _, e in ipairs(lib.elements) do
		if e.frame ~= frame and e.frame:IsVisible() then list[#list + 1] = e.frame end
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

-- The nearest of edges to one of values (nearer than best): how far to
-- move, and the line it meets.
local function Best(best, at, edges, values)
	for _, e in ipairs(edges) do
		for _, v in ipairs(values) do
			local d = v - e
			if math.abs(d) < SNAP and (not best or math.abs(d) < math.abs(best)) then best, at = d, v end
		end
	end
	return best, at
end

local function SnapOn()
	local m = Manager()
	return m and m.IsSnapEnabled and m:IsSnapEnabled()
end

-- Moved: its edges or middle to a line; beside an element (touching, tops or
-- bottoms even) or above or below one (touching, sides even). Returns how far
-- to move it, and the lines it meets (x, y in its own coordinates; nil for none).
function lib.SnapMove(frame)
	if not SnapOn() then return 0, 0 end
	local l, b, w, h = frame:GetRect()
	if not l then return 0, 0 end
	local r, t = l + w, b + h
	local xs, ys = Lines(frame)
	local dx, ax = Best(nil, nil, { l, r, l + w / 2 }, xs)
	local dy, ay = Best(nil, nil, { b, t, b + h / 2 }, ys)
	for _, f in ipairs(Others(frame)) do
		local fl, fb, fr, ft = Rect(f, frame)
		if fl then
			if b < ft + SNAP and t > fb - SNAP then -- side by side
				dx, ax = Best(dx, ax, { l, r }, { fr, fl })
				dy, ay = Best(dy, ay, { b, t }, { fb, ft })
			end
			if l < fr + SNAP and r > fl - SNAP then -- stacked
				dy, ay = Best(dy, ay, { b, t }, { ft, fb })
				dx, ax = Best(dx, ax, { l, r }, { fl, fr })
			end
		end
	end
	return dx or 0, dy or 0, ax, ay
end

-- Sized: its right and bottom edges to a line or an element's edge. Returns
-- as SnapMove.
function lib.SnapSize(frame)
	if not SnapOn() then return 0, 0 end
	local l, b, w = frame:GetRect()
	if not l then return 0, 0 end
	local xs, ys = Lines(frame)
	for _, f in ipairs(Others(frame)) do
		local fl, fb, fr, ft = Rect(f, frame)
		if fl then
			xs[#xs + 1], xs[#xs + 2] = fl, fr
			ys[#ys + 1], ys[#ys + 2] = fb, ft
		end
	end
	local dw, ax = Best(nil, nil, { l + w }, xs)
	local dh, ay = Best(nil, nil, { b }, ys)
	return dw or 0, dh or 0, ax, ay
end

-- While one moves or is sized: red lines across the screen where it will
-- snap, like the game's (EditModeManagerFrame:RefreshSnapPreviewLines).
local function DrawLines(frame, ax, ay)
	local p = lib.lines
	if not p then
		p = CreateFrame("Frame", nil, UIParent)
		p:SetAllPoints(UIParent)
		p:SetFrameStrata("HIGH")
		p.pool = {}
		lib.lines = p
	end
	for _, line in ipairs(p.pool) do line:Hide() end
	if not (ax or ay) then return end
	local k = frame:GetEffectiveScale() / p:GetEffectiveScale()
	local thick = 1.5
	if PixelUtil and PixelUtil.GetNearestPixelSize then
		thick = PixelUtil.GetNearestPixelSize(1.5, p:GetEffectiveScale(), 1.5)
	end
	local n = 0
	local function Line(x, y)
		n = n + 1
		local line = p.pool[n]
		if not line then
			line = p:CreateLine(nil, "OVERLAY")
			line:SetColorTexture(1, 0, 0, 1)
			p.pool[n] = line
		end
		line:SetThickness(thick)
		if x then
			line:SetStartPoint("BOTTOMLEFT", p, x, 0)
			line:SetEndPoint("TOPLEFT", p, x, 0)
		else
			line:SetStartPoint("BOTTOMLEFT", p, 0, y)
			line:SetEndPoint("BOTTOMRIGHT", p, 0, y)
		end
		line:Show()
	end
	if ax then Line(ax * k - (p:GetLeft() or 0)) end
	if ay then Line(nil, ay * k - (p:GetBottom() or 0)) end
end

function lib.Preview(frame, sizing)
	DrawLines(frame)
	lib.lines:SetScript("OnUpdate", function()
		local _, _, ax, ay
		if sizing then
			_, _, ax, ay = lib.SnapSize(frame)
		else
			_, _, ax, ay = lib.SnapMove(frame)
		end
		DrawLines(frame, ax, ay)
	end)
end

function lib.StopPreview()
	if not lib.lines then return end
	lib.lines:SetScript("OnUpdate", nil)
	DrawLines(UIParent)
end

---------------------------------------------------------------------------
-- The blue boxes
---------------------------------------------------------------------------
function lib.Paint()
	for _, e in ipairs(lib.elements) do
		local s = e.selection
		if s then
			local on = lib.editing and Shown(e)
			s:SetShown(on == true)
			if s.grip then s.grip:SetShown(on and lib.selected == e) end
			if on then
				local kit = lib.selected == e and "editmode-actionbar-selected" or "editmode-actionbar-highlight"
				if s.kit ~= kit then
					NineSliceUtil.ApplyLayout(s, SELECTION, kit)
					s.kit = kit
				end
			end
		end
	end
end

function lib.Select(e)
	if lib.selected ~= e then
		lib.selected = e
		-- The game's selection (and its settings) closes: one at a time.
		local m, theirs = Manager(), EditModeSystemSettingsDialog
		if m and m.ClearSelectedSystem and theirs and theirs:IsShown() then m:ClearSelectedSystem() end
		lib.Paint()
	end
	lib.ShowDialog(e)
end

function lib.Deselect()
	if lib.dialog then lib.dialog:Hide() end
	if not lib.selected then return end
	lib.selected = nil
	lib.Paint()
end

local function Placed(e)
	local frame = e.frame
	local x, y = frame:GetLeft(), frame:GetTop()
	if not x then return end
	frame:ClearAllPoints()
	frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", math.floor(x + 0.5), math.floor(y + 0.5))
	Call(e.Moved, frame)
end

local function Bounds(frame, r)
	if frame.SetResizeBounds then
		frame:SetResizeBounds(r[1], r[2], r[3], r[4])
	else
		if frame.SetMinResize then frame:SetMinResize(r[1], r[2]) end
		if frame.SetMaxResize then frame:SetMaxResize(r[3], r[4]) end
	end
end

local function Clamp(v, lo, hi) return math.max(lo, math.min(hi, math.floor(v + 0.5))) end

function lib.MakeSelection(e)
	local frame = e.frame
	frame:SetMovable(true)
	local s = CreateFrame("Frame", nil, frame, "NineSliceCodeTemplate")
	e.selection = s
	s:SetAllPoints()
	s:SetFrameLevel(frame:GetFrameLevel() + 50)
	if s.SetIgnoreParentAlpha then s:SetIgnoreParentAlpha(true) end
	s:EnableMouse(true)
	s:RegisterForDrag("LeftButton")
	s.hover = CreateFrame("Frame", nil, s, "NineSliceCodeTemplate")
	s.hover:SetAllPoints()
	NineSliceUtil.ApplyLayout(s.hover, SELECTION, "editmode-actionbar-highlight")
	s.hover:SetAlpha(0.4)
	if s.hover.SetBlendMode then s.hover:SetBlendMode("ADD") end
	s.hover:Hide()
	local label = s:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
	label:SetPoint("CENTER")
	label:SetText(e.label)
	s:SetScript("OnMouseDown", function() lib.Select(e) end)
	s:SetScript("OnDragStart", function()
		lib.Select(e)
		frame:StartMoving()
		lib.Preview(frame)
	end)
	s:SetScript("OnDragStop", function()
		lib.StopPreview()
		frame:StopMovingOrSizing()
		if frame.SetUserPlaced then frame:SetUserPlaced(false) end
		local dx, dy = lib.SnapMove(frame)
		local x, y = frame:GetLeft(), frame:GetTop()
		frame:ClearAllPoints()
		frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x + dx, y + dy)
		Placed(e)
		lib.Changed(e)
	end)
	s:SetScript("OnEnter", function() s.hover:Show() end)
	s:SetScript("OnLeave", function() s.hover:Hide() end)

	local r = e.resize
	if r then
		frame:SetResizable(true)
		Bounds(frame, r)
		local grip = CreateFrame("Button", nil, s)
		s.grip = grip
		grip:SetSize(16, 16)
		grip:SetPoint("BOTTOMRIGHT", -2, 2)
		grip:SetFrameLevel(s:GetFrameLevel() + 5)
		grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
		grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
		grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
		local function Size()
			Call(e.Sizing, Clamp(frame:GetWidth(), r[1], r[3]), Clamp(frame:GetHeight(), r[2], r[4]))
		end
		grip:SetScript("OnMouseDown", function()
			Placed(e) -- sized from its top left
			grip.sizing = true
			frame:StartSizing("BOTTOMRIGHT")
			grip:SetScript("OnUpdate", Size)
			lib.Preview(frame, true)
		end)
		grip:SetScript("OnMouseUp", function()
			if not grip.sizing then return end
			grip.sizing = false
			grip:SetScript("OnUpdate", nil)
			lib.StopPreview()
			frame:StopMovingOrSizing()
			local dw, dh = lib.SnapSize(frame)
			frame:SetSize(frame:GetWidth() + dw, frame:GetHeight() - dh)
			Size()
			Placed(e)
			lib.Changed(e)
		end)
	end
	s:Hide()
end

---------------------------------------------------------------------------
-- The selected element's settings, like the game's
---------------------------------------------------------------------------
function lib.RefreshDialog()
	local d, e = lib.dialog, lib.selected
	if not (d and e and d.form) then return end
	d.loading = true
	for _, c in ipairs(d.form.controls) do c.Refresh() end
	d.loading = false
	d.form.revert:SetEnabled(e.dirty == true)
	if d.form.reset then d.form.reset:SetEnabled(not (e.IsDefault and e.IsDefault())) end
end

-- Laid out as the game's (EditModeSystemSettingsDialog): its title, a row per
-- setting (label, slider), then Revert Changes, a divider and Reset To Default
-- Position.
local ROW_W, ROW_H, PAD = 343, 32, 20

local function DialogButton(parent, width, text, onClick)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 28)
	b:SetText(text)
	b:SetScript("OnClick", onClick)
	return b
end

local function MakeForm(d, e)
	local form = CreateFrame("Frame", nil, d)
	form:SetAllPoints()
	form.controls = {}
	local y = -15 - math.ceil(d.title:GetStringHeight() > 0 and d.title:GetStringHeight() or 17) - 12
	for _, c in ipairs(e.settings or {}) do
		local row = CreateFrame("Frame", nil, form)
		row:SetSize(ROW_W, ROW_H)
		row:SetPoint("TOPLEFT", PAD, y)
		local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightMedium")
		label:SetSize(100, ROW_H)
		label:SetJustifyH("LEFT")
		label:SetPoint("LEFT")
		label:SetText(c.label)
		local s = CreateFrame("Frame", nil, row, "MinimalSliderWithSteppersTemplate")
		s:SetSize(200, ROW_H)
		s:SetPoint("LEFT", label, "RIGHT", 5, 0)
		local right = MinimalSliderWithSteppersMixin.Label.Right
		local formatters = { [right] = CreateMinimalSliderFormatter(right, c.format) }
		s:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_, value)
			if d.loading then return end
			value = c.min + math.floor((value - c.min) / c.step + 0.5) * c.step
			if c.get() ~= value then
				Call(c.set, value)
				lib.Changed(e)
			end
		end, s)
		form.controls[#form.controls + 1] = {
			Refresh = function() s:Init(c.get(), c.min, c.max, (c.max - c.min) / c.step, formatters) end,
		}
		y = y - ROW_H - 2
	end
	y = y - 12 + 2
	-- Its unsaved changes back as saved.
	form.revert = DialogButton(form, 180, HUD_EDIT_MODE_REVERT_CHANGES or "Revert Changes", function()
		if not e.dirty then return end
		e.dirty = false
		Call(e.SetState, Copy(e.saved))
		lib.SyncButtons()
		lib.RefreshDialog()
	end)
	form.revert:SetPoint("TOPLEFT", PAD, y)
	y = y - 28 - 2
	if e.Default then
		local divider = form:CreateTexture(nil, "ARTWORK")
		divider:SetTexture("Interface\\FriendsFrame\\UI-FriendsFrame-OnlineDivider")
		divider:SetSize(330, 16)
		divider:SetPoint("TOPLEFT", PAD, y)
		y = y - 16 - 2
		form.reset = DialogButton(form, 330, HUD_EDIT_MODE_RESET_POSITION or "Reset To Default Position", function()
			Call(e.Default)
			lib.Changed(e)
		end)
		form.reset:SetPoint("TOPLEFT", PAD, y)
		y = y - 28
	end
	form.height = -y + PAD
	return form
end

function lib.ShowDialog(e)
	local d = lib.dialog
	if not d then
		d = CreateFrame("Frame", "FireEditModeDialog", UIParent)
		lib.dialog = d
		d:SetFrameStrata("DIALOG")
		d:SetFrameLevel(200)
		d:SetClampedToScreen(true)
		d:SetMovable(true)
		d:EnableMouse(true)
		d:RegisterForDrag("LeftButton")
		d:SetScript("OnDragStart", d.StartMoving)
		d:SetScript("OnDragStop", d.StopMovingOrSizing)
		local ok, border = pcall(CreateFrame, "Frame", nil, d, "DialogBorderTranslucentTemplate")
		if not ok then
			border = CreateFrame("Frame", nil, d, "BackdropTemplate")
			border:SetBackdrop(BACKDROP)
		end
		border:SetAllPoints()
		d.title = d:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
		d.title:SetPoint("TOP", 0, -15)
		local close = CreateFrame("Button", nil, d, "UIPanelCloseButton")
		close:SetPoint("TOPRIGHT")
		close:SetScript("OnClick", function() lib.Deselect() end)
		d:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -250, 200) -- where the game puts its own
		d.forms = {}
	end
	d.title:SetText(e.label)
	for _, form in pairs(d.forms) do form:Hide() end
	d.forms[e] = d.forms[e] or MakeForm(d, e)
	d.form = d.forms[e]
	d:SetSize(ROW_W + 2 * PAD, d.form.height)
	d.form:Show()
	lib.RefreshDialog()
	d:Show()
end

---------------------------------------------------------------------------
-- On or off: a box under the Edit Mode window (under FireMove's, if shown)
---------------------------------------------------------------------------
function lib.UpdateBox()
	local list = {}
	for _, e in ipairs(lib.elements) do
		if e.Toggle then list[#list + 1] = e end
	end
	local box = lib.box
	if #list == 0 then
		if box then box:Hide() end
		return
	end
	if not box then
		box = CreateFrame("Frame", "FireEditModeBox", UIParent, "BackdropTemplate")
		lib.box = box
		box:SetFrameStrata("DIALOG")
		box:SetBackdrop(BACKDROP)
		box.rows = {}
	end
	for i, e in ipairs(list) do
		local check = box.rows[i]
		if not check then
			check = CreateFrame("CheckButton", nil, box, "UICheckButtonTemplate")
			check:SetSize(30, 30)
			check:SetPoint("TOPLEFT", 12, -6 - (i - 1) * 30)
			check.label = box:CreateFontString(nil, "ARTWORK", "GameFontHighlightMedium")
			check.label:SetPoint("LEFT", check, "RIGHT", 4, 0)
			check:SetScript("OnClick", function(self)
				local el = self.element
				Call(el.Toggle.set, self:GetChecked() and true or false)
				if not Shown(el) and lib.selected == el then lib.Deselect() end
				lib.Paint()
			end)
			-- Like the game's: hovering it lights up the element.
			check:SetScript("OnEnter", function(self)
				local s = self.element.selection
				if s and s:IsShown() then s.hover:Show() end
			end)
			check:SetScript("OnLeave", function(self)
				local s = self.element.selection
				if s then s.hover:Hide() end
			end)
			box.rows[i] = check
		end
		check.element = e
		check.label:SetText(e.label)
		check:SetChecked(Shown(e))
		check:Show()
	end
	for i = #list + 1, #box.rows do box.rows[i]:Hide() end
	box:SetSize(220, 12 + #list * 30)
	box:Show()
	C_Timer.After(0, lib.PlaceBox) -- once FireMove's box is in place
end

function lib.PlaceBox()
	local box = lib.box
	if not box then return end
	local m, above = Manager(), _G.FireMoveNewBarBox
	box:ClearAllPoints()
	if above and above:IsShown() then
		box:SetPoint("TOP", above, "BOTTOM", 0, -2)
	elseif m then
		box:SetPoint("TOP", m, "BOTTOM", 0, -2)
	end
end

---------------------------------------------------------------------------
-- Entering and leaving Edit Mode
---------------------------------------------------------------------------
function lib.SetEditing(on)
	lib.editing = on
	if lib.ask and on then lib.ask:Hide() end
	if on then
		for _, e in ipairs(lib.elements) do
			if not e.selection then lib.MakeSelection(e) end
		end
		lib.UpdateBox()
	else
		lib.StopPreview()
		lib.Deselect()
		if lib.box then lib.box:Hide() end
	end
	for _, e in ipairs(lib.elements) do Call(e.Editing, on) end
	lib.Paint()
end

function lib.Register(def)
	local e = def
	e.saved = Copy(e.GetState())
	e.dirty = false
	local at = #lib.elements + 1
	for i, old in ipairs(lib.elements) do
		if old.name == e.name then -- registered again: this one instead
			at = i
			if old.selection then old.selection:Hide() end
		end
	end
	lib.elements[at] = e
	if lib.editing then
		lib.MakeSelection(e)
		lib.UpdateBox()
		Call(e.Editing, true)
		lib.Paint()
	end
	return e
end

function lib.Hook()
	local m = Manager()
	-- The Revert All Changes button calls the game's own function directly
	-- (bound when Edit Mode loaded), not through the hook below: its click too.
	-- (Reverting twice does nothing more.)
	if m and m.RevertAllChangesButton and not lib.revertButtonHooked then
		lib.revertButtonHooked = true
		m.RevertAllChangesButton:HookScript("OnClick", function() lib.Reverted() end)
	end
	if lib.hooked or not m then return end
	lib.hooked = true
	-- (Through lib, so a newer copy's code is the one that runs.)
	if m.SelectSystem then hooksecurefunc(m, "SelectSystem", function() lib.Deselect() end) end
	if m.RevertAllChanges then hooksecurefunc(m, "RevertAllChanges", function() lib.Reverted() end) end
	if m.SaveLayouts then hooksecurefunc(m, "SaveLayouts", function() lib.Commit() end) end
	-- The game turns its Save and Revert buttons off when it has nothing unsaved: on again for ours.
	if m.SetHasActiveChanges then hooksecurefunc(m, "SetHasActiveChanges", function() lib.SyncButtons() end) end
	if m.IsEditModeActive and m:IsEditModeActive() then lib.SetEditing(true) end
end

if not lib.events then
	if EventRegistry then
		EventRegistry:RegisterCallback("EditMode.Enter", function() lib.SetEditing(true) end, lib)
		EventRegistry:RegisterCallback("EditMode.Exit", function() lib.SetEditing(false) end, lib)
	end
	lib.events = CreateFrame("Frame")
	lib.events:RegisterEvent("ADDON_LOADED")
	lib.events:RegisterEvent("PLAYER_LOGIN")
	pcall(lib.events.RegisterEvent, lib.events, "GLOBAL_MOUSE_DOWN")
	lib.events:SetScript("OnEvent", function(_, event, addon)
		if event == "GLOBAL_MOUSE_DOWN" then
			-- A click anywhere else lets go of it.
			local e = lib.selected
			if e and not (e.selection:IsMouseOver() or (lib.dialog and lib.dialog:IsMouseOver())
				or (lib.box and lib.box:IsMouseOver())) then
				lib.Deselect()
			end
		elseif event == "PLAYER_LOGIN" or addon == "Blizzard_EditMode" then
			lib.Hook()
		end
	end)
end
