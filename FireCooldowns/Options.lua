-- Options > AddOns > FireCooldowns (or /fcd). A self-drawn ("canvas") page,
-- so the game's settings search never runs into it (see FireProcs/Options.lua).
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
	title:SetText("FireCooldowns")
	y = y - 24

	local about = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	about:SetPoint("TOPLEFT", 16, y)
	about:SetPoint("RIGHT", -16, 0)
	about:SetJustifyH("LEFT")
	about:SetText("Transmute and other crafting cooldowns, on all your characters. Move the list in Edit Mode.")
	y = y - 30

	local function Checkbox(key, label, tooltip, indent)
		local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
		cb:SetSize(26, 26)
		cb:SetPoint("TOPLEFT", 16 + (indent or 0), y)
		local text = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		text:SetPoint("LEFT", cb, "RIGHT", 4, 1)
		text:SetText(label)
		cb:SetHitRectInsets(0, -(text:GetStringWidth() + 8), 0, 0)
		cb:SetScript("OnClick", function(self)
			db[key] = self:GetChecked() and true or false
			ns.Display.Refresh()
			for _, fn in ipairs(refreshers) do fn() end
		end)
		cb:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(label, 1, 1, 1)
			GameTooltip:AddLine(tooltip, nil, nil, nil, true)
			GameTooltip:Show()
		end)
		cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
		refreshers[#refreshers + 1] = function()
			cb:SetChecked(db[key])
			if indent then
				local on = db.shown
				cb:SetEnabled(on)
				text:SetFontObject(on and "GameFontHighlight" or "GameFontDisable")
			end
		end
		y = y - 28
	end

	Checkbox("shown", "Show on screen", "Each cooldown and its time left. Ready ones stay until used.")
	Checkbox("alts", "Other characters", "Their cooldowns too, with their name.", 20)
	Checkbox("readyOnly", "Only when ready", "Hide cooldowns still counting down.", 20)
	Checkbox("sound", "Sound", "When a cooldown is ready.")
	y = y - 10

	local test = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	test:SetSize(100, 22)
	test:SetText("Try it")
	test:SetPoint("TOPLEFT", 20, y)
	test:SetScript("OnClick", function() SlashCmdList.FIRECOOLDOWNS("test") end)
	test:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Try it", 1, 1, 1)
		GameTooltip:AddLine("A pretend transmute, ready in 10 seconds.", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	test:SetScript("OnLeave", function() GameTooltip:Hide() end)

	local clear = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	clear:SetSize(100, 22)
	clear:SetText("Clear tests")
	clear:SetPoint("LEFT", test, "RIGHT", 8, 0)
	clear:SetScript("OnClick", function() SlashCmdList.FIRECOOLDOWNS("test clear") end)

	panel:SetScript("OnShow", function()
		for _, fn in ipairs(refreshers) do fn() end
	end)

	category = Settings.RegisterCanvasLayoutCategory(panel, "FireCooldowns")
	Settings.RegisterAddOnCategory(category)
end

function Options.Open()
	if not category then
		ns.Print("type /fcd help for the commands.")
		return
	end
	local id = category.GetID and category:GetID() or category.ID
	if not (id and pcall(Settings.OpenToCategory, id)) then
		pcall(Settings.OpenToCategory, category)
	end
end

function Options.Init()
	if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
		Build()
	end
end
