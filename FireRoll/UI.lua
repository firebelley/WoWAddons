-- The roll window and the dice button.
local _, ns = ...
local UI = {}
ns.UI = UI

local WIDTH = 262 -- room for Roll, Pass and End now with even padding on both sides
local ROW_H = 18
local MAX_ROWS = 15
local CLOSE_AFTER = 30 -- seconds a finished roll stays up (unless the mouse is over it)
local DICE = "Interface\\Buttons\\UI-GroupLoot-Dice-Up"

local frame, button
local rows = {}

local function ClassColor(class)
	local c = class and ((C_ClassColor and C_ClassColor.GetClassColor and C_ClassColor.GetClassColor(class))
		or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]))
	if c then return c.r, c.g, c.b end
	return 1, 1, 1
end

local function Colored(r, key)
	local cr, cg, cb = ClassColor(r.class[key])
	return ("|cff%02x%02x%02x%s|r"):format(cr * 255, cg * 255, cb * 255, ns.Describe(key))
end

local function PlaySoundSafe(id)
	if id then pcall(PlaySound, id, "SFX") end
end

local function SavePoint(f, key)
	local point, _, rel, x, y = f:GetPoint()
	ns.db[key] = { point, rel, x, y }
end

local function RestorePoint(f, key, default)
	local p = ns.db[key] or default
	f:ClearAllPoints()
	f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
end

local WINDOW_DEFAULT = { "CENTER", "CENTER", 320, 120 }
local BUTTON_DEFAULT = { "BOTTOM", "BOTTOM", 300, 150 }

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local function Button(parent, text, width, onClick)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(text)
	b:SetScript("OnClick", onClick)
	return b
end

local function Row(i)
	if rows[i] then return rows[i] end
	local row = CreateFrame("Frame", nil, frame)
	row:SetSize(WIDTH - 24, ROW_H)
	row:SetPoint("TOPLEFT", 12, -44 - (i - 1) * ROW_H)
	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()
	row.bg:SetColorTexture(1, 0.82, 0, 0.15)
	row.name = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	row.name:SetPoint("LEFT", 4, 0)
	row.name:SetPoint("RIGHT", -70, 0)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)
	row.value = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	row.value:SetPoint("RIGHT", -4, 0)
	row.value:SetJustifyH("RIGHT")
	rows[i] = row
	return row
end

local function Build()
	frame = CreateFrame("Frame", "FireRollFrame", UIParent, "BackdropTemplate")
	frame:SetSize(WIDTH, 120)
	frame:SetFrameStrata("DIALOG")
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		SavePoint(self, "windowPoint")
	end)
	if frame.SetBackdrop then
		frame:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 16,
			insets = { left = 4, right = 4, top = 4, bottom = 4 },
		})
		frame:SetBackdropColor(0.05, 0.05, 0.05, 0.92)
		frame:SetBackdropBorderColor(0.8, 0.6, 0.2, 1)
	end
	RestorePoint(frame, "windowPoint", WINDOW_DEFAULT)
	frame:Hide()
	tinsert(UISpecialFrames, "FireRollFrame") -- Escape closes it

	local icon = frame:CreateTexture(nil, "ARTWORK")
	icon:SetSize(24, 24)
	icon:SetPoint("TOPLEFT", 10, -10)
	icon:SetTexture(DICE)

	frame.title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	frame.title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 6, 0)
	frame.title:SetPoint("RIGHT", -28, 0)
	frame.title:SetJustifyH("LEFT")
	frame.title:SetWordWrap(false)

	frame.sub = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	frame.sub:SetPoint("TOPLEFT", frame.title, "BOTTOMLEFT", 0, -2)
	frame.sub:SetPoint("RIGHT", -28, 0)
	frame.sub:SetJustifyH("LEFT")

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 0, 0)

	frame.result = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	frame.result:SetPoint("LEFT", 12, 0)
	frame.result:SetPoint("RIGHT", -12, 0)

	frame.more = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	frame.more:SetPoint("LEFT", 16, 0)

	frame.roll = Button(frame, "Roll", 80, function() ns.Roll() end)
	frame.pass = Button(frame, "Pass", 70, function() ns.Pass() end)
	frame.finish = Button(frame, "End now", 80, function() ns.Finish() end)
	frame.finish:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("End now", 1, 1, 1)
		GameTooltip:AddLine("Decide the roll with whoever has rolled so far.", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	frame.finish:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- Rolled (highest first), then passed, then still waiting, then gone.
local function Sorted(r)
	local list = {}
	for i, key in ipairs(r.members) do list[i] = key end
	local function Rank(key)
		local v = r.status[key]
		if type(v) == "number" then return 0, -v end
		if v == "pass" then return 1, 0 end
		if r.gone[key] then return 3, 0 end
		return 2, 0
	end
	local order = {}
	for i, key in ipairs(r.members) do order[key] = i end
	table.sort(list, function(a, b)
		local ga, va = Rank(a)
		local gb, vb = Rank(b)
		if ga ~= gb then return ga < gb end
		if va ~= vb then return va < vb end
		return order[a] < order[b]
	end)
	return list
end

local function StatusText(r, key)
	local v = r.status[key]
	if type(v) == "number" then return ("|cffffffff%d|r"):format(v) end
	if v == "pass" then return "|cff888888pass|r" end
	if r.gone[key] then return "|cff888888" .. r.gone[key] .. "|r" end
	if r.done then return "|cff888888no roll|r" end
	if key == ns.Me() and r.rolling then return "|cffaaaaaarolling...|r" end
	if r.helloDone and not r.addon[key] then return "|cffaaaaaa/roll|r" end
	return "|cffaaaaaawaiting|r"
end

local function ResultLine(r)
	if #r.winners == 0 then return "|cffaaaaaaNobody rolled.|r" end
	if #r.winners > 1 then
		local names = {}
		for i, key in ipairs(r.winners) do names[i] = Colored(r, key) end
		return ("Tie at %d: %s|n|cffaaaaaaroll-off coming up|r"):format(r.best, table.concat(names, ", "))
	end
	local key = r.winners[1]
	if key == ns.Me() then return ("|cff40ff40You win!|r (%d)"):format(r.best) end
	return ("%s |cffffd100wins|r (%d)"):format(Colored(r, key), r.best)
end

function UI.Update()
	local r = ns.roll
	if not (frame and frame:IsShown() and r) then return end
	local me = ns.Me()

	local what = r.label or "Roll"
	frame.title:SetText(r.rolloff and (what .. " - roll-off") or what)
	local sub = r.by == me and "your roll" or ("started by " .. r.by)
	if not r.done then
		local left = math.max(0, math.ceil(r.endsAt - GetTime()))
		sub = ("%s - waiting for %d - %ds"):format(sub, ns.Waiting(r), left)
	end
	if r.test then sub = sub .. " (test)" end
	frame.sub:SetText(sub)

	-- Highlight the leader while rolling, the winner(s) once done.
	local top = {}
	if r.done then
		for _, key in ipairs(r.winners) do top[key] = true end
	else
		local best
		for _, key in ipairs(r.members) do
			local v = r.status[key]
			if type(v) == "number" and (not best or v > best) then best = v end
		end
		for _, key in ipairs(r.members) do
			if best and r.status[key] == best then top[key] = true end
		end
	end

	local list = Sorted(r)
	local shown = math.min(#list, MAX_ROWS)
	for i = 1, shown do
		local row, key = Row(i), list[i]
		row.name:SetText(Colored(r, key))
		row.value:SetText(StatusText(r, key))
		row.bg:SetShown(top[key] or false)
		row:Show()
	end
	for i = shown + 1, #rows do rows[i]:Hide() end

	local y = -44 - shown * ROW_H
	if #list > shown then
		frame.more:SetText(("and %d more"):format(#list - shown))
		frame.more:ClearAllPoints()
		frame.more:SetPoint("TOPLEFT", 16, y - 2)
		frame.more:Show()
		y = y - 16
	else
		frame.more:Hide()
	end
	if #list == 0 then
		frame.more:SetText("nobody in this roll")
		frame.more:ClearAllPoints()
		frame.more:SetPoint("TOPLEFT", 16, y - 2)
		frame.more:Show()
		y = y - 16
	end
	y = y - 8

	local canRoll = not r.done and ns.IsMember(r, me) and r.status[me] == nil and not r.gone[me]
	local canEnd = not r.done and (r.by == me or r.test)
	frame.roll:SetShown(canRoll)
	frame.pass:SetShown(canRoll)
	frame.roll:SetEnabled(not r.rolling)
	frame.finish:SetShown(canEnd)

	if r.done then
		frame.result:SetText(ResultLine(r))
		frame.result:ClearAllPoints()
		frame.result:SetPoint("TOPLEFT", 12, y)
		frame.result:SetPoint("RIGHT", -12, 0)
		frame.result:Show()
		y = y - frame.result:GetStringHeight() - 10
	else
		frame.result:Hide()
	end

	if canRoll or canEnd then
		local x = 12
		for _, b in ipairs({ frame.roll, frame.pass, frame.finish }) do
			if b:IsShown() then
				b:ClearAllPoints()
				b:SetPoint("TOPLEFT", x, y)
				x = x + b:GetWidth() + 4
			end
		end
		y = y - 30
	end

	frame:SetHeight(-y + 6)
end

function UI.Show(announce)
	if not frame then Build() end
	local wasShown = frame:IsShown()
	frame:Show()
	UI.Update()
	if announce and not wasShown then
		PlaySoundSafe((SOUNDKIT and SOUNDKIT.READY_CHECK) or 8960)
	end
end

function UI.Hide()
	if frame then frame:Hide() end
end

-- Puts a finished roll away after a while, unless it's being looked at or a
-- new roll has replaced it.
function UI.CloseLater(r)
	local function Check()
		if ns.roll ~= r or not (frame and frame:IsShown()) then return end
		if frame:IsMouseOver() then C_Timer.After(5, Check) return end
		frame:Hide()
	end
	C_Timer.After(CLOSE_AFTER, Check)
end

---------------------------------------------------------------------------
-- Dice button
---------------------------------------------------------------------------

local function BuildButton()
	button = CreateFrame("Button", "FireRollButton", UIParent)
	button:SetSize(32, 32)
	button:SetFrameStrata("MEDIUM")
	button:SetClampedToScreen(true)
	button:SetMovable(true)
	button:RegisterForDrag("LeftButton")
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:SetNormalTexture(DICE)
	button:SetPushedTexture("Interface\\Buttons\\UI-GroupLoot-Dice-Down")
	button:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Dice-Highlight", "ADD")
	RestorePoint(button, "buttonPoint", BUTTON_DEFAULT)
	button:SetScript("OnDragStart", button.StartMoving)
	button:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		SavePoint(self, "buttonPoint")
	end)
	button:SetScript("OnClick", function(_, mouse)
		if mouse == "RightButton" then
			ns.Options.Open()
			return
		end
		local r = ns.roll
		if r and not r.done and not r.test then UI.Show() else ns.Start() end
	end)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("FireRoll", 1, 1, 1)
		local r = ns.roll
		if r and not r.done and not r.test then
			GameTooltip:AddLine("Click to show the roll in progress.", nil, nil, nil, true)
		else
			GameTooltip:AddLine("Click to start a roll for the group.", nil, nil, nil, true)
			GameTooltip:AddLine("To roll for something by name: /froll <name or shift-clicked item>", 0.7, 0.7, 0.7, true)
		end
		GameTooltip:AddLine("Drag to move. Right-click for options.", 0.7, 0.7, 0.7, true)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- The dice show while you're in a group (if turned on).
function UI.UpdateButton()
	if not ns.db then return end
	if not button then BuildButton() end
	button:SetShown(ns.db.button and IsInGroup() or false)
end

function UI.ResetPositions()
	ns.db.windowPoint, ns.db.buttonPoint = nil, nil
	if frame then RestorePoint(frame, "windowPoint", WINDOW_DEFAULT) end
	if button then RestorePoint(button, "buttonPoint", BUTTON_DEFAULT) end
end
