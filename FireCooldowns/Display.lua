-- The list on screen: each cooldown with its icon and time left. A ready one
-- stays, green with its icon pulsing, until you use it. Other characters'
-- show under yours, with their name. Placed, turned on or off and its text
-- sized in Edit Mode (EditMode.lua); the rest in the options (Options.lua).
local _, ns = ...

local Display = {}
ns.Display = Display

Display.MIN_TEXT, Display.MAX_TEXT, Display.TEXT = 8, 20, 12
local POINT = { "BOTTOMRIGHT", "BOTTOMRIGHT", -300, 220 } -- above the action bars, right side
local GAP = 4      -- between icon and name
local TIME_GAP = 12 -- between name and time

local frame
local rows = {}
local editing = false
local font -- { file, flags } of the game's normal font

local SAMPLE = {
	{ label = "Transmute", icon = "Interface\\Icons\\INV_Misc_StoneTablet_05", ready = true, mine = true },
	{ label = "Mooncloth", icon = "Interface\\Icons\\INV_Fabric_Moonrag_01", left = 26 * 3600 },
}

function Display.TextSize()
	return math.floor((ns.db.textSize or Display.TEXT) + 0.5)
end

function Display.Place()
	local p = ns.db.point or POINT
	frame:ClearAllPoints()
	frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
end

-- Kept from its bottom right, so it grows up and to the left wherever it is.
function Display.Pin()
	local x, y = frame:GetRight(), frame:GetBottom()
	if not (x and y) then return end
	ns.db.point = { "BOTTOMRIGHT", "BOTTOMLEFT", math.floor(x + 0.5), math.floor(y + 0.5) }
	Display.Place()
end

function Display.ResetPosition()
	ns.db.point = nil
	Display.Place()
end

-- The game blocks setting up click pass-through in combat: a row made
-- mid-fight gets its clicks once the fight ends.
local clicksPending = {}
local function EnableClicks(r)
	if InCombatLockdown() then
		clicksPending[r] = true
		return
	end
	r:EnableMouse(true)
	if r.SetPassThroughButtons then pcall(r.SetPassThroughButtons, r, "LeftButton") end
end
local regen = CreateFrame("Frame")
regen:RegisterEvent("PLAYER_REGEN_ENABLED")
regen:SetScript("OnEvent", function()
	for r in pairs(clicksPending) do
		clicksPending[r] = nil
		EnableClicks(r)
	end
end)

local function CreateRow()
	local r = CreateFrame("Frame", nil, frame)
	r.icon = r:CreateTexture(nil, "ARTWORK")
	r.icon:SetPoint("LEFT")
	r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	r.name = r:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	r.name:SetPoint("LEFT", r.icon, "RIGHT", GAP, 0)
	r.name:SetJustifyH("LEFT")
	r.time = r:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	r.time:SetPoint("RIGHT")
	r.time:SetJustifyH("RIGHT")
	local pulse = r:CreateAnimationGroup()
	pulse:SetLooping("BOUNCE")
	local a = pulse:CreateAnimation("Alpha")
	a:SetFromAlpha(1)
	a:SetToAlpha(0.3)
	a:SetDuration(0.8)
	r.pulse = pulse
	-- Right-click a ready one to dismiss it until it's used again; left
	-- clicks go through to the world.
	EnableClicks(r)
	r:SetScript("OnMouseUp", function(self, button)
		local item = self.item
		if button ~= "RightButton" or not (item and item.ready and item.entries) then return end
		for _, e in ipairs(item.entries) do e.dismissed = true end
		GameTooltip:Hide()
		Display.Refresh()
	end)
	r:SetScript("OnEnter", function(self)
		local item = self.item
		if not (item and item.ready and item.entries) then return end
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText(item.plain .. " ready", 1, 1, 1)
		GameTooltip:AddLine("Right-click to dismiss until it's used again.", 0.8, 0.8, 0.8)
		GameTooltip:Show()
	end)
	r:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return r
end

-- What to show: this character's cooldowns, then the others' (by name).
local function Items()
	local db, me, now = ns.db, ns.me, ns.Now()
	local chars = { me }
	if db.alts then
		local others = {}
		for _, c in pairs(db.chars) do
			if c ~= me and next(c.cds) then others[#others + 1] = c end
		end
		table.sort(others, function(a, b) return (a.name or "") < (b.name or "") end)
		for _, c in ipairs(others) do chars[#chars + 1] = c end
	end
	local items = {}
	for _, c in ipairs(chars) do
		local shown = {}
		for _, e in ipairs(ns.Entries(c)) do
			if not (e.dismissed and e.readyAt <= now) then shown[#shown + 1] = e end
		end
		for _, g in ipairs(ns.Group(shown, now)) do
			if g.ready or not db.readyOnly then
				items[#items + 1] = {
					label = c == me and g.label or (ns.ClassName(c) .. ": " .. g.label),
					plain = g.label, entries = g.entries,
					icon = g.icon, ready = g.ready, left = g.left, mine = c == me,
				}
			end
		end
	end
	return items
end

function Display.Refresh()
	if not frame then return end
	local items = ns.db.shown and Items() or {}
	if editing and ns.db.shown and #items == 0 then items = SAMPLE end
	if #items == 0 then
		frame:Hide()
		for _, r in ipairs(rows) do r.pulse:Stop() end
		return
	end

	local size = Display.TextSize()
	local iconSize = size + 4
	local rowH = iconSize + 2
	local nameW, timeW = 0, 0
	for i, item in ipairs(items) do
		local r = rows[i] or CreateRow()
		rows[i] = r
		r.icon:SetSize(iconSize, iconSize)
		r.icon:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
		r.name:SetFont(font[1], size, font[2])
		r.time:SetFont(font[1], size, font[2])
		r.item = item
		r.name:SetText(item.label)
		if item.ready then
			r.time:SetText("Ready")
			r.time:SetTextColor(0.25, 1, 0.25)
		else
			r.time:SetText(ns.Left(item.left))
			r.time:SetTextColor(1, 1, 1)
		end
		if item.ready and item.mine then
			if not r.pulse:IsPlaying() then r.pulse:Play() end
		else
			r.pulse:Stop()
			r.icon:SetAlpha(1)
		end
		nameW = math.max(nameW, r.name:GetStringWidth())
		timeW = math.max(timeW, r.time:GetStringWidth())
	end

	local width = math.ceil(iconSize + GAP + nameW + TIME_GAP + timeW)
	for i, r in ipairs(rows) do
		if items[i] then
			r:SetSize(width, rowH)
			r:ClearAllPoints()
			r:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -(i - 1) * rowH)
			r:Show()
		else
			r.pulse:Stop()
			r:Hide()
		end
	end
	frame:SetSize(width, #items * rowH)
	frame:Show()
end

-- In Edit Mode it shows a sample when there's nothing to show.
function Display.SetEditing(on)
	editing = on
	Display.Refresh()
end

function Display.Frame() return frame end

function Display.Init()
	frame = CreateFrame("Frame", "FireCooldownsFrame", UIParent)
	frame:SetSize(1, 1)
	frame:SetFrameStrata("LOW")
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	if frame.SetDontSavePosition then frame:SetDontSavePosition(true) end
	local probe = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	local file, _, flags = probe:GetFont()
	font = { file or STANDARD_TEXT_FONT, flags }
	probe:Hide()
	Display.Place()
	frame:Hide()
	Display.Refresh()
end
