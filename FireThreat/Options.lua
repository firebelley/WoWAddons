-- Options > AddOns > FireThreat (or /fthreat). A self-drawn ("canvas") page,
-- so the game's settings search never runs into it (see FireProcs/Options.lua).
local _, ns = ...

local category

local function Tooltip(widget, title, text)
	widget:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(title, 1, 1, 1)
		if text then GameTooltip:AddLine(text, nil, nil, nil, true) end
		GameTooltip:Show()
	end)
	widget:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

local function ApplyNow()
	ns.Apply()
end

local function Build()
	local db = ns.db
	local panel = CreateFrame("Frame")
	panel:Hide()
	local refreshers = {}
	local y = -16

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, y)
	title:SetText("FireThreat")
	y = y - 24

	local about = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	about:SetPoint("TOPLEFT", 16, y)
	about:SetPoint("RIGHT", -16, 0)
	about:SetJustifyH("LEFT")
	about:SetText("Enemies you're fighting (needs enemy nameplates on). Red means act and is listed first.\n"
		.. "Tank - green: on you. Yellow: about to be pulled. Red: on someone else.\n"
		.. "Damage/healing - green: on someone else. Yellow: ease off. Red: on you.\n"
		.. "Hover an enemy to point an arrow at it.")
	y = y - 62

	local lastButton
	local function Button(text, tooltip, onClick)
		local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		b:SetSize(130, 22)
		b:SetText(text)
		if lastButton then b:SetPoint("LEFT", lastButton, "RIGHT", 8, 0) else b:SetPoint("TOPLEFT", 20, y) end
		b:SetScript("OnClick", onClick)
		Tooltip(b, text, tooltip)
		lastButton = b
	end

	local function Checkbox(key, label, tooltip)
		local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
		cb:SetSize(26, 26)
		cb:SetPoint("TOPLEFT", 16, y)
		local text = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		text:SetPoint("LEFT", cb, "RIGHT", 4, 1)
		text:SetText(label)
		cb:SetHitRectInsets(0, -(text:GetStringWidth() + 8), 0, 0)
		cb:SetScript("OnClick", function(self)
			db[key] = self:GetChecked() and true or false
			ApplyNow()
		end)
		Tooltip(cb, label, tooltip)
		refreshers[#refreshers + 1] = function() cb:SetChecked(db[key]) end
		y = y - 28
	end

	local sliderX = 0
	local function Slider(key, label, tooltip, min, max, step, format)
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
		local name = s:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		name:SetPoint("BOTTOMLEFT", s, "TOPLEFT", 0, 2)
		name:SetText(label)
		local value = s:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		value:SetPoint("BOTTOMRIGHT", s, "TOPRIGHT", 0, 2)
		local loading = false
		s:SetScript("OnValueChanged", function(_, v)
			v = math.floor((v - min) / step + 0.5) * step + min
			value:SetText(format(v))
			if loading or db[key] == v then return end
			db[key] = v
			ApplyNow()
		end)
		Tooltip(s, label, tooltip)
		refreshers[#refreshers + 1] = function()
			loading = true
			s:SetValue(db[key])
			value:SetText(format(db[key]))
			loading = false
		end
		if sliderX == 0 then sliderX = 250 else sliderX = 0; y = y - 48 end
	end

	Button("Unlock / Lock", "Unlock, close this window and drag the title bar, then lock again.",
		function()
			ns.Print(ns.ToggleMove() and "drag the title bar, then press Unlock / Lock again (or type /fthreat move)." or "position saved.")
		end)
	Button("Reset position", "Put the list back in its default spot.", function() ns.ResetPosition() end)
	lastButton = nil
	y = y - 34

	Slider("scale", "Size", "How big the list is.", 0.5, 2, 0.05,
		function(v) return ("%d%%"):format(math.floor(v * 100 + 0.5)) end)
	Slider("maxRows", "Rows", "The most enemies listed at once.", 3, 20, 1,
		function(v) return tostring(v) end)

	-- Role: three radio buttons in a row.
	local roleLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	roleLabel:SetPoint("TOPLEFT", 20, y - 4)
	roleLabel:SetText("Role")
	local radios, x = {}, 60
	local function Radio(value, label, tooltip)
		local ok, rb = pcall(CreateFrame, "CheckButton", nil, panel, "UIRadioButtonTemplate")
		if not ok then rb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate") end
		rb:SetSize(18, 18)
		rb:SetPoint("TOPLEFT", x, y - 2)
		local text = rb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		text:SetPoint("LEFT", rb, "RIGHT", 4, 0)
		text:SetText(label)
		rb.text = text
		rb:SetHitRectInsets(0, -(text:GetStringWidth() + 8), 0, 0)
		rb:SetScript("OnClick", function()
			db.role = value
			for _, fn in ipairs(refreshers) do fn() end
			ApplyNow()
		end)
		Tooltip(rb, label, tooltip)
		radios[value] = rb
		x = x + text:GetStringWidth() + 40
		return rb
	end
	local auto = Radio("auto", "Automatic",
		"Tank in Defensive Stance, Bear Form, Righteous Fury or the tank role.")
	auto.text:SetWidth(180)
	auto.text:SetJustifyH("LEFT")
	x = x + 180 - auto.text:GetStringWidth()
	Radio("tank", "Tank")
	Radio("dps", "Damage / healing")
	refreshers[#refreshers + 1] = function()
		for value, rb in pairs(radios) do rb:SetChecked(db.role == value) end
		auto.text:SetText("Automatic |cff999999(now: " .. (ns.IsTank() and "tank" or "damage/healing") .. ")|r")
	end
	y = y - 30

	Checkbox("showOthers", "List enemies fighting people outside your group",
		"Shown in grey at the bottom, marked \"not your fight\".")
	Checkbox("flash", "Pulse red enemies",
		"A red pulse on their rows. Tanking, enemies attacking healers are listed first, then those on cloth wearers.")
	Checkbox("markNameplates", "Red arrow over red enemies",
		"Marks their nameplates in the world, so you can spot them without looking at the list.")
	Checkbox("warnLost", "Tanking: warn when an enemy leaves you",
		"Raid-warning style alert when an enemy leaves you for someone in your group.")
	Checkbox("warnAggro", "Damage / healing: warn when you pull an enemy",
		"Raid-warning style alert when an enemy turns to you.")
	Checkbox("warnSound", "Play a sound with the warnings", "The raid warning sound.")

	panel:SetScript("OnShow", function()
		for _, fn in ipairs(refreshers) do fn() end
	end)

	category = Settings.RegisterCanvasLayoutCategory(panel, "FireThreat")
	Settings.RegisterAddOnCategory(category)
end

function ns.OpenOptions()
	if not category then
		ns.Print("/fthreat move - unlock/lock, /fthreat reset - default position")
		return
	end
	local id = category.GetID and category:GetID() or category.ID
	if not (id and pcall(Settings.OpenToCategory, id)) then
		pcall(Settings.OpenToCategory, category)
	end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
	if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
		Build()
	end
end)
