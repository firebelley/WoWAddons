-- Options > AddOns > FireAuction (or /fah options), and the slash commands.
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

StaticPopupDialogs.FIREAUCTION_FORGET = {
	text = "Forget all saved auction prices for %s?",
	button1 = YES,
	button2 = NO,
	OnAccept = function()
		local realm = ns.Realm()
		if realm then
			wipe(realm.items)
			realm.lastScan = 0
		end
		ns.Window.Refresh()
		ns.Print("prices forgotten.")
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

local function Build()
	local panel = CreateFrame("Frame")
	panel:Hide()
	local refreshers = {}
	local y = -16

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, y)
	title:SetText("FireAuction")
	y = y - 24

	local about = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	about:SetPoint("TOPLEFT", 16, y)
	about:SetPoint("RIGHT", -16, 0)
	about:SetJustifyH("LEFT")
	about:SetText("Scans the auction house and keeps a price history for every item. Item tooltips show the "
		.. "lowest buyout and how it moved; the price window (/fah, a key binding, or Prices at the auction "
		.. "house) lets you search items and see their price over time. Prices are kept per realm and faction.")
	y = y - 50

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

	local lastButton
	local function Button(text, tooltip, onClick)
		local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		b:SetSize(150, 22)
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

	local function Checkbox(key, label, tooltip)
		local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
		cb:SetSize(26, 26)
		cb:SetPoint("TOPLEFT", 16, y)
		local text = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		text:SetPoint("LEFT", cb, "RIGHT", 4, 1)
		text:SetText(label)
		cb:SetHitRectInsets(0, -(text:GetStringWidth() + 8), 0, 0)
		cb:SetScript("OnClick", function(self) ns.db[key] = self:GetChecked() and true or false end)
		Tooltip(cb, label, tooltip)
		refreshers[#refreshers + 1] = function() cb:SetChecked(ns.db[key] and true or false) end
		y = y - 28
	end

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
			v = math.floor((v - min) / step + 0.5) * step + min
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

	local function Days(v) return ("%d days"):format(v) end

	Header("Scanning")
	Checkbox("autoScan", "Scan when I open the auction house",
		"Scans by itself each time you open the auction house, when the game allows one (about every 15 minutes). "
			.. "Otherwise use the Scan button above the auction house window.")

	Header("Prices")
	Checkbox("tooltip", "Show auction prices in item tooltips",
		"The lowest buyout from your latest scan, and how much it moved over the trend period.")
	Slider("historyDays", "Keep prices for",
		"How many days of prices to keep. Older days are removed at the next scan.", 7, 90, 1, Days,
		function() ns.Window.Refresh() end)
	Slider("trendDays", "Trend period",
		"How many days back the trend looks (the % in tooltips), and how far ahead the price window projects it.",
		2, 30, 1, Days, function() ns.Window.Refresh() end)
	if sliderX ~= 0 then sliderX, y = 0, y - 48 end

	y = y - 6
	Button("Open price window", "Search your saved prices and see an item's price over time (/fah).",
		function() ns.Window.Show() end)
	Button("Forget prices", "Delete every saved price for this realm and faction.", function()
		StaticPopup_Show("FIREAUCTION_FORGET", (GetRealmName() or "?") .. " (" .. (UnitFactionGroup("player") or "?") .. ")")
	end)
	EndButtons()

	panel:SetScript("OnShow", function()
		for _, fn in ipairs(refreshers) do ns.SafeCall(fn) end
	end)

	category = Settings.RegisterCanvasLayoutCategory(panel, "FireAuction")
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

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_FIREAUCTION1 = "/fah"
SLASH_FIREAUCTION2 = "/fireauction"
SlashCmdList.FIREAUCTION = function(input)
	local cmd, rest = strtrim(input or ""):match("^(%S*)%s*(.-)$")
	cmd = (cmd or ""):lower()
	if cmd == "" then
		ns.Window.Toggle()
	elseif cmd == "scan" then
		ns.Scan.Start(false)
	elseif cmd == "options" or cmd == "config" or cmd == "settings" then
		Options.Open()
	elseif cmd == "debug" then
		ns.debug = not ns.debug
		local realm = ns.Realm()
		local n = 0
		if realm then for _ in pairs(realm.items) do n = n + 1 end end
		ns.Print(("debug %s. %d items saved; last scan %s; scan state %s; next scan allowed in %ds."):format(
			ns.debug and "on" or "off", n, realm and realm.lastScan > 0 and ns.TimeAgo(realm.lastScan) or "never",
			ns.Scan.state, ns.Scan.CooldownLeft()))
	elseif cmd == "help" then
		ns.Print("commands:")
		print("  /fah - show/hide the price window")
		print("  /fah <item name> - search for an item")
		print("  /fah scan - scan the auction house (while it's open)")
		print("  /fah options - open the settings")
	else
		ns.Window.Show()
		local text = strtrim(input)
		local id = tonumber(text:match("item:(%d+)"))
		local name = text:match("%[(.-)%]") or text
		ns.Window.Search(name, id)
	end
end
