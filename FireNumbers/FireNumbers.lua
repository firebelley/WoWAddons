-- FireNumbers: the game's own damage numbers, made easier to read.
--
-- Only the game's numbers can be yours alone: it draws them itself and knows
-- who hit. Addons can't tell - every hit an enemy takes reaches them without
-- its attacker (UNIT_COMBAT), and everything that would say (the combat log,
-- the damage meter's totals, combat text) is closed or secret in combat. So
-- FireNumbers changes how the game draws them, through its settings (CVars):
-- size, pop, rise, fall, spread - and the font.
--
-- On first load it switches to its own style (bigger, floating up instead of
-- arcing down, crits popping harder); Options > AddOns > FireNumbers tunes it,
-- or puts back the game's style (what you had before). The style is built on
-- the game's classic numbers - the only ones its settings shape - so that's
-- kept on.
local DB -- FireNumbersDB

local function Print(msg) print("|cffff8030FireNumbers|r: " .. msg) end

local CLASSIC = "classicStyleWorldText"

-- The settings FireNumbers changes, and its style.
local STYLE = {
	[CLASSIC] = "1",
	WorldTextScale_v2 = "1.4",
	WorldTextMinSize_v2 = "10",
	WorldTextRampPowCrit_v2 = "2.5", -- the curve of a crit's movement: higher leaves it later (the game's 8 stays put)
	WorldTextGravity_v2 = "0",
	WorldTextRandomZMax_v2 = "1.0",
	WorldTextRandomZMin_v2 = "0.55",
	WorldTextRandomXY_v2 = "0.3",
	floatingCombatTextCombatDamageDirectionalScale_v2 = "0",
}
local RISE_SPREAD = 0.55 -- the slowest rise, as a share of the fastest

-- Fonts that come with the game. The engine reads its damage font as you log
-- in, so a change shows after logging out and back in.
local FONTS = {
	{ name = "Game font", path = nil },
	{ name = "Friz Quadrata", path = "Fonts\\FRIZQT__.TTF" },
	{ name = "Arial Narrow", path = "Fonts\\ARIALN.TTF" },
	{ name = "Skurri", path = "Fonts\\SKURRI.TTF" },
	{ name = "Morpheus", path = "Fonts\\MORPHEUS.TTF" },
}

local function Get(cvar)
	local ok, v = pcall(GetCVar, cvar)
	return ok and v or nil
end

local function Set(cvar, value)
	if Get(cvar) == nil then return false end -- not in this client
	return pcall(SetCVar, cvar, tostring(value))
end

-- What you had, the first time FireNumbers changes each setting.
local function Remember(cvar)
	DB.original = DB.original or {}
	if DB.original[cvar] == nil then DB.original[cvar] = Get(cvar) end
end

local function ApplyStyle()
	for cvar, value in pairs(STYLE) do
		Remember(cvar)
		Set(cvar, value)
	end
	DB.gameStyle = nil
end

local function GameStyle()
	for cvar, value in pairs(DB.original or {}) do Set(cvar, value) end
	DB.original = nil
	DB.font = nil
	DB.gameStyle = true -- until you pick FireNumbers' again
end

-- The sliders only shape classic numbers: keep it on (unless you went back to the game's style).
local function KeepClassic()
	if DB.gameStyle or Get(CLASSIC) == "1" then return end
	Remember(CLASSIC)
	Set(CLASSIC, "1")
end

---------------------------------------------------------------------------
-- Options > AddOns > FireNumbers
---------------------------------------------------------------------------
local category

local function Build()
	local panel = CreateFrame("Frame")
	panel:Hide()
	local refreshers = {}
	local y = -16

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, y)
	title:SetText("FireNumbers")
	y = y - 24
	local about = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	about:SetPoint("TOPLEFT", 16, y)
	about:SetPoint("RIGHT", -16, 0)
	about:SetJustifyH("LEFT")
	about:SetText("Shapes the game's own damage numbers (only yours). Changes show on your next hits - try them on "
		.. "a training dummy.")
	y = y - 30

	local function Tooltip(widget, label, text)
		widget:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(label, 1, 1, 1)
			GameTooltip:AddLine(text, nil, nil, nil, true)
			GameTooltip:Show()
		end)
		widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end

	-- Sliders in the classic options look; two fit side by side.
	-- set(v) defaults to setting the cvar; get() to reading it.
	local sliderX = 0
	local function Slider(cvar, label, tooltip, min, max, step, format, set, get)
		if Get(cvar) == nil then return end -- not in this client
		local ok, s = pcall(CreateFrame, "Slider", nil, panel, "BackdropTemplate")
		if not ok then s = CreateFrame("Slider", nil, panel) end
		s:SetOrientation("HORIZONTAL")
		s:SetSize(200, 17)
		s:SetPoint("TOPLEFT", 24 + sliderX, y - 18)
		if s.SetBackdrop then
			s:SetBackdrop({
				bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
				edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
				tile = true, tileSize = 8, edgeSize = 8,
				insets = { left = 3, right = 3, top = 6, bottom = 6 },
			})
		end
		s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
		s:SetMinMaxValues(min, max)
		s:SetValueStep(step)
		if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
		s:EnableMouseWheel(true)
		local name = s:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		name:SetPoint("BOTTOMLEFT", s, "TOPLEFT", 0, 2)
		name:SetText(label)
		local value = s:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		value:SetPoint("BOTTOMRIGHT", s, "TOPRIGHT", 0, 2)
		local loading = false
		s:SetScript("OnValueChanged", function(_, v)
			v = math.floor((v - min) / step + 0.5) * step + min -- snap to the step
			value:SetText(format(v))
			if loading then return end
			Remember(cvar)
			if set then set(v) else Set(cvar, v) end
			DB.gameStyle = nil -- tuning: FireNumbers' numbers again
			KeepClassic()
		end)
		s:SetScript("OnMouseWheel", function(self, delta)
			self:SetValue(math.max(min, math.min(max, self:GetValue() + delta * step)))
		end)
		Tooltip(s, label, tooltip)
		refreshers[#refreshers + 1] = function()
			local v = tonumber(get and get() or Get(cvar)) or min
			loading = true
			s:SetValue(v)
			value:SetText(format(v))
			loading = false
		end
		if sliderX == 0 then sliderX = 250 else sliderX, y = 0, y - 48 end
	end
	local function EndSliders()
		if sliderX ~= 0 then sliderX, y = 0, y - 48 end
	end

	local function Percent(v) return ("%d%%"):format(math.floor(v * 100 + 0.5)) end
	local function Number(v) return ("%.1f"):format(v) end
	local function Seconds(v) return ("%.1fs"):format(v) end

	Slider("WorldTextScale_v2", "Size", "How big the numbers are.", 0.25, 6, 0.05, Percent)
	Slider("WorldTextMinSize_v2", "Smallest size", "How small numbers on far-away enemies can get. Higher keeps them "
		.. "readable.", 0, 80, 1, function(v) return ("%d"):format(v) end)
	Slider("WorldTextRandomZMax_v2", "Rise", "How fast numbers float up.", 0, 10, 0.1, Number,
		function(v)
			Remember("WorldTextRandomZMin_v2")
			Set("WorldTextRandomZMax_v2", v)
			Set("WorldTextRandomZMin_v2", math.floor(v * RISE_SPREAD * 100 + 0.5) / 100)
		end)
	Slider("WorldTextGravity_v2", "Fall", "How fast numbers fall back down. At 0 they keep floating up.", -3, 10, 0.1,
		Number)
	Slider("WorldTextRandomXY_v2", "Spread", "How far to the sides numbers start, so they don't stack.", 0, 10, 0.1,
		Number)
	Slider("WorldTextRampDuration_v2", "Duration", "How long each number stays.", 0.1, 8, 0.1, Seconds)
	-- The curve of its movement over its life, not a delay: high values leave it
	-- all to the very end, so the number fades before it moves.
	Slider("WorldTextRampPow_v2", "Ease", "Below 1: a hit's number shoots off, then slows. Above 1: it starts slow "
		.. "and speeds up. Too high and it fades before it moves.", 0.1, 6, 0.1, Number)
	Slider("WorldTextRampPowCrit_v2", "Crit ease", "The same for crits. The game's own is 8: crits stay put.",
		0.1, 10, 0.1, Number)
	EndSliders()

	-- Font: a sample of each; the engine picks it up as you log in.
	local fontLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	fontLabel:SetPoint("TOPLEFT", 16, y)
	fontLabel:SetText("Font")
	local fontNote = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	fontNote:SetPoint("LEFT", fontLabel, "RIGHT", 8, 0)
	fontNote:SetText("shows after you log out and back in")
	y = y - 22
	local fontButtons = {}
	for i, f in ipairs(FONTS) do
		local b = CreateFrame("Button", nil, panel)
		b:SetSize(140, 30)
		b:SetPoint("TOPLEFT", 16 + ((i - 1) % 3) * 150, y - math.floor((i - 1) / 3) * 34)
		local hl = b:CreateTexture(nil, "BACKGROUND")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 0.82, 0, 0.15)
		b.selected = hl
		local sample = b:CreateFontString(nil, "ARTWORK")
		sample:SetPoint("LEFT", 6, 0)
		sample:SetFont(f.path or DB.gameFont or "Fonts\\FRIZQT__.TTF", 18, "THICKOUTLINE")
		sample:SetText("1,248")
		local name = b:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		name:SetPoint("LEFT", sample, "RIGHT", 8, 0)
		name:SetText(f.name)
		b:SetScript("OnClick", function()
			DB.font = f.path
			for _, other in ipairs(fontButtons) do other.selected:SetShown(other == b) end
			Print("font: " .. f.name .. " - log out and back in to see it.")
		end)
		b.path = f.path
		fontButtons[#fontButtons + 1] = b
	end
	refreshers[#refreshers + 1] = function()
		for _, b in ipairs(fontButtons) do b.selected:SetShown(b.path == DB.font) end
	end
	y = y - math.ceil(#FONTS / 3) * 34 - 10

	local function Button(text, tooltip, x, onClick)
		local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		b:SetSize(170, 22)
		b:SetText(text)
		b:SetPoint("TOPLEFT", x, y)
		b:SetScript("OnClick", function()
			onClick()
			for _, fn in ipairs(refreshers) do fn() end
		end)
		Tooltip(b, text, tooltip)
	end
	Button("FireNumbers style", "Bigger, floating up instead of arcing down, crits popping harder.", 20, ApplyStyle)
	Button("Game's style", "What you had before FireNumbers (and the game font).", 200, GameStyle)

	panel:SetScript("OnShow", function()
		for _, fn in ipairs(refreshers) do fn() end
	end)
	category = Settings.RegisterCanvasLayoutCategory(panel, "FireNumbers")
	Settings.RegisterAddOnCategory(category)
end

local function OpenOptions()
	if not category then return end
	local id = category.GetID and category:GetID() or category.ID
	if not (id and pcall(Settings.OpenToCategory, id)) then pcall(Settings.OpenToCategory, category) end
end

---------------------------------------------------------------------------
-- /fnum cvars: every setting this client has for its combat numbers.
---------------------------------------------------------------------------
local PATTERNS = { "worldtext", "floatingcombattext", "combatdamage", "damagetext", "combattext" }

local function ListCVars()
	local list = {}
	local all = ConsoleGetAllCommands and ConsoleGetAllCommands()
	if type(all) ~= "table" then
		Print("this client doesn't list its settings.")
		return
	end
	for _, info in ipairs(all) do
		local name = info and info.command
		if type(name) == "string" then
			local lower = name:lower()
			for _, p in ipairs(PATTERNS) do
				if lower:find(p, 1, true) then
					list[#list + 1] = name
					break
				end
			end
		end
	end
	table.sort(list, function(a, b) return a:lower() < b:lower() end)
	Print(("%d settings for the game's combat numbers:"):format(#list))
	for _, name in ipairs(list) do print(("  %s = %s"):format(name, tostring(Get(name)))) end
	Print("damage text font: " .. tostring(DAMAGE_TEXT_FONT))
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(_, event, addon)
	if event == "ADDON_LOADED" then
		if addon ~= "FireNumbers" then return end
		FireNumbersDB = type(FireNumbersDB) == "table" and FireNumbersDB or {}
		DB = FireNumbersDB
		-- The first version turned the game's damage numbers off: put them back.
		if DB.hidBlizzard then
			pcall(SetCVar, "floatingCombatTextCombatDamage_v2", DB.blizzardWas or "1")
			DB.hidBlizzard, DB.blizzardWas, DB.enabled = nil, nil, nil
		end
		-- The game's font, for the "Game font" sample; then yours, if you picked one.
		DB.gameFont = DB.gameFont or (type(DAMAGE_TEXT_FONT) == "string" and DAMAGE_TEXT_FONT) or nil
		if DB.font then DAMAGE_TEXT_FONT = DB.font end
	else
		-- The first style held crits still (12): if that's still set, the new one.
		if DB.styled and not DB.critHoldFixed and tonumber(Get("WorldTextRampPowCrit_v2")) == 12 then
			Set("WorldTextRampPowCrit_v2", STYLE.WorldTextRampPowCrit_v2)
		end
		DB.critHoldFixed = true
		if not DB.styled then
			ApplyStyle()
			DB.styled = true
		else
			KeepClassic()
		end
		if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then Build() end
	end
end)

SLASH_FIRENUMBERS1 = "/fnum"
SLASH_FIRENUMBERS2 = "/firenumbers"
SlashCmdList.FIRENUMBERS = function(msg)
	if (msg or ""):lower() == "cvars" then
		ListCVars()
	else
		OpenOptions()
	end
end
