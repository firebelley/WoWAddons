-- What you see: a big icon + name above your character that pops in and fades
-- out, and below it a row of icons for proc buffs you have right now.
local _, ns = ...
local API = ns.API

local Display = {}
ns.Display = Display

local POP, FADE = 0.15, 0.6 -- seconds; how long it holds is a setting (db.hold)
local MAX_LINES = 3
local LINE_HEIGHT = 44
local ICON_SIZE = 36
local FONT_SIZE = 26
local AURA_SIZE = 36
local AURA_GAP = 6
local WIDTH = 360
local DEFAULT_Y = 200

local holder = CreateFrame("Frame", "FireProcsFrame", UIParent)
holder:SetSize(WIDTH, LINE_HEIGHT)
holder:SetFrameStrata("HIGH")
holder:SetClampedToScreen(true)
holder:SetMovable(true)
holder:SetPoint("CENTER", UIParent, "CENTER", 0, DEFAULT_Y)

---------------------------------------------------------------------------
-- Announcement lines
---------------------------------------------------------------------------
local function LineOnUpdate(self, elapsed)
	self.t = self.t + elapsed
	local t, c = self.t, self.content
	local HOLD = ns.db.hold or 1.5
	if t < POP then
		local p = t / POP
		c:SetScale(1.6 - 0.6 * p)
		c:SetAlpha(p)
	elseif t < POP + HOLD then
		c:SetScale(1)
		c:SetAlpha(1)
	elseif t < POP + HOLD + FADE then
		c:SetAlpha(1 - (t - POP - HOLD) / FADE)
	else
		self:Hide()
		self.key = nil
	end
end

local lines = {}
for i = 1, MAX_LINES do
	-- The slot stays put; only its content scales, around its own centre.
	local slot = CreateFrame("Frame", nil, holder)
	slot:SetSize(WIDTH, LINE_HEIGHT)
	slot:SetPoint("BOTTOM", holder, "BOTTOM", 0, (i - 1) * LINE_HEIGHT)

	local c = CreateFrame("Frame", nil, slot)
	c:SetPoint("CENTER")
	c:SetSize(WIDTH, LINE_HEIGHT)
	c.icon = c:CreateTexture(nil, "ARTWORK")
	c.icon:SetSize(ICON_SIZE, ICON_SIZE)
	c.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	c.text = c:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	local font = c.text:GetFont()
	c.text:SetFont(font or STANDARD_TEXT_FONT, FONT_SIZE, "OUTLINE")
	c.text:SetTextColor(1, 0.82, 0)

	slot.content = c
	slot.t = 0
	slot:Hide()
	slot:SetScript("OnUpdate", LineOnUpdate)
	lines[i] = slot
end

-- Icon + text centred as a pair, without measuring the text (a hidden name
-- can be shown but not measured): shifting the text right by half the icon's
-- width centres the whole pair.
local GAP = 8
local function LayoutLine(c, hasIcon)
	c.icon:ClearAllPoints()
	c.text:ClearAllPoints()
	c.text:SetPoint("CENTER", c, "CENTER", hasIcon and (ICON_SIZE + GAP) / 2 or 0, 0)
	if hasIcon then c.icon:SetPoint("RIGHT", c.text, "LEFT", -GAP, 0) end
end

local lastSound = 0

-- key: what identifies this announcement (defaults to the name), so the same
-- proc re-uses its line instead of stacking.
local function PickLine(key)
	for _, l in ipairs(lines) do
		if l:IsShown() and l.key == key then return l end
	end
	for _, l in ipairs(lines) do
		if not l:IsShown() then return l end
	end
	local oldest = lines[1]
	for _, l in ipairs(lines) do
		if l.t > oldest.t then oldest = l end
	end
	return oldest
end

local function Play(line)
	line.t = 0
	line.content:SetAlpha(0)
	line:Show()
	local now = GetTime()
	if ns.db.sound and now - lastSound > 0.3 then
		lastSound = now
		API.PlayAlertSound()
	end
end

function Display.Alert(name, icon)
	local line = PickLine(name)
	line.key = name
	local c = line.content
	c.text:SetText(name)
	if icon then
		c.icon:SetTexture(icon)
		c.icon:Show()
	else
		c.icon:Hide()
	end
	LayoutLine(c, icon ~= nil)
	Play(line)
end

---------------------------------------------------------------------------
-- Active proc buffs
---------------------------------------------------------------------------
local row = CreateFrame("Frame", nil, holder)
row:SetSize(1, AURA_SIZE)
row:SetPoint("TOP", holder, "BOTTOM", 0, -6)

local auraButtons = {}

local function CreateAuraButton()
	local b = CreateFrame("Frame", nil, row)
	b:SetSize(AURA_SIZE, AURA_SIZE)
	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetAllPoints()
	b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	local ok, cd = pcall(CreateFrame, "Cooldown", nil, b, "CooldownFrameTemplate")
	if ok and cd then
		cd:SetAllPoints()
		cd:SetReverse(true)
		b.cd = cd
	end
	b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	b.count:SetPoint("BOTTOMRIGHT", -1, 2)
	return b
end

-- list: { name, icon, count, duration, expires } for each proc buff you have.
function Display.SetAuras(list)
	if ns.db.showIcons == false then list = {} end
	local n = #list
	row:SetWidth(math.max(n * AURA_SIZE + math.max(n - 1, 0) * AURA_GAP, 1))
	for i, a in ipairs(list) do
		local b = auraButtons[i]
		if not b then
			b = CreateAuraButton()
			auraButtons[i] = b
		end
		b:ClearAllPoints()
		b:SetPoint("LEFT", row, "LEFT", (i - 1) * (AURA_SIZE + AURA_GAP), 0)
		b.icon:SetTexture(a.icon)
		b.count:SetText((a.count or 0) > 1 and a.count or "")
		if b.cd then
			if a.duration and a.duration > 0 then
				b.cd:SetCooldown(a.expires - a.duration, a.duration)
			elseif b.cd.Clear then
				b.cd:Clear()
			else
				b.cd:SetCooldown(0, 0)
			end
		end
		b:Show()
	end
	for i = n + 1, #auraButtons do auraButtons[i]:Hide() end
	if Display.PlaceMissingRow then Display.PlaceMissingRow(n) end
end

---------------------------------------------------------------------------
-- Missing buffs (buff reminders): greyed-out, red-edged, pulsing icons under
-- the proc icons, until you recast them.
---------------------------------------------------------------------------
local missingRow = CreateFrame("Frame", nil, holder)
missingRow:SetSize(1, AURA_SIZE)
missingRow:SetPoint("TOP", row, "BOTTOM", 0, -AURA_GAP)

local missingButtons = {}

local function CreateMissingButton()
	local b = CreateFrame("Frame", nil, missingRow)
	b:SetSize(AURA_SIZE, AURA_SIZE)
	local edge = b:CreateTexture(nil, "BACKGROUND")
	edge:SetPoint("TOPLEFT", -2, 2)
	edge:SetPoint("BOTTOMRIGHT", 2, -2)
	edge:SetColorTexture(0.9, 0.1, 0.1, 1)
	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetAllPoints()
	b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	b.icon:SetDesaturated(true)
	b.icon:SetVertexColor(1, 0.6, 0.6)
	local ag = b:CreateAnimationGroup()
	ag:SetLooping("BOUNCE")
	local a = ag:CreateAnimation("Alpha")
	a:SetFromAlpha(1)
	a:SetToAlpha(0.45)
	a:SetDuration(0.8)
	b:SetScript("OnShow", function() ag:Play() end)
	b:SetScript("OnHide", function() ag:Stop() end)
	-- Right-click dismisses it; left clicks go through to the world.
	b:EnableMouse(true)
	if b.SetPassThroughButtons then pcall(b.SetPassThroughButtons, b, "LeftButton") end
	b:SetScript("OnMouseUp", function(self, button)
		if button == "RightButton" and self.name then
			GameTooltip:Hide()
			ns.SafeCall(ns.SelfBuffs.Dismiss, self.name)
		end
	end)
	b:SetScript("OnEnter", function(self)
		if not self.name then return end
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:SetText(self.name .. " is gone", 1, 0.3, 0.3)
		GameTooltip:AddLine("Right-click to dismiss until you recast it.", 0.8, 0.8, 0.8)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return b
end

-- Right under the announcements, or under the proc icons when there are some.
local function PlaceMissingRow(procCount)
	missingRow:ClearAllPoints()
	if procCount > 0 then
		missingRow:SetPoint("TOP", row, "BOTTOM", 0, -AURA_GAP)
	else
		missingRow:SetPoint("TOP", holder, "BOTTOM", 0, -6)
	end
end
Display.PlaceMissingRow = PlaceMissingRow

-- list: { name, icon } for each buff to recast.
function Display.SetMissing(list)
	local n = #list
	missingRow:SetWidth(math.max(n * AURA_SIZE + math.max(n - 1, 0) * AURA_GAP, 1))
	for i, m in ipairs(list) do
		local b = missingButtons[i]
		if not b then
			b = CreateMissingButton()
			missingButtons[i] = b
		end
		b:ClearAllPoints()
		b:SetPoint("LEFT", missingRow, "LEFT", (i - 1) * (AURA_SIZE + AURA_GAP), 0)
		b.icon:SetTexture(m.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
		b.name = m.name
		b:Show()
	end
	for i = n + 1, #missingButtons do missingButtons[i]:Hide() end
end

---------------------------------------------------------------------------
-- Moving
---------------------------------------------------------------------------
local box = holder:CreateTexture(nil, "BACKGROUND")
box:SetAllPoints()
box:SetColorTexture(0.1, 0.4, 1, 0.35)
box:Hide()
local boxLabel = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
boxLabel:SetPoint("CENTER")
boxLabel:SetText("FireProcs: drag to move, /fprocs move when done")
boxLabel:Hide()

holder:RegisterForDrag("LeftButton")
holder:SetScript("OnDragStart", function(self) self:StartMoving() end)
holder:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	self:SetUserPlaced(false) -- we save the position ourselves
	local point, _, relPoint, x, y = self:GetPoint()
	ns.db.position = { point, relPoint, x, y }
end)

local moving = false
function Display.ToggleMove()
	moving = not moving
	holder:EnableMouse(moving)
	box:SetShown(moving)
	boxLabel:SetShown(moving)
	return moving
end

function Display.ApplyPosition()
	local p = ns.db.position
	holder:ClearAllPoints()
	if p then
		holder:SetPoint(p[1], UIParent, p[2], p[3], p[4])
	else
		holder:SetPoint("CENTER", UIParent, "CENTER", 0, DEFAULT_Y)
	end
end

function Display.ResetPosition()
	ns.db.position = nil
	Display.ApplyPosition()
end

function Display.Test()
	Display.Alert("Clearcasting", "Interface\\Icons\\Spell_Shadow_ManaBurn")
	C_Timer.After(0.5, function()
		Display.Alert("Overpower", "Interface\\Icons\\Ability_MeleeDamage")
	end)
	C_Timer.After(1, function()
		Display.Alert("Demon Armor is gone", "Interface\\Icons\\Spell_Shadow_RagingScream")
	end)
	Display.SetAuras({
		{ name = "Clearcasting", icon = "Interface\\Icons\\Spell_Shadow_ManaBurn", count = 0, duration = 8, expires = GetTime() + 8 },
	})
	Display.SetMissing({ { name = "Demon Armor", icon = "Interface\\Icons\\Spell_Shadow_RagingScream" } })
	C_Timer.After(8, function()
		ns.Auras.Update()
		ns.SelfBuffs.Update()
	end)
end

-- Size from the options. When changed live, the announcements stay centred on
-- the same spot (positions are stored in the frame's own scaled units).
function Display.ApplyScale(keepCenter)
	local x, y = holder:GetCenter()
	local oldScale = holder:GetEffectiveScale()
	holder:SetScale(ns.db.scale or 1)
	if keepCenter and x then
		local s = holder:GetEffectiveScale() / UIParent:GetEffectiveScale()
		local o = oldScale / UIParent:GetEffectiveScale()
		holder:ClearAllPoints()
		holder:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x * o / s, y * o / s)
		ns.db.position = { "CENTER", "BOTTOMLEFT", x * o / s, y * o / s }
	end
end

ns.On("PLAYER_LOGIN", function()
	Display.ApplyScale(false)
	Display.ApplyPosition()
end)
