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
		for _, house in ipairs({ "faction", "neutral" }) do
			local realm = ns.Realm(house)
			if realm then
				wipe(realm.items)
				realm.lastScan = 0
				realm.syncedFull = nil
			end
		end
		ns.Window.Refresh()
		ns.BagIcons.Refresh()
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
	about:SetText("Scans the auction house and keeps a price history. Prices show in item tooltips and the price "
		.. "window (/fah). Your faction's and the neutral auction house are kept separately.")
	y = y - 36

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
		ns.ClickSound(b)
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
		cb:SetHitRectInsets(0, -(text:GetStringWidth() + 8), 0, 0)
		cb:SetScript("OnClick", function(self)
			ns.db[key] = self:GetChecked() and true or false
			if onChange then ns.SafeCall(onChange) end
		end)
		ns.ClickSound(cb)
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
		"Scans when you open the auction house, if the game allows one (about every 15 minutes).")

	Header("Prices")
	Checkbox("minimapButton", "Show the minimap button",
		"Click for the price window, right-click for options. Drag to move.",
		function() ns.MinimapButton.Update() end)
	Checkbox("tooltip", "Show auction prices in item tooltips",
		"Market price and trend from your latest scan, plus the lowest listing when it's noticeably cheaper.")
	Slider("historyDays", "Keep prices for",
		"How many days of prices to keep. Older days are removed at the next scan.", 7, 90, 1, Days,
		function() ns.Window.Refresh() end)
	Slider("trendDays", "Trend period",
		"How many days back the trend looks (the % in tooltips), and how far ahead the price window projects it.",
		2, 30, 1, Days, function() ns.Window.Refresh() end)
	if sliderX ~= 0 then sliderX, y = 0, y - 48 end

	-- An amount of money: "[ 0 ] g  [ 50 ] s".
	local function MoneyInput(key, label, tooltip, onChange)
		local name = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		name:SetPoint("TOPLEFT", 46, y - 6)
		name:SetText(label)
		local boxes = {}
		local function Save()
			local g = tonumber(boxes[1]:GetText()) or 0
			local s = math.min(99, tonumber(boxes[2]:GetText()) or 0)
			local value = math.max(0, math.floor(g) * 10000 + math.floor(s) * 100)
			if ns.db[key] ~= value then
				ns.db[key] = value
				if onChange then ns.SafeCall(onChange) end
			end
		end
		local x = 46 + name:GetStringWidth() + 14
		for i, coin in ipairs({ "g", "s" }) do
			local box = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
			box:SetSize(i == 1 and 50 or 30, 20)
			box:SetPoint("TOPLEFT", x, y - 2)
			box:SetAutoFocus(false)
			box:SetNumeric(true)
			box:SetMaxLetters(i == 1 and 6 or 2)
			box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
			box:SetScript("OnEditFocusLost", Save)
			Tooltip(box, label, tooltip)
			local unit = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
			unit:SetPoint("LEFT", box, "RIGHT", 4, 0)
			unit:SetText(coin == "g" and "|TInterface\\MoneyFrame\\UI-GoldIcon:0|t" or "|TInterface\\MoneyFrame\\UI-SilverIcon:0|t")
			boxes[i] = box
			x = x + (i == 1 and 50 or 30) + 26
		end
		refreshers[#refreshers + 1] = function()
			local v = ns.db[key] or 0
			boxes[1]:SetText(tostring(math.floor(v / 10000)))
			boxes[2]:SetText(tostring(math.floor(v / 100) % 100))
		end
		y = y - 30
	end

	Header("Bags")
	Checkbox("markValuable", "Mark valuable items in my bags",
		"A gold coin on bag items worth at least this much each. Soulbound items are skipped.",
		function() ns.BagIcons.Refresh() end)
	MoneyInput("markPrice", "Worth at least", "The auction price per item that gets the gold coin.",
		function() ns.BagIcons.Refresh() end)

	Header("Selling")
	Checkbox("announceSales", "Announce when one of my auctions sells",
		"A big on-screen message and coin sound when something sells. Gold waiting in the mail shows on the "
			.. "minimap button's tooltip.")

	Header("Crafting")
	Checkbox("craftProfit", "Show crafting profit in profession windows",
		"Sell price (after the 5% cut) minus reagent costs, under the selected recipe. Hover for the breakdown.",
		function() ns.Crafting.Refresh() end)
	Checkbox("craftWorth", "Show crafting profit for reagents in item tooltips",
		"Profit per reagent bought at the lowest price and crafted with your best recipe. Recipes are saved when "
			.. "you open a profession window.")

	y = y - 6
	Button("Open price window", "Search your saved prices and see an item's price over time (/fah).",
		function() ns.Window.Show() end)
	Button("Forget prices", "Delete all saved prices for this realm.", function()
		StaticPopup_Show("FIREAUCTION_FORGET", (GetRealmName() or "?") .. " (" .. (UnitFactionGroup("player") or "?") .. " and neutral)")
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
	elseif cmd == "sales" then
		ns.Sales.Print()
	elseif cmd == "auctions" or cmd == "listings" or cmd == "listed" then
		ns.Sales.PrintListings()
	elseif cmd == "testsale" then
		ns.Sales.Test()
	elseif cmd == "sync" then
		ns.Sync.Now()
	elseif cmd == "options" or cmd == "config" or cmd == "settings" then
		Options.Open()
	elseif cmd == "debug" then
		ns.debug = not ns.debug
		ns.Print(("debug %s. Scan state %s; next scan allowed in %ds."):format(
			ns.debug and "on" or "off", ns.Scan.state, ns.Scan.CooldownLeft()))
		for _, house in ipairs({ "faction", "neutral" }) do
			local realm = ns.Realm(house)
			local n = 0
			if realm then for _ in pairs(realm.items) do n = n + 1 end end
			print(("  %s prices: %d items, %s"):format(ns.HouseName(house), n,
				ns.LastScanText(realm) or "never scanned"))
		end
		print("  " .. ns.Scan.HouseDebug())
		print("  " .. ns.Sync.Status())
	elseif cmd == "help" then
		ns.Print("commands:")
		print("  /fah - show/hide the price window")
		print("  /fah <item name> - search for an item")
		print("  /fah scan - scan the auction house (while it's open)")
		print("  /fah sales - what's sold and waiting in the mailbox")
		print("  /fah auctions - what you have listed, with time left")
		print("  /fah testsale - show what a sale announcement looks like")
		print("  /fah sync - get newer prices from your guild now (it also happens by itself)")
		print("  /fah options - open the settings")
	else
		ns.Window.Show()
		local text = strtrim(input)
		local id = tonumber(text:match("item:(%d+)"))
		local name = text:match("%[(.-)%]") or text
		ns.Window.Search(name, id)
	end
end
