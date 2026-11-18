-- The tracked todos on screen, like the quest tracker: each with its checkbox.
-- The header: the list button (or click the header) opens the list, the -/+
-- collapses it. A todo: click for it in the list, right-click to untrack it.
-- Placed, sized and turned on or off in Edit Mode (EditMode.lua): it's as wide
-- as set there, and as tall as its todos up to the height set there.
local _, ns = ...
local Todo = ns.Todo

local Tracker = {}
ns.Tracker = Tracker

local HEADER = 20
Tracker.WIDTH, Tracker.HEIGHT = 230, 300 -- defaults
Tracker.MIN_W, Tracker.MAX_W, Tracker.MIN_H, Tracker.MAX_H = 150, 600, 60, 900
local POINT = { "TOPRIGHT", "TOPRIGHT", -90, -300 }

local tracker, header, collapse, more
local lines = {}
local editing = false

function Tracker.Enabled() return ns.db.trackerShown ~= false end

function Tracker.Size()
	return ns.db.trackerWidth or Tracker.WIDTH, ns.db.trackerHeight or Tracker.HEIGHT
end

function Tracker.Place()
	if not tracker then return end
	local p = ns.db.trackerPoint or POINT
	tracker:ClearAllPoints()
	tracker:SetPoint(p[1], UIParent, p[2], p[3], p[4])
end

-- Kept from its top left, so it grows downward wherever it is.
function Tracker.Pin()
	local x, y = tracker:GetLeft(), tracker:GetTop()
	if not (x and y) then return end
	x, y = math.floor(x + 0.5), math.floor(y + 0.5)
	ns.db.trackerPoint = { "TOPLEFT", "BOTTOMLEFT", x, y }
	Tracker.Place()
end

local function Tip(owner, text)
	GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
	GameTooltip:SetText(text, 1, 1, 1)
	GameTooltip:Show()
end

local function CreateLine()
	local line = CreateFrame("Button", nil, tracker)
	line:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	ns.Hyperlinks(line)
	local check = CreateFrame("CheckButton", nil, line, "UICheckButtonTemplate")
	check:SetSize(20, 20)
	check:SetPoint("TOPLEFT", -2, 2)
	check:SetScript("OnClick", function(self) Todo.SetDone(line.id, self:GetChecked()) end)
	line.check = check
	local text = line:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	text:SetPoint("TOPLEFT", 20, -2)
	text:SetJustifyH("LEFT")
	text:SetWordWrap(true)
	line.text = text
	line:SetScript("OnClick", function(self, button)
		local id = self.id
		ns.UnlessLink(self, function()
			if button == "RightButton" then
				Todo.SetTracked(id, false)
			else
				ns.Window.ShowTodo(id)
			end
		end)
	end)
	return line
end

local function Build()
	tracker = CreateFrame("Frame", "FireTodoTracker", UIParent)
	tracker:SetSize(Tracker.Size())
	tracker:SetMovable(true)
	tracker:SetClampedToScreen(true)
	if tracker.SetDontSavePosition then tracker:SetDontSavePosition(true) end
	Tracker.Place()

	header = CreateFrame("Button", nil, tracker)
	header:SetPoint("TOPLEFT")
	header:SetPoint("TOPRIGHT")
	header:SetHeight(HEADER)
	header.text = header:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	header.text:SetPoint("LEFT", 0, 0)
	header:SetScript("OnClick", function() ns.Window.Toggle() end)

	collapse = CreateFrame("Button", nil, header)
	collapse:SetSize(16, 16)
	collapse:SetPoint("RIGHT", 0, 0)
	collapse:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight", "ADD")
	collapse:SetScript("OnClick", function()
		ns.db.trackerCollapsed = not ns.db.trackerCollapsed or nil
		Tracker.Refresh()
	end)

	local list = CreateFrame("Button", nil, header)
	list:SetSize(16, 16)
	list:SetPoint("RIGHT", collapse, "LEFT", -4, 0)
	list:SetNormalTexture("Interface\\Buttons\\UI-GuildButton-PublicNote-Up")
	list:SetPushedTexture("Interface\\Buttons\\UI-GuildButton-PublicNote-Down")
	list:SetHighlightTexture("Interface\\Buttons\\UI-GuildButton-PublicNote-Up", "ADD")
	list:SetScript("OnClick", function() ns.Window.Toggle() end)
	list:SetScript("OnEnter", function(self) Tip(self, "Todo list") end)
	list:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- Todos past the height set in Edit Mode.
	more = CreateFrame("Button", nil, tracker)
	more:SetHeight(14)
	more.text = more:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	more.text:SetPoint("LEFT", 20, 0)
	more:SetScript("OnClick", function() ns.Window.Show() end)
	tracker:Hide() -- until Refresh (it may be off)
end

function Tracker.Frame()
	if not tracker then Build() end
	return tracker
end

-- In Edit Mode it shows at the size set (EditMode.lua), even with nothing tracked.
function Tracker.SetEditing(on)
	editing = on
	Tracker.Refresh()
end

function Tracker.Refresh()
	if not ns.db then return end
	if not Tracker.Enabled() then
		if tracker then tracker:Hide() end
		return
	end
	if not tracker then Build() end
	local width, maxHeight = Tracker.Size()
	tracker:SetWidth(width)
	local shown = {}
	for _, t in ipairs(Todo.List()) do
		if t.tracked then shown[#shown + 1] = t end
	end
	local collapsed = ns.db.trackerCollapsed and #shown > 0
	local open = 0
	for _, t in ipairs(shown) do
		if not t.done then open = open + 1 end
	end
	header.text:SetText(collapsed and ("Todo (" .. open .. ")") or "Todo")
	collapse:SetShown(#shown > 0)
	collapse:SetNormalTexture(collapsed and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up")
	collapse:SetPushedTexture(collapsed and "Interface\\Buttons\\UI-PlusButton-Down" or "Interface\\Buttons\\UI-MinusButton-Down")

	local y, hidden = HEADER + 2, 0
	for i, t in ipairs(shown) do
		local line = lines[i]
		if not line then
			line = CreateLine()
			lines[i] = line
		end
		line:Hide()
		if not collapsed and hidden == 0 then
			line.id = t.id
			line.text:SetWidth(width - 20)
			line.text:SetText(t.text)
			line.text:SetAlpha(t.done and 0.45 or 1)
			line.check:SetChecked(t.done == true)
			local h = math.max(18, math.ceil(line.text:GetStringHeight()) + 6)
			-- Room for it (and for "N more" if others follow)?
			if y + h + (i < #shown and 14 or 0) <= maxHeight then
				line:ClearAllPoints()
				line:SetPoint("TOPLEFT", tracker, "TOPLEFT", 0, -y)
				line:SetSize(width, h)
				line:Show()
				y = y + h
			else
				hidden = #shown - i + 1
			end
		end
	end
	for i = #shown + 1, #lines do lines[i]:Hide() end
	more:SetShown(hidden > 0)
	if hidden > 0 then
		more.text:SetText(hidden .. " more")
		more:ClearAllPoints()
		more:SetPoint("TOPLEFT", tracker, "TOPLEFT", 0, -y)
		more:SetWidth(width)
		y = y + 14
	end
	tracker:SetHeight(editing and maxHeight or (collapsed and HEADER or y))
	tracker:Show()
end

ns.OnChange(Tracker.Refresh)
