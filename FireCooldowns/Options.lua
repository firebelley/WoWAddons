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

	Checkbox("shown", "Show on screen", "Each cooldown and its time left. Ready ones stay until used or right-clicked.")
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
	local abilitiesHead = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	abilitiesHead:SetText("Your abilities")
	local addHead = Heading("Add")

	-- Errors here would otherwise vanish (the game hides them): print them.
	local reported = {}
	local function Safe(fn)
		return function(...)
			local ok, err = pcall(fn, ...)
			if not ok and not reported[tostring(err)] then
				reported[tostring(err)] = true
				ns.Print("|cffff4040error:|r " .. tostring(err))
			end
		end
	end

	local box = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
	box:SetSize(220, 20)
	box:SetAutoFocus(false)
	local addError = Note()
	-- Returns the name tracked, or nil.
	local function AddText(text)
		local name, why = ns.Add(text)
		if name then
			box:SetText("")
			box:ClearFocus()
			addError:SetText("")
			ns.Print(("tracking %s."):format(name))
		else
			addError:SetText(why)
		end
		return name
	end
	local function AddFromBox() AddText(box:GetText()) end
	box:SetScript("OnEnterPressed", Safe(AddFromBox))
	box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	Tip(box, "Spell ID or link", "Shift-click a spell, recipe or item while typing here.")
	local addButton = Button(panel, "Add", 60, Safe(AddFromBox))
	local addNote = Note()
	addNote:SetText("Drag a spell from your spellbook or an item from your bags onto this page.")

	-- A slot to drop things on, lit while you're holding something. Drawn
	-- here (no game art), so it shows whatever the game's textures are.
	local slot = CreateFrame("Button", nil, panel)
	slot:SetSize(32, 32)
	slot:EnableMouse(true)
	slot:RegisterForClicks("AnyUp")
	local function Fill(layer, r, g, b, a)
		local t = slot:CreateTexture(nil, layer)
		t:SetColorTexture(r, g, b, a)
		return t
	end
	local border = Fill("BACKGROUND", 0.8, 0.65, 0.2, 1)
	border:SetAllPoints()
	local inner = Fill("BORDER", 0.05, 0.05, 0.05, 0.9)
	inner:SetPoint("TOPLEFT", 1, -1)
	inner:SetPoint("BOTTOMRIGHT", -1, 1)
	local lit = Fill("ARTWORK", 1, 0.85, 0.3, 0.35)
	lit:SetPoint("TOPLEFT", 1, -1)
	lit:SetPoint("BOTTOMRIGHT", -1, 1)
	lit:Hide()
	local plus = slot:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	plus:SetPoint("CENTER", 0, 1)
	plus:SetText("+")
	Tip(slot, "Drop here", "A spell, item or macro to track.")

	-- Shift-clicking a link while the box is focused puts it in the box.
	local function OnInsertLink(link)
		if box:HasFocus() and type(link) == "string" then box:SetText(link) end
	end
	if ChatEdit_InsertLink then hooksecurefunc("ChatEdit_InsertLink", OnInsertLink) end
	if ChatFrameUtil and ChatFrameUtil.InsertLink then hooksecurefunc(ChatFrameUtil, "InsertLink", OnInsertLink) end

	-- Something dragged off an action bar leaves the bar, so it goes back to
	-- the slot it came from.
	local pickedSlot
	local function OnPickupAction(s)
		if type(s) == "number" and not (issecretvalue and issecretvalue(s)) and s >= 1 and s % 1 == 0 then
			pickedSlot = s
		end
	end
	if PickupAction then hooksecurefunc("PickupAction", OnPickupAction) end
	if C_ActionBar and C_ActionBar.PickupAction then hooksecurefunc(C_ActionBar, "PickupAction", OnPickupAction) end
	local cursorWatch = CreateFrame("Frame")
	pcall(cursorWatch.RegisterEvent, cursorWatch, "CURSOR_CHANGED")
	cursorWatch:SetScript("OnEvent", function()
		local holding = GetCursorInfo() ~= nil
		if not holding then pickedSlot = nil end
		lit:SetShown(holding)
	end)

	-- A spell comes as (spellbook slot, spellbook, spell ID); the ID may be
	-- missing, so it's looked up from the spellbook slot then.
	local function SpellFromBook(index, book)
		if not (C_SpellBook and C_SpellBook.GetSpellBookItemInfo and type(index) == "number") then return nil end
		local bank = Enum and Enum.SpellBookSpellBank
		bank = bank and ((book == "pet" and bank.Pet) or bank.Player) or 0
		local ok, info = pcall(C_SpellBook.GetSpellBookItemInfo, index, bank)
		return ok and type(info) == "table" and (info.spellID or info.actionID) or nil
	end

	local function CursorText(kind, a, b, c)
		if kind == "spell" then
			local id = tonumber(c) or SpellFromBook(a, b)
			return id and tostring(id)
		elseif kind == "item" then
			return type(b) == "string" and b or ("|Hitem:" .. tostring(a))
		elseif kind == "macro" then
			local spell = GetMacroSpell and GetMacroSpell(a)
			if spell then return tostring(spell) end
			local _, link = GetMacroItem and GetMacroItem(a)
			return link
		end
	end

	local Drop = Safe(function()
		if not GetCursorInfo() or InCombatLockdown() then return end
		local info = { GetCursorInfo() }
		local text = CursorText(unpack(info))
		local restored = true
		if pickedSlot then
			-- Off an action bar: back to its slot. If that can't be done (or
			-- checked), it stays in hand to put back yourself.
			local slotID = pickedSlot
			local function Has()
				local fn = (C_ActionBar and C_ActionBar.HasAction) or HasAction
				local ok, has = pcall(fn, slotID)
				if ok then return has == true end
			end
			if Has() == false then
				local place = (C_ActionBar and C_ActionBar.PutActionInSlot) or PlaceAction
				if place then pcall(place, slotID) end
			end
			restored = Has() == true
		end
		pickedSlot = nil
		if restored then ClearCursor() end
		if not (text and AddText(text)) then
			-- What the game handed over, to see why.
			for i = 1, #info do info[i] = tostring(info[i]) end
			ns.Print("couldn't track the dropped " .. table.concat(info, ", ") .. ".")
		end
	end)
	slot:SetScript("OnReceiveDrag", Drop)
	slot:SetScript("OnClick", Drop)
	box:SetScript("OnReceiveDrag", Drop)
	-- Anywhere on the page.
	panel:EnableMouse(true)
	panel:SetScript("OnReceiveDrag", Drop)
	panel:SetScript("OnMouseUp", function() if GetCursorInfo() then Drop() end end)

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
		r.check:SetScript("OnClick", Safe(function(self)
			if self:GetChecked() and r.addID then
				ns.Add(tostring(r.addID))
			else
				ns.SetOn(r.key, self:GetChecked())
				Layout()
			end
		end))
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
		local abilities = ns.Abilities(found)
		trackNote:SetShown(#found == 0 and #abilities == 0)
		if #found == 0 and #abilities == 0 then
			Place(trackNote, 22, yy)
			yy = yy - 18
		end
		local used = 0
		local function Fill(t, x, width)
			used = used + 1
			local r = Row(used)
			r.key, r.addID = t.key, t.addID
			r:SetWidth(width)
			r.check:SetChecked(t.on == true)
			r.icon:SetTexture(t.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
			r.icon:SetDesaturated(not t.on)
			r.text:SetText(t.key)
			r.text:SetFontObject(t.on and "GameFontHighlight" or "GameFontDisable")
			r.remove:SetShown(t.custom == true)
			Place(r, x, yy)
			r:Show()
		end
		for _, t in ipairs(found) do
			Fill(t, 18, 400)
			yy = yy - ROW
		end

		-- Your abilities with a cooldown, in two columns.
		abilitiesHead:SetShown(#abilities > 0)
		if #abilities > 0 then
			yy = yy - 6
			Place(abilitiesHead, 22, yy)
			yy = yy - 18
			for i, t in ipairs(abilities) do
				local col = (i - 1) % 2
				Fill(t, 18 + col * 220, 210)
				if col == 1 or i == #abilities then yy = yy - ROW end
			end
		end
		for i = used + 1, #rows do rows[i]:Hide() end
		yy = yy - 10

		Place(addHead, 16, yy)
		yy = yy - 20
		Place(slot, 22, yy)
		box:ClearAllPoints()
		box:SetPoint("LEFT", slot, "RIGHT", 14, 0)
		addButton:ClearAllPoints()
		addButton:SetPoint("LEFT", box, "RIGHT", 8, 0)
		addError:ClearAllPoints()
		addError:SetPoint("LEFT", addButton, "RIGHT", 8, 0)
		yy = yy - 38
		Place(addNote, 22, yy)
		yy = yy - 26

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
