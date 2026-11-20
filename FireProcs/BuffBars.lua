-- Timer bars on the game's own buff icons (top right): a bar just below (or
-- above) each icon showing the time left, green when fresh, red as it runs
-- out. Off by default (Options > AddOns > FireProcs).
--
-- The icon's time text ("60 m") sits right against the icon; when the bar is
-- on the same side, the text is moved out past the bar.
--
-- Blizzard's buff buttons already work out their time left every frame
-- (button.timeLeft), so the bars just read that. In combat it can be a hidden
-- value: status bars still accept those, so the bar keeps moving; the colour
-- then comes from the game's own duration object for that buff where it can.
--
-- Weapon enchants (poisons, stones, imbues) don't say how long they last in
-- total: the longest time left seen for each enchant is remembered instead
-- (db.enchantDurations), rounded up to the minute.
local _, ns = ...
local API = ns.API

local BuffBars = {}
ns.BuffBars = BuffBars

local TICK = 0.05 -- seconds between bar updates
local TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
local GAP = 1     -- pixels between the icon and the bar

local bars = {} -- [Blizzard buff button] = our status bar

-- 1 = full (green), 0.5 = yellow, 0 = empty (red).
local function SetColor(bar, f)
	if f > 0.5 then
		bar:SetStatusBarColor((1 - f) * 2, 1, 0)
	else
		bar:SetStatusBarColor(1, f * 2, 0)
	end
end

-- The same colours as a curve, for hidden (combat) values.
local curve
local function Curve()
	if curve == nil then
		curve = false
		if C_CurveUtil and C_CurveUtil.CreateColorCurve and CreateColor then
			local ok, c = pcall(C_CurveUtil.CreateColorCurve)
			if ok and c and pcall(function()
				c:AddPoint(0, CreateColor(1, 0, 0))
				c:AddPoint(0.5, CreateColor(1, 1, 0))
				c:AddPoint(1, CreateColor(0, 1, 0))
			end) then
				curve = c
			end
		end
	end
	return curve or nil
end

-- Colour from the buff's own duration object (hidden values allowed). Leaves
-- the colour as it was if the game won't say.
local function SetHiddenColor(bar, button, info)
	local c = Curve()
	local id = info.auraInstanceID
	if not (c and id and not API.IsSecret(id) and C_UnitAuras and C_UnitAuras.GetAuraDuration) then return end
	pcall(function()
		local dur = C_UnitAuras.GetAuraDuration(button.unit or "player", id)
		local color = dur and dur:EvaluateRemainingPercent(c)
		if color then bar:SetStatusBarColor(color:GetRGB()) end
	end)
end

-- Total length of a weapon enchant: the longest time left seen for it.
local function EnchantTotal(info)
	local inv = info.ID
	local left = info.expirationTime
	if type(inv) ~= "number" or type(left) ~= "number" or API.IsSecret(left) then return nil end
	left = left - GetTime()
	local key = "slot" .. inv -- if the enchant can't be identified: per weapon slot
	if C_Item and C_Item.GetWeaponEnchantInfo then
		local ok, list = pcall(C_Item.GetWeaponEnchantInfo, inv - 16)
		if ok and type(list) == "table" then
			for _, e in pairs(list) do
				local id = type(e) == "table" and e.enchantID
				if id and not API.IsSecret(id) and id ~= 0 then
					key = id
					break
				end
			end
		end
	end
	local known = ns.db.enchantDurations
	local seen = math.ceil(left / 60) * 60
	if not known[key] or seen > known[key] then known[key] = seen end
	return known[key]
end

local function Total(info)
	if info.auraType == "TempEnchant" then return EnchantTotal(info) end
	return info.duration
end

-- Moves the icon's time text out of the bar's way (push = 0 puts it back).
-- Blizzard anchors it against the icon with no offset: below it ("BOTTOM"),
-- above it ("TOP") or beside it, depending on how the buff frame grows.
local function NudgeText(button, push)
	local text = button.Duration
	if not (text and text.GetPoint) then return end
	local point, rel, relPoint, x, y = text:GetPoint(1)
	if not point then return end
	local want = 0
	if push > 0 then
		local above = ns.db.buffBarAbove
		if relPoint == "BOTTOM" and not above then
			want = -push
		elseif relPoint == "TOP" and above then
			want = push
		end
	end
	if y ~= want then text:SetPoint(point, rel, relPoint, x or 0, want) end
end

local function UpdateBar(button, bar)
	local info = button.buttonInfo
	local left = button.timeLeft
	if not (button:IsShown() and info and type(left) == "number") or button.isExample then
		bar:Hide()
		return
	end
	if bar.info ~= info then -- a different buff on this button (or a refresh)
		bar.info = info
		bar.total = Total(info)
		bar:SetStatusBarColor(0, 1, 0)
	end
	local total = bar.total
	if type(total) ~= "number" then
		bar:Hide()
	elseif API.IsSecret(total) or API.IsSecret(left) then
		bar:SetMinMaxValues(0, total)
		bar:SetValue(left)
		SetHiddenColor(bar, button, info)
		bar:Show()
	elseif total <= 0 then
		bar:Hide()
	else
		local f = math.max(0, math.min(1, left / total))
		bar:SetMinMaxValues(0, 1)
		bar:SetValue(f)
		SetColor(bar, f)
		bar:Show()
	end
end

-- A bar is two status bars side by side, given the same values: the left one
-- fills from its right edge, the right one from its left edge, so together
-- they shrink from both ends toward the middle. With "shrink from both ends"
-- off, the left one alone spans the whole width and fills normally.
-- (Calls like SetValue go to both halves, so hidden values work too.)
local Bar = {}
for _, method in ipairs({ "SetStatusBarColor", "SetMinMaxValues", "SetValue" }) do
	Bar[method] = function(self, ...)
		self.left[method](self.left, ...)
		self.right[method](self.right, ...)
	end
end

function Bar:SetCentered(center)
	local l, r = self.left, self.right
	l:ClearAllPoints()
	l:SetPoint("TOPLEFT")
	l:SetPoint("BOTTOMLEFT")
	if center then
		l:SetPoint("RIGHT", self, "CENTER")
	else
		l:SetPoint("RIGHT")
	end
	l:SetReverseFill(center and true or false)
	r:SetShown(center and true or false)
end

local function Half(bar)
	local s = CreateFrame("StatusBar", nil, bar)
	s:SetStatusBarTexture(TEXTURE)
	s:SetMinMaxValues(0, 1)
	return s
end

local function CreateBar(button)
	local bar = CreateFrame("Frame", nil, button)
	Mixin(bar, Bar)
	bar:SetFrameLevel(button:GetFrameLevel() + 2)
	local bg = bar:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 0.6)
	bar.left = Half(bar)
	bar.right = Half(bar)
	bar.right:SetPoint("TOPLEFT", bar, "TOP")
	bar.right:SetPoint("BOTTOMRIGHT")
	bar.icon = button.Icon
	bar:Hide()
	return bar
end

-- Just below the icon, or just above it; as wide as the icon.
function Bar:Place(above)
	local icon = self.icon
	self:ClearAllPoints()
	if above then
		self:SetPoint("BOTTOMLEFT", icon, "TOPLEFT", 0, GAP)
		self:SetPoint("BOTTOMRIGHT", icon, "TOPRIGHT", 0, GAP)
	else
		self:SetPoint("TOPLEFT", icon, "BOTTOMLEFT", 0, -GAP)
		self:SetPoint("TOPRIGHT", icon, "BOTTOMRIGHT", 0, -GAP)
	end
end

local driver = CreateFrame("Frame")
driver:Hide()
local wait = 0
driver:SetScript("OnUpdate", function(_, elapsed)
	wait = wait - elapsed
	if wait > 0 then return end
	wait = TICK
	-- (Checked every tick: the game puts the text back whenever it re-lays
	-- out the buffs.)
	local push = (ns.db.buffBarHeight or ns.DEFAULTS.buffBarHeight) + GAP
	for button, bar in pairs(bars) do
		local ok, err = pcall(UpdateBar, button, bar)
		if not ok then
			bar:Hide()
			ns.ReportError(err)
		end
		ns.SafeCall(NudgeText, button, bar:IsShown() and push or 0)
	end
end)

-- Applies the settings: on/off, bar height, fill direction, above/below.
function BuffBars.Refresh()
	local on = ns.db.buffBars
	local height = ns.db.buffBarHeight or ns.DEFAULTS.buffBarHeight
	for button, bar in pairs(bars) do
		bar:SetHeight(height)
		bar:SetCentered(ns.db.buffBarCenter)
		bar:Place(ns.db.buffBarAbove)
		if not on then
			bar:Hide()
			ns.SafeCall(NudgeText, button, 0)
		end
	end
	wait = 0
	driver:SetShown(on and true or false)
end

ns.On("PLAYER_LOGIN", function()
	local frames = BuffFrame and BuffFrame.auraFrames
	if type(frames) ~= "table" then return end
	for _, button in ipairs(frames) do
		if not button.isAuraAnchor and button.Icon then
			bars[button] = CreateBar(button)
		end
	end
	BuffBars.Refresh()
end)
