-- What you see: a big icon + name above your character that pops in and fades
-- out, and below it a row of icons for proc buffs you have right now.
local _, ns = ...
local API = ns.API

local Display = {}
ns.Display = Display

local POP, HOLD, FADE = 0.15, 1.5, 0.6 -- seconds
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
		self.name = nil
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
	c:SetHeight(LINE_HEIGHT)
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

local function LayoutLine(c, hasIcon)
	c.icon:ClearAllPoints()
	c.text:ClearAllPoints()
	local textWidth = c.text:GetStringWidth() or 0
	if hasIcon then
		c.icon:SetPoint("LEFT", c, "LEFT", 0, 0)
		c.text:SetPoint("LEFT", c.icon, "RIGHT", 8, 0)
		c:SetWidth(math.max(ICON_SIZE + 8 + textWidth, 1))
	else
		c.text:SetPoint("LEFT", c, "LEFT", 0, 0)
		c:SetWidth(math.max(textWidth, 1))
	end
end

local lastSound = 0

function Display.Alert(name, icon)
	-- Reuse the line already showing this proc, then a free one, then the oldest.
	local line
	for _, l in ipairs(lines) do
		if l:IsShown() and l.name == name then line = l break end
	end
	if not line then
		for _, l in ipairs(lines) do
			if not l:IsShown() then line = l break end
		end
	end
	if not line then
		line = lines[1]
		for _, l in ipairs(lines) do
			if l.t > line.t then line = l end
		end
	end

	local c = line.content
	line.name = name
	c.text:SetText(name)
	if icon then
		c.icon:SetTexture(icon)
		c.icon:Show()
	else
		c.icon:Hide()
	end
	LayoutLine(c, icon ~= nil)
	line.t = 0
	c:SetAlpha(0)
	line:Show()

	local now = GetTime()
	if ns.db.sound and now - lastSound > 0.3 then
		lastSound = now
		API.PlayAlertSound()
	end
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
	Display.SetAuras({
		{ name = "Clearcasting", icon = "Interface\\Icons\\Spell_Shadow_ManaBurn", count = 0, duration = 8, expires = GetTime() + 8 },
	})
	C_Timer.After(8, function() ns.Auras.Update() end)
end

ns.On("PLAYER_LOGIN", Display.ApplyPosition)
