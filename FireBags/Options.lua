-- Options > AddOns > FireBags (or /fbags options).
-- A self-drawn ("canvas") page, so the game's settings search never runs into
-- it (see FireProcs/Options.lua for why that matters).
local _, ns = ...

local Options = {}
ns.Options = Options

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

local function RefreshWindows()
	for _, w in ipairs(ns.windows) do w:RequestRefresh() end
end

local function Build()
	local panel = CreateFrame("Frame")
	panel:Hide()
	local refreshers = {} -- re-read the settings into the widgets each time the page opens
	local y = -16         -- next free spot, top to bottom

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, y)
	title:SetText("FireBags")
	y = y - 30

	local function Header(text)
		y = y - 8
		local h = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
		h:SetPoint("TOPLEFT", 16, y)
		h:SetText(text)
		local line = panel:CreateTexture(nil, "ARTWORK")
		line:SetColorTexture(1, 1, 1, 0.15)
		line:SetHeight(1)
		line:SetPoint("LEFT", h, "RIGHT", 8, 0)
		line:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
		y = y - 24
	end

	-- Buttons go side by side on one row.
	local lastButton
	local function Button(text, tooltip, onClick)
		local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		b:SetSize(130, 22)
		b:SetText(text)
		if lastButton then
			b:SetPoint("LEFT", lastButton, "RIGHT", 8, 0)
		else
			b:SetPoint("TOPLEFT", 20, y)
		end
		b:SetScript("OnClick", function() ns.SafeCall(onClick) end)
		Tooltip(b, text, tooltip)
		lastButton = b
	end
	local function EndButtons()
		lastButton = nil
		y = y - 34
	end

	local function Checkbox(key, label, tooltip, onChange)
		local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
		cb:SetSize(26, 26)
		cb:SetPoint("TOPLEFT", 16, y)
		local text = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		text:SetPoint("LEFT", cb, "RIGHT", 4, 1)
		text:SetText(label)
		cb:SetHitRectInsets(0, -(text:GetStringWidth() + 8), 0, 0) -- clicking the label works too
		cb:SetScript("OnClick", function(self)
			ns.db[key] = self:GetChecked() and true or false
			if onChange then ns.SafeCall(onChange) end
		end)
		Tooltip(cb, label, tooltip)
		refreshers[#refreshers + 1] = function() cb:SetChecked(ns.db[key] and true or false) end
		y = y - 28
	end

	-- One choice out of a few: "Label:  (o) A  ( ) B  ( ) C" on one row.
	local function Choice(key, label, tooltip, choices, onChange)
		local name = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		name:SetPoint("TOPLEFT", 20, y - 6)
		name:SetText(label)
		local buttons = {}
		local x = 20 + math.max(110, name:GetStringWidth() + 12)
		for _, choice in ipairs(choices) do
			local ok, rb = pcall(CreateFrame, "CheckButton", nil, panel, "UIRadioButtonTemplate")
			if not ok then rb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate") end
			rb:SetSize(18, 18)
			rb:SetPoint("TOPLEFT", x, y - 4)
			local text = rb:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
			text:SetPoint("LEFT", rb, "RIGHT", 2, 0)
			text:SetText(choice.label)
			rb:SetHitRectInsets(0, -(text:GetStringWidth() + 6), 0, 0)
			rb:SetScript("OnClick", function()
				ns.db[key] = choice.value
				for _, other in ipairs(buttons) do other:SetChecked(other == rb) end
				if onChange then ns.SafeCall(onChange) end
			end)
			Tooltip(rb, label .. " " .. choice.label, choice.tooltip or tooltip)
			rb.fbValue = choice
			buttons[#buttons + 1] = rb
			x = x + 18 + text:GetStringWidth() + 22
		end
		refreshers[#refreshers + 1] = function()
			for _, rb in ipairs(buttons) do
				local c = rb.fbValue
				rb:SetChecked(ns.db[key] == c.value or (c.also and ns.db[key] == c.also) or false)
			end
		end
		y = y - 28
	end

	-- Sliders in the classic options look; two fit side by side.
	local sliderX = 0
	local function Slider(key, label, tooltip, min, max, step, format, onChange)
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
		s:SetScript("OnValueChanged", function(self, v)
			v = math.floor((v - min) / step + 0.5) * step + min -- snap to the step
			value:SetText(format(v))
			if loading or ns.db[key] == v then return end
			ns.db[key] = v
			if onChange then ns.SafeCall(onChange) end
		end)
		s:SetScript("OnMouseWheel", function(self, delta)
			self:SetValue(math.max(min, math.min(max, self:GetValue() + delta * step)))
		end)
		Tooltip(s, label, tooltip)
		refreshers[#refreshers + 1] = function()
			loading = true
			s:SetValue(ns.db[key])
			value:SetText(format(ns.db[key]))
			loading = false
		end

		if sliderX == 0 then
			sliderX = 250
		else
			sliderX = 0
			y = y - 48
		end
	end
	local function EndSliders()
		if sliderX ~= 0 then sliderX, y = 0, y - 48 end
	end

	local function Slots(v) return ("%d per row"):format(v) end

	Header("Windows")
	Button("Reset positions", "Put the bag and bank windows back where they started.", function()
		wipe(ns.db.positions)
		for _, w in ipairs(ns.windows) do w:ApplyPosition() end
	end)
	Button("Open bank", "Browse your bank from anywhere (what it held the last time you visited a banker).",
		function() ns.ToggleBank() end)
	EndButtons()
	Slider("scale", "Size", "How big the bag and bank windows are.", 0.5, 2, 0.05,
		function(v) return ("%d%%"):format(math.floor(v * 100 + 0.5)) end, ns.ApplyWindowSettings)
	Slider("columns", "Bag slots", "How many slots fit in one row of the bag window.", 6, 24, 1, Slots, RefreshWindows)
	Slider("bankColumns", "Bank slots", "How many slots fit in one row of the bank window.", 6, 24, 1, Slots, RefreshWindows)
	EndSliders()
	Checkbox("locked", "Lock window positions", "Stop the windows from being dragged by accident.")
	Choice("background", "Background:", "What's behind the slots.", {
		{ value = "default", label = "Default" },
		{ value = "rock", label = "Rock" },
		{ value = "marble", label = "Marble" },
		{ value = "dark", label = "Dark" },
	}, function()
		for _, w in ipairs(ns.windows) do w:ApplyBackground() end
	end)

	Header("Bags")
	Checkbox("showKeyring", "Show the keyring", "Show your keys in their own section of the bag window.",
		function() ns.inventory:RequestRefresh() end)
	Checkbox("newItemGlow", "Make new items glow", "Items you just got glow until you look at them.",
		function() ns.inventory:RequestRefresh() end)
	Choice("sortMode", "Sort with:", nil, {
		{ value = "auto", also = "blizzard", label = "The game's sort",
			tooltip = "The game's own sorting (smooth and quick). FireBags' sorter is used if the game has none." },
		{ value = "custom", label = "FireBags' sorter",
			tooltip = "FireBags' own sorting, which moves one item at a time (slower)." },
	})

	Header("Counts")
	Checkbox("tooltipCounts", "Bag and bank counts in item tooltips",
		"\"Bags: 12   Bank: 40\" on item tooltips (bank as of your last visit).")
	Checkbox("craftCounts", "Count your bank in profession windows",
		"Extra crafts from your bank, in blue: [1+3]. Reopen the profession window to apply.")
	Checkbox("craftVendor", "Show what buying vendor reagents would add",
		"Extra crafts if you bought vendor reagents (thread, dye...), in gold: [1+3+2]. Hover a recipe for what "
			.. "to buy. Reopen the profession window to apply.")

	panel:SetScript("OnShow", function()
		for _, fn in ipairs(refreshers) do ns.SafeCall(fn) end
	end)

	category = Settings.RegisterCanvasLayoutCategory(panel, "FireBags")
	Settings.RegisterAddOnCategory(category)
end

function Options.Open()
	if not category then
		ns.Print("the options page isn't available on this client.")
		return
	end
	local id = category.GetID and category:GetID() or category.ID
	if not (id and pcall(Settings.OpenToCategory, id)) then
		pcall(Settings.OpenToCategory, category)
	end
end

ns.On("PLAYER_LOGIN", function()
	if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
		ns.SafeCall(Build)
	end
end)
