-- Options > AddOns > FireRoll (or /froll options). A self-drawn ("canvas")
-- page, so the game's settings search never runs into it (see FireProcs/Options.lua).
local _, ns = ...
local Options = {}
ns.Options = Options

local category

local function Build()
	local db = ns.db
	local panel = CreateFrame("Frame")
	panel:Hide()
	local refreshers = {}
	local y = -16

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, y)
	title:SetText("FireRoll")
	y = y - 24

	local about = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	about:SetPoint("TOPLEFT", 16, y)
	about:SetPoint("RIGHT", -16, 0)
	about:SetJustifyH("LEFT")
	about:SetText("Click the dice (shown while you're in a group) to start a roll, or type /froll <what> - "
		.. "shift-click an item to roll for it. Everyone with FireRoll gets a window with Roll and Pass, and "
		.. "it shows the winner as soon as the whole group has rolled or passed (or after a minute). "
		.. "Ties roll off by themselves. Players without FireRoll can join in by typing /roll.")
	y = y - 58

	local function Checkbox(key, label, tooltip, onChange)
		local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
		cb:SetSize(26, 26)
		cb:SetPoint("TOPLEFT", 16, y)
		local text = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		text:SetPoint("LEFT", cb, "RIGHT", 4, 1)
		text:SetText(label)
		cb:SetHitRectInsets(0, -(text:GetStringWidth() + 8), 0, 0)
		cb:SetScript("OnClick", function(self)
			db[key] = self:GetChecked() and true or false
			if onChange then onChange() end
		end)
		cb:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(label, 1, 1, 1)
			if tooltip then GameTooltip:AddLine(tooltip, nil, nil, nil, true) end
			GameTooltip:Show()
		end)
		cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
		refreshers[#refreshers + 1] = function() cb:SetChecked(db[key]) end
		y = y - 28
	end

	Checkbox("button", "Show the dice button while in a group",
		"Drag it to move it. You can always start a roll with /froll instead.", ns.UI.UpdateButton)
	Checkbox("chat", "Tell players without FireRoll in group chat",
		"When you start a roll and someone in the group doesn't have FireRoll, a line in group chat "
		.. "asks them to /roll, and another says who won. Nothing is posted when everyone has it.")
	y = y - 10

	local function PanelButton(text, width, onClick)
		local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		b:SetSize(width, 22)
		b:SetText(text)
		b:SetScript("OnClick", onClick)
		return b
	end
	local test = PanelButton("Try it", 100, function() ns.Start("Test chest", nil, true) end)
	test:SetPoint("TOPLEFT", 20, y)
	local reset = PanelButton("Reset positions", 130, function() ns.UI.ResetPositions() end)
	reset:SetPoint("LEFT", test, "RIGHT", 8, 0)

	panel:SetScript("OnShow", function()
		for _, fn in ipairs(refreshers) do fn() end
	end)

	category = Settings.RegisterCanvasLayoutCategory(panel, "FireRoll")
	Settings.RegisterAddOnCategory(category)
end

function Options.Open()
	if not category then
		ns.Print("type /froll help for the commands.")
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
