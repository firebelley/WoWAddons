-- Options > AddOns > FireChat (or /fchat). A self-drawn ("canvas") page, so the
-- game's settings search never runs into it (see FireProcs/Options.lua).
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
	title:SetText("FireChat")
	y = y - 34

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
			ns.Refresh()
		end)
		cb:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(label, 1, 1, 1)
			GameTooltip:AddLine(tooltip, nil, nil, nil, true)
			GameTooltip:Show()
		end)
		cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
		refreshers[#refreshers + 1] = function() cb:SetChecked(db[key]) end
		y = y - 26
	end

	Checkbox("hoverOnly", "Tabs and buttons on mouse-over", "Hidden until you point at the chat.")
	Checkbox("outline", "Outlined text", "Sharper text. Off: the game's shadow.")

	panel:SetScript("OnShow", function()
		for _, fn in ipairs(refreshers) do fn() end
	end)

	category = Settings.RegisterCanvasLayoutCategory(panel, "FireChat")
	Settings.RegisterAddOnCategory(category)
end

function Options.Open()
	if not category then return end
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
