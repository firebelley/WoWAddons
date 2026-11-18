-- The main bar's look for the game's other action bars (2-8): in Edit Mode,
-- "Button Style" in the box under a bar's settings - "Main Action Bar" (the
-- thick button frames, the frame behind them, the dividers between them) or
-- "Other Action Bars" (the game's own for them). Kept with the Edit Mode
-- layout, like layers (FireMove.lua: Save, Revert).
--
-- Only the buttons' textures are changed. The frame behind and the dividers
-- are ours, beside the bar rather than in it: the game lays out what's in
-- its bars, and anything of ours in there would taint that.
local _, ns = ...

local Style = {}
ns.Style = Style

local BARS = {
	MultiBarBottomLeft = true, MultiBarBottomRight = true, MultiBarRight = true, MultiBarLeft = true,
	MultiBar5 = true, MultiBar6 = true, MultiBar7 = true,
}
local STYLES = { { "main", "Main Action Bar" }, { "other", "Other Action Bars" } }

local art = {}     -- [bar] = { frame (behind it), pools (dividers) }
local touched = {} -- [bar] = true: styled this session (so "other" is put back on it)
local hooked = {}
local rows = {}
local soon

local function Store(create)
	local all = FireMoveLayers and FireMoveLayers.style
	if not all then return end
	local key = ns.Layout and ns.Layout() or "none"
	if create then all[key] = all[key] or {} end
	return all[key]
end

local function Get(bar)
	local s, name = Store(), bar and bar:GetName()
	return s and name and s[name] or "other"
end

function Style.Eligible(frame)
	local name = frame and frame.GetName and frame:GetName()
	return name ~= nil and BARS[name] == true and frame.actionButtons ~= nil
end

-- The frame behind the buttons, as the main bar has it; and its dividers.
local function Art(bar)
	local a = art[bar]
	if a then return a end
	local frame = CreateFrame("Frame", nil, UIParent)
	frame:SetPoint("TOPLEFT", bar, "TOPLEFT", -6, 6)
	frame:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 4, -5)
	frame.texture = frame:CreateTexture(nil, "BACKGROUND", nil, -3)
	frame.texture:SetAtlas("UI-HUD-ActionBar-Frame")
	frame.texture:SetAllPoints()
	frame:Hide()
	local ok, horizontal = pcall(CreateFramePool, "FRAME", frame, "HorizontalDividerTemplate")
	local ok2, vertical = pcall(CreateFramePool, "FRAME", frame, "VerticalDividerTemplate")
	a = { frame = frame, pools = (ok and ok2) and { horizontal = horizontal, vertical = vertical } or nil }
	art[bar] = a
	return a
end

-- As the main bar draws them: one row, no extra padding, between buttons shown.
local function Dividers(bar, a, on)
	local pools = a.pools
	if not pools then return end
	pools.horizontal:ReleaseAll()
	pools.vertical:ReleaseAll()
	if not on or (bar.numRows or 1) > 1 or (bar.buttonPadding or 0) > (bar.minButtonPadding or 2) then return end
	local horizontal = bar.isHorizontal ~= false
	local pool = horizontal and pools.horizontal or pools.vertical
	local lastShown = false
	for _, b in ipairs(bar.actionButtons) do
		if b:IsShown() then
			if lastShown then
				local d = pool:Acquire()
				d:ClearAllPoints()
				if horizontal then
					d:SetPoint("TOP", b, "TOP", 0, 0)
					d:SetPoint("BOTTOM", b, "BOTTOM", 0, 0)
					d:SetPoint("RIGHT", b, "LEFT", 5, 0)
				else
					d:SetPoint("LEFT", b, "LEFT", 0, 0)
					d:SetPoint("RIGHT", b, "RIGHT", 0, 0)
					d:SetPoint("BOTTOM", b, "TOP", 0, -5)
				end
				d:Show()
			end
			lastShown = true
		else
			lastShown = false
		end
	end
end

local function ApplyBar(bar)
	local style = Get(bar)
	if style == "other" and not touched[bar] then return end
	touched[bar] = true
	local main = style == "main"
	for _, b in ipairs(bar.actionButtons) do ns.SetButtonStyle(b, style) end
	local a = Art(bar)
	-- Just under the bar: on its layer (layers and dragging change it).
	a.frame:SetFrameStrata(bar:GetFrameStrata())
	a.frame:SetFrameLevel(math.max(0, bar:GetFrameLevel() - 1))
	local first = bar.actionButtons[1]
	local scale = first and first.container and first.container:GetScale() or 1
	a.frame.texture:SetScale(scale)
	a.frame:SetShown(main and bar:IsVisible())
	Dividers(bar, a, main)
end

local Watch

function Style.Apply()
	soon = nil
	for name in pairs(BARS) do
		local bar = _G[name]
		if bar and bar.actionButtons then
			Watch(bar)
			ApplyBar(bar)
		end
	end
end

function Style.Soon()
	if soon then return end
	soon = true
	C_Timer.After(0, Style.Apply)
end

-- The bar shown or hidden, laid out again (rows, icons, padding, buttons
-- shown), or put on another layer: ours follow.
function Watch(bar)
	if hooked[bar] then return end
	hooked[bar] = true
	bar:HookScript("OnShow", Style.Soon)
	bar:HookScript("OnHide", Style.Soon)
	for _, fn in ipairs({ "UpdateGridLayout", "UpdateShownButtons", "UpdateFrameStrata" }) do
		if bar[fn] then hooksecurefunc(bar, fn, Style.Soon) end
	end
end

local function Set(bar, style)
	local store, name = Store(true), bar and bar:GetName()
	if not (store and name) then return end
	store[name] = style ~= "other" and style or nil
	Style.Apply()
	ns.Changed()
	for _, r in ipairs(rows) do r.Refresh() end
end

Style.Set = Set

-- "Button Style [Main Action Bar]", shown for the game's other bars.
-- getFrame: the element it's for (or nil).
function Style.CreateRow(parent, getFrame, width)
	width = width or 216
	local row = CreateFrame("Frame", nil, parent)
	row:SetSize(width, 24)
	local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	label:SetPoint("LEFT")
	label:SetText("Button Style")
	local dd = CreateFrame("DropdownButton", nil, row, "WowStyle1DropdownTemplate")
	dd:SetWidth(width - 76)
	dd:SetPoint("RIGHT")
	dd:SetupMenu(function(_, root)
		for _, option in ipairs(STYLES) do
			root:CreateRadio(option[2], function()
				local bar = getFrame()
				return bar ~= nil and Get(bar) == option[1]
			end, function()
				local bar = getFrame()
				if bar and Style.Eligible(bar) then Set(bar, option[1]) end
			end)
		end
	end)
	local r = { row = row }
	function r.Refresh()
		local bar = getFrame()
		local on = Style.Eligible(bar)
		row:SetShown(on)
		if on then dd:GenerateMenu() end
		return on
	end
	rows[#rows + 1] = r
	r.Refresh()
	return row, r
end
