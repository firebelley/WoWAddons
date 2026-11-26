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
	about:SetText("Shift-click the world map to drop a pin, click it to track it, shift-right-click to remove it. Your group sees your pins if "
		.. "they have FireWaypoints, and your guild shows on the map. /fwp 45.2 60.1 drops one at those coordinates. "
		.. "Your group's tracked quests show on your minimap.")
	y = y - 48

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
	Checkbox("guild", "Show your guild on the map",
		"Guild members with FireWaypoints show as dots on the map and minimap, and see where you are. Off: neither.",
		function() ns.Guild.Changed() end)
	Checkbox("quests", "Show your group's quest areas",
		"The area of the quest each group member is following, on your minimap, if they have FireWaypoints. They see yours. Off: neither.",
		function() ns.Quests.Changed() end)
	y = y - 10

	-- A size slider (the classic options slider look).
	local function Slider(key, label, tooltip, onChange)
		local min, max, step = 0.5, 3, 0.1
		local function Format(v) return ("%d%%"):format(math.floor(v * 100 + 0.5)) end
		local ok, s = pcall(CreateFrame, "Slider", nil, panel, "BackdropTemplate")
		if not ok then s = CreateFrame("Slider", nil, panel) end
		s:SetOrientation("HORIZONTAL")
		s:SetSize(200, 17)
		s:SetPoint("TOPLEFT", 24, y - 18)
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
			value:SetText(Format(v))
			if loading or db[key] == v then return end
			db[key] = v
			onChange()
		end)
		s:SetScript("OnMouseWheel", function(self, delta)
			self:SetValue(math.max(min, math.min(max, self:GetValue() + delta * step)))
		end)
		s:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(label, 1, 1, 1)
			GameTooltip:AddLine(tooltip, nil, nil, nil, true)
			GameTooltip:Show()
		end)
		s:SetScript("OnLeave", function() GameTooltip:Hide() end)
		refreshers[#refreshers + 1] = function()
			loading = true
			s:SetValue(db[key])
			value:SetText(Format(db[key]))
			loading = false
		end
		y = y - 48
	end

	Slider("minimapScale", "Minimap pin size", "How big pins are on the minimap, nearby and on its edge.", ns.Changed)
	Slider("guildScale", "Guild dot size", "How big guild members' dots are on the map and minimap.", ns.Changed)

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
