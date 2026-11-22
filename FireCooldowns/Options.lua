-- Options > AddOns > FireCooldowns (or /fcd). A self-drawn ("canvas") page,
-- so the game's settings search never runs into it (see FireProcs/Options.lua).
--   Show: the list on screen and the sound.
--   Track: everything found (crafts with a cooldown, and what you've used
--   this session with one), off until you turn it on; yours (added below)
--   can be removed.
--   Add: a spell ID, or shift-click a spell, recipe or item into the box.
local _, ns = ...
local Options = {}
ns.Options = Options

local category, panel, Layout
local ROW = 24

local function Tip(owner, title, text)
	owner:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(title, 1, 1, 1)
		if text then GameTooltip:AddLine(text, nil, nil, nil, true) end
		GameTooltip:Show()
	end)
	owner:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function Button(parent, text, width, onClick)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(text)
	b:SetScript("OnClick", onClick)
	return b
end

local function Heading(text)
	local h = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	h:SetText(text)
	return h
end

local function Note()
	local n = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	n:SetJustifyH("LEFT")
	return n
end

local function Build()
	local db = ns.db
	panel = CreateFrame("Frame")
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
	about:SetText("Cooldowns on all your characters. Move the list in Edit Mode.")
	y = y - 26

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
		Tip(cb, label, tooltip)
		refreshers[#refreshers + 1] = function()
			cb:SetChecked(db[key])
			if indent then
				cb:SetEnabled(db.shown)
				text:SetFontObject(db.shown and "GameFontHighlight" or "GameFontDisable")
			end
		end
		y = y - 26
	end

	Checkbox("shown", "Show on screen", "Each cooldown and its time left. Ready ones stay until used.")
	Checkbox("alts", "Other characters", "Their cooldowns too, with their name.", 20)
	Checkbox("readyOnly", "Only when ready", "Hide cooldowns still counting down.", 20)
	Checkbox("sound", "Sound", "When a cooldown is ready.")
	y = y - 12

	-------------------------------------------------------------------------
	-- Track and add: laid out again whenever they change.
	-------------------------------------------------------------------------
	local top = y
	local trackHead = Heading("Track")
	local trackNote = Note()
	trackNote:SetText("Nothing found yet. Crafts and things you use with a cooldown show here.")
	local addHead = Heading("Add")

	local box = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
	box:SetSize(220, 20)
	box:SetAutoFocus(false)
	local addError = Note()
	local function AddFromBox()
		local name, why = ns.Add(box:GetText())
		if name then
			box:SetText("")
			box:ClearFocus()
			addError:SetText("")
		else
			addError:SetText(why)
		end
	end
	box:SetScript("OnEnterPressed", AddFromBox)
	box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	Tip(box, "Spell ID or link", "Shift-click a spell, recipe or item while typing here.")
	local addButton = Button(panel, "Add", 60, AddFromBox)
	-- Shift-clicking a link while the box is focused puts it in the box.
	local function OnInsertLink(link)
		if box:HasFocus() and type(link) == "string" then box:SetText(link) end
	end
	if ChatEdit_InsertLink then hooksecurefunc("ChatEdit_InsertLink", OnInsertLink) end
	if ChatFrameUtil and ChatFrameUtil.InsertLink then hooksecurefunc(ChatFrameUtil, "InsertLink", OnInsertLink) end

	local test = Button(panel, "Try it", 100, function() SlashCmdList.FIRECOOLDOWNS("test") end)
	Tip(test, "Try it", "A pretend transmute, ready in 10 seconds.")
	local clear = Button(panel, "Clear test", 100, function() SlashCmdList.FIRECOOLDOWNS("test clear") end)

	local rows = {}

	local function Row(i)
		local r = rows[i]
		if r then return r end
		r = CreateFrame("Frame", nil, panel)
		r:SetSize(400, ROW)
		r.check = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate")
		r.check:SetSize(24, 24)
		r.check:SetPoint("LEFT")
		r.check:SetScript("OnClick", function(self)
			if self:GetChecked() and r.recentID then
				ns.Add(tostring(r.recentID))
			else
				ns.SetOn(r.key, self:GetChecked())
				Layout()
			end
		end)
		Tip(r.check, "Track", "Show it and remind you when it's ready, on all characters.")
		r.icon = r:CreateTexture(nil, "ARTWORK")
		r.icon:SetSize(18, 18)
		r.icon:SetPoint("LEFT", r.check, "RIGHT", 2, 0)
		r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		r.text = r:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		r.text:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
		r.remove = Button(r, "Remove", 70, function() ns.Remove(r.key) end)
		r.remove:SetPoint("LEFT", r.text, "RIGHT", 10, 0)
		Tip(r.remove, "Remove", "Take it off this list.")
		rows[i] = r
		return r
	end

	local function Place(region, x, yy)
		region:ClearAllPoints()
		region:SetPoint("TOPLEFT", panel, "TOPLEFT", x, yy)
	end

	Layout = function()
		local yy = top
		Place(trackHead, 16, yy)
		yy = yy - 20
		local found = ns.Found()
		trackNote:SetShown(#found == 0)
		if #found == 0 then
			Place(trackNote, 22, yy)
			yy = yy - 18
		end
		for i, t in ipairs(found) do
			local r = Row(i)
			r.key, r.recentID = t.key, t.recentID
			r.check:SetChecked(t.on)
			r.icon:SetTexture(t.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
			r.icon:SetDesaturated(not t.on)
			r.text:SetText(t.key)
			r.text:SetFontObject(t.on and "GameFontHighlight" or "GameFontDisable")
			r.remove:SetShown(t.custom == true)
			Place(r, 18, yy)
			r:Show()
			yy = yy - ROW
		end
		for i = #found + 1, #rows do rows[i]:Hide() end
		yy = yy - 10

		Place(addHead, 16, yy)
		yy = yy - 22
		Place(box, 24, yy)
		addButton:ClearAllPoints()
		addButton:SetPoint("LEFT", box, "RIGHT", 8, 0)
		addError:ClearAllPoints()
		addError:SetPoint("LEFT", addButton, "RIGHT", 8, 0)
		yy = yy - 36

		Place(test, 20, yy)
		clear:ClearAllPoints()
		clear:SetPoint("LEFT", test, "RIGHT", 8, 0)
	end

	panel:SetScript("OnShow", function()
		for _, fn in ipairs(refreshers) do fn() end
		addError:SetText("")
		Layout()
	end)

	category = Settings.RegisterCanvasLayoutCategory(panel, "FireCooldowns")
	Settings.RegisterAddOnCategory(category)
end

-- After something is tracked, removed or used.
function Options.Refresh()
	if panel and panel:IsShown() and Layout then Layout() end
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
