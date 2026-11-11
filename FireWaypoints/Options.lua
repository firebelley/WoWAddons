-- Options > AddOns > FireWaypoints (or /fwp options). A self-drawn ("canvas")
-- page, like the other Fire addons.
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
	title:SetText("FireWaypoints")
	y = y - 24

	local about = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	about:SetPoint("TOPLEFT", 16, y)
	about:SetPoint("RIGHT", -16, 0)
	about:SetJustifyH("LEFT")
	about:SetText("Shift-click the world map to drop a pin - as many as you like. Right-click a pin to remove it. "
		.. "Pins show on the world map and the minimap, and everyone in your group with FireWaypoints sees yours "
		.. "(and you see theirs, in their class color). /fwp 45.2 60.1 drops one at those coordinates in your zone.")
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

	Checkbox("minimap", "Show pins on the minimap",
		"Nearby pins where they are, further ones on the minimap's edge pointing the way.", ns.Changed)
	Checkbox("share", "Share your pins with your group",
		"Group members with FireWaypoints see your pins. You still see theirs either way.", ns.SharingChanged)
	y = y - 10

	local clear = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	clear:SetSize(140, 22)
	clear:SetText("Clear my pins")
	clear:SetPoint("TOPLEFT", 20, y)
	clear:SetScript("OnClick", function()
		ns.ClearMine()
		ns.Print("your pins are cleared (for your group too).")
	end)

	panel:SetScript("OnShow", function()
		for _, fn in ipairs(refreshers) do fn() end
	end)

	category = Settings.RegisterCanvasLayoutCategory(panel, "FireWaypoints")
	Settings.RegisterAddOnCategory(category)
end

function Options.Open()
	if not category then
		ns.Print("type /fwp help for the commands.")
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
