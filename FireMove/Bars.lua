-- Extra action bars. In Edit Mode, "New action bar" (under the Edit Mode
-- window) adds a bar made like the game's own: the game's bar and button
-- look, working the same (Buttons.lua: drag spells on, cooldowns, range, keys
-- set in Quick Keybind mode). Each takes 12 action slots no other bar or stance
-- uses; the game has only so many, so the button greys out when none are left.
--
-- In Edit Mode a bar shows like the game's: click it for its settings, drag
-- it to move it (it lines up with bars it's dropped near). Its settings and
-- place are kept with the Edit Mode layout, as the game keeps its bars'.
-- Which bars a character has (and their slots) is the character's own.
-- Like the game's, changes wait for Edit Mode's Save (FireMove.lua).
-- Nothing changes during combat: then once it ends.
local _, ns = ...

local FIRST = 9 -- after the game's eight: Action Bar 9, 10...
-- Pages (12 slots each) no bar of the game's shows, in the order they're
-- used. Some classes' stances and forms take over 7-10.
local PAGES = { 7, 8, 9, 10, 12, 11 }
local STANCES = { WARRIOR = { 7, 8, 9 }, DRUID = { 7, 8, 9, 10 }, ROGUE = { 7, 8 }, PRIEST = { 7 } }
local DEFAULTS = {
	horizontal = true, rows = 1, icons = 12, size = 100, padding = 2, visibility = "Always", showAll = false,
	style = "main", -- the buttons' frames: the main bar's thick ones, or the other bars' thin ones
}
local ORIENTATION = { { true, "Horizontal" }, { false, "Vertical" } }
local STYLES = { { "main", "Main Action Bar" }, { "other", "Other Action Bars" } }
local VISIBILITY = {
	{ "Always", "Always Visible" }, { "InCombat", "In Combat" }, { "OutOfCombat", "Out of Combat" }, { "Hidden", "Hidden" },
}
local DRIVER = { Always = "show", InCombat = "[combat] show; hide", OutOfCombat = "[combat] hide; show", Hidden = "hide" }
-- Why empty buttons show: the game's reasons, and ours.
local GRID_ALWAYS = ACTION_BUTTON_SHOW_GRID_REASON_CVAR or 1
local GRID_DRAG = ACTION_BUTTON_SHOW_GRID_REASON_EVENT or 2
local GRID_EDIT, GRID_BIND = 0x100, 0x200
local SNAP = 10 -- a bar dropped this near another lines up with it
local BLIZZARD_BARS = {
	"MainActionBar", "MultiBarBottomLeft", "MultiBarBottomRight", "MultiBarRight", "MultiBarLeft",
	"MultiBar5", "MultiBar6", "MultiBar7", "StanceBar", "PetActionBar",
}
-- The game's look for a frame in Edit Mode.
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

local CDB           -- FireMoveBarsChar: { [bar] = page }
local bars = {}     -- [bar] = frame, once made (a deleted one is kept, hidden)
local editing, binding, dragging
local selected      -- the bar whose settings are open
local pending       -- changes waiting for combat to end
local loading       -- filling in the settings: not a change
local dialog, newBox

local function Locked() return InCombatLockdown and InCombatLockdown() end
local function Live(n) return CDB ~= nil and CDB[n] ~= nil end

---------------------------------------------------------------------------
-- Settings, kept with the layout
---------------------------------------------------------------------------

local function Store(create)
	local all = FireMoveLayers and FireMoveLayers.bars
	if not all then return end
	local key = ns.Layout and ns.Layout() or "none"
	if create then all[key] = all[key] or {} end
	return all[key]
end

local function Get(n, key)
	local store = Store()
	local value = store and store[n] and store[n][key]
	if value == nil then return DEFAULTS[key] end
	return value
end

local Apply

local function Set(n, key, value)
	local store = Store(true)
	if not store then return end
	store[n] = store[n] or {}
	store[n][key] = value
	Apply(n)
	ns.Changed()
	if dialog and dialog.revert then dialog.revert:SetEnabled(ns.BarChanged(n)) end
end

-- The settings that differ from the saved ones.
local function Same(a, b)
	if type(a) ~= "table" or type(b) ~= "table" then return a == b end
	for k, v in pairs(a) do if not Same(v, b[k]) then return false end end
	for k in pairs(b) do if a[k] == nil then return false end end
	return true
end

function ns.BarChanged(n)
	local saved = ns.SavedBar and ns.SavedBar(n) or {}
	for key in pairs(DEFAULTS) do
		local was = saved[key]
		if was == nil then was = DEFAULTS[key] end
		if not Same(Get(n, key), was) then return true end
	end
	return not Same(Get(n, "pos"), saved.pos)
end

-- This bar's settings back as saved.
local function RevertBar(n)
	local store = Store(true)
	if not store then return end
	local saved = ns.SavedBar and ns.SavedBar(n)
	if saved then
		store[n] = {}
		for k, v in pairs(saved) do store[n][k] = type(v) == "table" and { unpack(v) } or v end
	else
		store[n] = nil
	end
	Apply(n)
end

-- The character's bars (FireMove.lua keeps a saved copy, and puts it back).
function ns.CharBars() return CDB end
function ns.SetCharBars(t)
	if not CDB then return end
	wipe(CDB)
	for n, page in pairs(t) do CDB[n] = page end
end

-- The next 12 slots no bar or stance uses, or nil.
local function FreePage()
	if not CDB then return end
	local taken = {}
	local _, class = UnitClass("player")
	for _, page in ipairs(STANCES[class] or {}) do taken[page] = true end
	local api = C_ActionBar or {}
	for _, name in ipairs({ "GetVehicleBarIndex", "GetOverrideBarIndex", "GetTempShapeshiftBarIndex" }) do
		if api[name] then
			local ok, page = pcall(api[name])
			if ok and page then taken[page] = true end
		end
	end
	for _, page in pairs(CDB) do taken[page] = true end
	for _, page in ipairs(PAGES) do
		if not taken[page] then return page end
	end
end

---------------------------------------------------------------------------
-- Bars
---------------------------------------------------------------------------

-- Empty buttons show while any reason holds.
local function Grid(bar, reason, on)
	for _, b in ipairs(bar.actionButtons) do
		local value = b:GetAttribute("showgrid") or 0
		value = on and bit.bor(value, reason) or bit.band(value, bit.bnot(reason))
		if value ~= b:GetAttribute("showgrid") then b:SetAttribute("showgrid", value) end
	end
end

local function Grids(bar)
	local n = bar.n
	Grid(bar, GRID_ALWAYS, Get(n, "showAll"))
	Grid(bar, GRID_DRAG, dragging)
	Grid(bar, GRID_EDIT, editing)
	Grid(bar, GRID_BIND, binding)
	bar:UpdateShownButtons()
	bar.oldGridSettings = nil
	bar:UpdateGridLayout()
end

-- The game's, but never during combat (showing a button is blocked then).
local function UpdateShownButtons(bar)
	if Locked() then
		pending = true
		return
	end
	ActionBarMixin.UpdateShownButtons(bar)
end

-- The main bar's dividers between buttons, as it draws them: one row, no
-- extra padding, its look.
local function UpdateDividers(bar)
	if not bar.dividers then
		local ok, horizontal = pcall(CreateFramePool, "FRAME", bar, "HorizontalDividerTemplate")
		local ok2, vertical = pcall(CreateFramePool, "FRAME", bar, "VerticalDividerTemplate")
		if not (ok and ok2) then return end
		bar.dividers = { horizontal = horizontal, vertical = vertical }
	end
	-- Only redrawn when what they depend on changed.
	local key = { tostring(bar.hideBarArt), bar.numRows, bar.buttonPadding, tostring(bar.isHorizontal) }
	for _, b in ipairs(bar.actionButtons) do key[#key + 1] = b:IsShown() and "1" or "0" end
	key = table.concat(key, ",")
	if key == bar.dividerKey then return end
	bar.dividerKey = key
	local pools = bar.dividers
	pools.horizontal:ReleaseAll()
	pools.vertical:ReleaseAll()
	if bar.hideBarArt or bar.numRows > 1 or bar.buttonPadding > bar.minButtonPadding then return end
	local pool = bar.isHorizontal and pools.horizontal or pools.vertical
	local lastShown = false
	for _, b in ipairs(bar.actionButtons) do
		if b:IsShown() then
			if lastShown then
				local divider = pool:Acquire()
				divider:ClearAllPoints()
				if bar.isHorizontal then
					divider:SetPoint("TOP", b, "TOP", 0, 0)
					divider:SetPoint("BOTTOM", b, "BOTTOM", 0, 0)
					divider:SetPoint("RIGHT", b, "LEFT", 5, 0)
				else
					divider:SetPoint("LEFT", b, "LEFT", 0, 0)
					divider:SetPoint("RIGHT", b, "RIGHT", 0, 0)
					divider:SetPoint("BOTTOM", b, "TOP", 0, -5)
				end
				divider:Show()
			end
			lastShown = true
		else
			lastShown = false
		end
	end
end

local function Paint(bar)
	local s = bar.FireSelection
	local on = editing and Live(bar.n)
	s:SetShown(on)
	if not on then return end
	local kit = selected == bar.n and "editmode-actionbar-selected" or "editmode-actionbar-highlight"
	if s.kit ~= kit then
		NineSliceUtil.ApplyLayout(s, SELECTION, kit)
		s.kit = kit
	end
	s.label:SetText("Action Bar " .. bar.n)
	if s.label.SetRotation then s.label:SetRotation(bar.isHorizontal and 0 or math.pi / 2) end
end

local function Place(n)
	local bar, pos = bars[n], Get(n, "pos")
	bar:ClearAllPoints()
	if pos then
		bar:SetPoint("CENTER", UIParent, "CENTER", pos[1], pos[2])
	else
		bar:SetPoint("CENTER", UIParent, "CENTER", 0, 150 - (n - FIRST) * 50)
	end
end

function Apply(n)
	local bar = bars[n]
	if not bar then return end
	if Locked() then
		pending = true
		return
	end
	if not Live(n) then
		UnregisterStateDriver(bar, "visibility")
		bar:Hide()
		Paint(bar)
		return
	end
	local page = CDB[n]
	bar:SetAttribute("actionpage", page)
	for _, b in ipairs(bar.actionButtons) do
		if b:GetAttribute("actionpage") ~= page then b:SetAttribute("actionpage", page) end
	end
	bar.isHorizontal = Get(n, "horizontal")
	bar.addButtonsToRight = true
	bar.addButtonsToTop = bar.isHorizontal
	bar.numRows = Get(n, "rows")
	bar.numButtonsShowable = Get(n, "icons")
	bar.buttonPadding = Get(n, "padding")
	local scale = Get(n, "size") / 100
	for _, b in ipairs(bar.actionButtons) do b.container:SetScale(scale) end
	-- The main bar's look (its buttons' frames, the frame behind them, the
	-- dividers between them), or the other bars'.
	local style = Get(n, "style")
	bar.hideBarArt = style == "other"
	for _, b in ipairs(bar.actionButtons) do ns.SetButtonStyle(b, style) end
	bar.BorderArt:SetShown(not bar.hideBarArt)
	bar.BorderArt:SetScale(scale)
	Grids(bar)
	if not dragging and bar:GetFrameStrata() == "TOOLTIP" then bar:UpdateFrameStrata(false) end
	Place(n)
	if ns.Attach and ns.Attach.Of(bar) then ns.Attach.Apply() end
	if editing then
		UnregisterStateDriver(bar, "visibility")
		bar:Show()
	else
		RegisterStateDriver(bar, "visibility", DRIVER[Get(n, "visibility")] or "show")
	end
	Paint(bar)
end

-- How far to move a dropped bar to line it up with one it's near: side by
-- side (touching, tops or bottoms even) or stacked (touching, edges even).
local function Snap(bar)
	local l, b, w, h = bar:GetRect()
	if not l then return 0, 0 end
	local r, t = l + w, b + h
	local bestX, bestY
	local function Try(best, d)
		if math.abs(d) < SNAP and (not best or math.abs(d) < math.abs(best)) then return d end
		return best
	end
	local targets = {}
	for n, other in pairs(bars) do
		if other ~= bar and Live(n) then targets[#targets + 1] = other end
	end
	for _, name in ipairs(BLIZZARD_BARS) do
		local f = _G[name]
		if f and f.IsVisible and f:IsVisible() then targets[#targets + 1] = f end
	end
	for _, f in ipairs(targets) do
		local fl, fb, fw, fh = f:GetRect()
		if fl then
			local k = f:GetEffectiveScale() / bar:GetEffectiveScale()
			fl, fb, fw, fh = fl * k, fb * k, fw * k, fh * k
			local fr, ft = fl + fw, fb + fh
			if b < ft + SNAP and t > fb - SNAP then -- side by side
				bestX = Try(Try(bestX, fr - l), fl - r)
				bestY = Try(Try(bestY, fb - b), ft - t)
			end
			if l < fr + SNAP and r > fl - SNAP then -- stacked
				bestY = Try(Try(bestY, ft - b), fb - t)
				bestX = Try(Try(bestX, fl - l), fr - r)
			end
		end
	end
	return bestX or 0, bestY or 0
end

local function Dropped(bar)
	if ns.Attach then ns.Attach.Detach(bar, true) end
	local dx, dy = Snap(bar)
	local x, y = bar:GetCenter()
	local ux, uy = UIParent:GetCenter()
	if not (x and ux) then return end
	Set(bar.n, "pos", { math.floor(x - ux + dx + 0.5), math.floor(y - uy + dy + 0.5) })
end

local Select

local function MakeSelection(bar)
	local s = CreateFrame("Frame", nil, bar, "NineSliceCodeTemplate")
	s:SetAllPoints()
	s:SetFrameLevel(bar:GetFrameLevel() + 50)
	if s.SetIgnoreParentAlpha then s:SetIgnoreParentAlpha(true) end
	s:EnableMouse(true)
	s:RegisterForDrag("LeftButton")
	s.hover = CreateFrame("Frame", nil, s, "NineSliceCodeTemplate")
	s.hover:SetAllPoints()
	NineSliceUtil.ApplyLayout(s.hover, SELECTION, "editmode-actionbar-highlight")
	s.hover:SetAlpha(0.4)
	if s.hover.SetBlendMode then s.hover:SetBlendMode("ADD") end
	s.hover:Hide()
	s.label = s:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
	s.label:SetPoint("CENTER")
	s:SetScript("OnMouseDown", function() Select(bar.n) end)
	s:SetScript("OnDragStart", function()
		if Locked() then return end
		Select(bar.n)
		bar:StartMoving()
	end)
	s:SetScript("OnDragStop", function()
		bar:StopMovingOrSizing()
		Dropped(bar)
	end)
	s:SetScript("OnEnter", function() s.hover:Show() end)
	s:SetScript("OnLeave", function() s.hover:Hide() end)
	s:Hide()
	bar.FireSelection = s
end

local function Make(n)
	if bars[n] then return bars[n] end
	local bar = CreateFrame("Frame", "FireMoveBar" .. n, UIParent, "FireMoveBarTemplate")
	bar.n = n
	bar.UpdateShownButtons = UpdateShownButtons
	bar.UpdateDividers = UpdateDividers
	-- The frame behind the main bar's buttons, as it has it.
	bar.BorderArt = bar:CreateTexture(nil, "BACKGROUND", nil, -3)
	bar.BorderArt:SetAtlas("UI-HUD-ActionBar-Frame")
	bar.BorderArt.ignoreInLayout = true
	bar.BorderArt:SetPoint("TOPLEFT", bar, "TOPLEFT", -6, 6)
	bar.BorderArt:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 4, -5)
	bar:SetMovable(true)
	bar:SetClampedToScreen(true)
	if bar.SetDontSavePosition then bar:SetDontSavePosition(true) end
	for _, b in ipairs(bar.actionButtons) do ns.SetupButton(b) end
	MakeSelection(bar)
	bars[n] = bar
	return bar
end

---------------------------------------------------------------------------
-- The settings dialog (like the game's for its bars)
---------------------------------------------------------------------------

local controls = {}

local function RefreshDialog()
	if not (dialog and selected) then return end
	loading = true
	dialog.title:SetText("Action Bar " .. selected)
	for _, c in ipairs(controls) do c.Refresh() end
	dialog.revert:SetEnabled(ns.BarChanged(selected))
	if ns.Attach then ns.Attach.Refresh() end
	loading = false
end

local function Label(text, y)
	local fs = dialog:CreateFontString(nil, "ARTWORK", "GameFontHighlightMedium")
	fs:SetSize(110, 32)
	fs:SetJustifyH("LEFT")
	fs:SetPoint("TOPLEFT", 20, y)
	fs:SetText(text)
	return fs
end

local function Dropdown(text, y, key, options)
	local dd = CreateFrame("DropdownButton", nil, dialog, "WowStyle1DropdownTemplate")
	dd:SetWidth(225)
	dd:SetPoint("LEFT", Label(text, y), "RIGHT", 5, 0)
	dd:SetupMenu(function(_, root)
		for _, option in ipairs(options) do
			root:CreateRadio(option[2],
				function() return selected ~= nil and Get(selected, key) == option[1] end,
				function() if selected then Set(selected, key, option[1]) end end)
		end
	end)
	controls[#controls + 1] = { Refresh = function() dd:GenerateMenu() end }
end

local function Slider(text, y, key, min, max, step, format)
	local s = CreateFrame("Frame", nil, dialog, "MinimalSliderWithSteppersTemplate")
	s:SetSize(200, 32)
	s:SetPoint("LEFT", Label(text, y), "RIGHT", 5, 0)
	local right = MinimalSliderWithSteppersMixin.Label.Right
	local formatters = { [right] = CreateMinimalSliderFormatter(right, format) }
	s:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_, value)
		if loading or not selected then return end
		value = min + math.floor((value - min) / step + 0.5) * step
		if Get(selected, key) ~= value then Set(selected, key, value) end
	end, s)
	controls[#controls + 1] = {
		Refresh = function() s:Init(Get(selected, key), min, max, (max - min) / step, formatters) end,
	}
end

local function DialogButton(text, y, onClick)
	local b = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
	b:SetSize(330, 22)
	b:SetPoint("TOP", 0, y)
	b:SetText(text)
	b:SetScript("OnClick", onClick)
	return b
end

local function Checkbox(text, y, key)
	local check = CreateFrame("CheckButton", nil, dialog, "UICheckButtonTemplate")
	check:SetSize(32, 32)
	check:SetPoint("TOPLEFT", 16, y)
	local label = dialog:CreateFontString(nil, "ARTWORK", "GameFontHighlightMedium")
	label:SetPoint("LEFT", check, "RIGHT", 5, 0)
	label:SetText(text)
	check:SetScript("OnClick", function(self)
		if selected then Set(selected, key, self:GetChecked() and true or false) end
	end)
	controls[#controls + 1] = { Refresh = function() check:SetChecked(Get(selected, key)) end }
end

local Deselect, Delete

local function CreateDialog()
	dialog = CreateFrame("Frame", "FireMoveBarDialog", UIParent)
	dialog:SetSize(380, 486)
	dialog:SetFrameStrata("DIALOG")
	dialog:SetFrameLevel(200)
	dialog:SetClampedToScreen(true)
	dialog:SetMovable(true)
	dialog:EnableMouse(true)
	dialog:RegisterForDrag("LeftButton")
	dialog:SetScript("OnDragStart", dialog.StartMoving)
	dialog:SetScript("OnDragStop", dialog.StopMovingOrSizing)
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
	close:SetScript("OnClick", function() Deselect() end)

	Dropdown("Orientation", -40, "horizontal", ORIENTATION)
	Slider("# of Rows", -74, "rows", 1, 4, 1)
	Slider("# of Icons", -108, "icons", 1, 12, 1)
	Slider("Icon Size", -142, "size", 50, 200, 10, function(v) return ("%d%%"):format(v) end)
	Slider("Icon Padding", -176, "padding", 2, 10, 1)
	Dropdown("Bar Visible", -210, "visibility", VISIBILITY)

	Dropdown("Button Style", -246, "style", STYLES)
	Checkbox("Always Show Buttons", -280, "showAll")

	dialog.revert = DialogButton("Revert Changes", -326, function()
		if selected then
			RevertBar(selected)
			RefreshDialog()
		end
	end)
	DialogButton("Reset To Default Position", -356, function()
		if selected then Set(selected, "pos", nil) end
	end)
	DialogButton("Delete Bar", -386, function()
		if selected then Delete(selected) end
	end)
	if ns.Attach then
		local row = ns.Attach.CreateRow(dialog, function() return selected and bars[selected] end, 330)
		row:SetPoint("TOP", 0, -418)
	end
	dialog:Hide()
end

local function ShowDialog()
	if not dialog then CreateDialog() end
	if not dialog.placed then
		dialog:ClearAllPoints()
		dialog:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -250, 200) -- where the game puts its own
		dialog.placed = true
	end
	RefreshDialog()
	dialog:Show()
end

function Select(n)
	if not editing then return end
	if selected ~= n then
		selected = n
		-- The game's selection (and its settings) closes: one at a time.
		local manager, theirs = EditModeManagerFrame, EditModeSystemSettingsDialog
		if manager and manager.ClearSelectedSystem and theirs and theirs:IsShown() then
			manager:ClearSelectedSystem()
		end
		for _, bar in pairs(bars) do Paint(bar) end
	end
	ShowDialog()
end

function Deselect()
	if dialog then dialog:Hide() end
	if not selected then return end
	selected = nil
	for _, bar in pairs(bars) do Paint(bar) end
end

---------------------------------------------------------------------------
-- New and deleted bars
---------------------------------------------------------------------------

local function UpdateNewBox()
	if not newBox then return end
	newBox:SetShown(editing == true)
	newBox.button:SetEnabled(not Locked() and FreePage() ~= nil)
end

local function NewBar()
	if Locked() or not CDB then return end
	local page = FreePage()
	if not page then return end
	local n = FIRST
	while CDB[n] do n = n + 1 end
	CDB[n] = page
	Make(n)
	Apply(n)
	Select(n)
	UpdateNewBox()
	ns.Changed()
end

-- Its slots keep what's on them: a new bar gets them back.
function Delete(n)
	if Locked() or not Live(n) then return end
	CDB[n] = nil
	Deselect()
	Apply(n)
	UpdateNewBox()
	ns.Changed()
end

local function CreateNewBox()
	local manager = EditModeManagerFrame
	if newBox or not manager then return end
	newBox = CreateFrame("Frame", "FireMoveNewBarBox", UIParent, "BackdropTemplate")
	newBox:SetSize(200, 40)
	newBox:SetFrameStrata("DIALOG")
	newBox:SetPoint("TOP", manager, "BOTTOM", 0, -2)
	newBox:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	local b = CreateFrame("Button", nil, newBox, "UIPanelButtonTemplate")
	b:SetSize(176, 22)
	b:SetPoint("CENTER")
	b:SetText("New action bar")
	b:SetMotionScriptsWhileDisabled(true)
	b:SetScript("OnClick", NewBar)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:SetText(self:IsEnabled() and "Another action bar" or "No free action slots left", 1, 1, 1)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	newBox.button = b
	newBox:Hide()
end

---------------------------------------------------------------------------
-- Keeping up
---------------------------------------------------------------------------

local function ApplyAll()
	if not CDB then return end
	if Locked() then
		pending = true
		return
	end
	pending = false
	if selected and not Live(selected) then Deselect() end
	for n in pairs(CDB) do Make(n) end
	for n in pairs(bars) do Apply(n) end
	if dialog and dialog:IsShown() then RefreshDialog() end
	UpdateNewBox()
end
ns.LayoutChanged = ApplyAll

-- The extra bars there are (for attaching one element to another, Attach.lua).
function ns.BarFrames()
	local list = {}
	for n, bar in pairs(bars) do
		if Live(n) then list[#list + 1] = bar end
	end
	return list
end

local function SetEditing(on)
	editing = on
	if not on then Deselect() end
	ApplyAll()
end

-- Quick Keybind mode: their buttons light up, and take keys (Buttons.lua).
local function SetBinding(on)
	binding = on
	ns.SetBindMode(on)
	ApplyAll()
end

-- Dragging a spell: empty buttons show (and the bars come forward, as the game's).
local function SetDragging(on)
	dragging = on
	if Locked() then
		pending = true
		return
	end
	for n, bar in pairs(bars) do
		if Live(n) then
			Grids(bar)
			bar:UpdateFrameStrata(on, GRID_DRAG)
		end
	end
end

local hooked
local function HookEditMode()
	local manager = EditModeManagerFrame
	if hooked or not manager then return end
	hooked = true
	CreateNewBox()
	if manager.SelectSystem then hooksecurefunc(manager, "SelectSystem", function() Deselect() end) end
	if manager.IsEditModeActive and manager:IsEditModeActive() then SetEditing(true) end
end

if EventRegistry then
	EventRegistry:RegisterCallback("EditMode.Enter", function() SetEditing(true) end, {})
	EventRegistry:RegisterCallback("EditMode.Exit", function() SetEditing(false) end, {})
	EventRegistry:RegisterCallback("QuickKeybindFrame.QuickKeybindModeEnabled", function() SetBinding(true) end, {})
	EventRegistry:RegisterCallback("QuickKeybindFrame.QuickKeybindModeDisabled", function() SetBinding(false) end, {})
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("ACTIONBAR_SHOWGRID")
events:RegisterEvent("ACTIONBAR_HIDEGRID")
events:SetScript("OnEvent", function(_, event, addon)
	if event == "ADDON_LOADED" then
		if addon == "FireMove" then
			FireMoveBarsChar = FireMoveBarsChar or {}
			CDB = FireMoveBarsChar
		elseif addon == "Blizzard_EditMode" then
			HookEditMode()
		end
	elseif event == "PLAYER_LOGIN" then
		HookEditMode()
		ApplyAll()
	elseif event == "PLAYER_REGEN_ENABLED" then
		if pending then ApplyAll() end
		UpdateNewBox()
	elseif event == "ACTIONBAR_SHOWGRID" then
		SetDragging(true)
	elseif event == "ACTIONBAR_HIDEGRID" then
		SetDragging(false)
	end
end)
