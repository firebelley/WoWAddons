-- The options panel: Options > AddOns > FireProcs (or /fprocs).
--
-- Both pages are "canvas" pages: plain frames FireProcs draws itself with
-- Blizzard's widget templates. The game's settings search (which also runs in
-- the Keybindings page) walks every list-style page's controls, and running
-- into controls an addon created taints Blizzard's keybinding code - that
-- caused "FireProcs has been blocked from an action only available to the
-- Blizzard UI". Canvas pages aren't searched, so they can't cause that.
local _, ns = ...

local Options = {}
ns.Options = Options

local category, procsCategory, buffsCategory

local function Tooltip(widget, title, text)
	widget:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(title, 1, 1, 1)
		if text then GameTooltip:AddLine(text, nil, nil, nil, true) end
		GameTooltip:Show()
	end)
	widget:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

---------------------------------------------------------------------------
-- Main page
---------------------------------------------------------------------------
local function BuildMain()
	local panel = CreateFrame("Frame")
	panel:Hide()
	local refreshers = {} -- re-read db into the widgets each time the page opens
	local y = -16         -- next free spot, top to bottom

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, y)
	title:SetText("FireProcs")
	y = y - 30

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

	-- Buttons go side by side on one row.
	local lastButton
	local function Button(text, tooltip, onClick)
		local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		b:SetSize(130, 22)
		b:SetText(text)
		if lastButton then
			b:SetPoint("LEFT", lastButton, "RIGHT", 8, 0)
		else
			b:SetPoint("TOPLEFT", 20, y)
		end
		b:SetScript("OnClick", function() ns.SafeCall(onClick) end)
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
		cb:SetHitRectInsets(0, -(text:GetStringWidth() + 8), 0, 0) -- clicking the label works too
		cb:SetScript("OnClick", function(self)
			local on = self:GetChecked() and true or false
			ns.db[key] = on
			if onChange then ns.SafeCall(onChange, on) end
		end)
		Tooltip(cb, label, tooltip)
		refreshers[#refreshers + 1] = function() cb:SetChecked(ns.db[key] ~= false) end
		y = y - 28
	end

	-- Sliders in the classic options look; two fit side by side.
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
			v = math.floor((v - min) / step + 0.5) * step + min -- snap to the step
			value:SetText(format(v))
			if loading or ns.db[key] == v then return end
			ns.db[key] = v
			if onChange then ns.SafeCall(onChange, v) end
		end)
		s:SetScript("OnMouseWheel", function(self, delta)
			self:SetValue(math.max(min, math.min(max, self:GetValue() + delta * step)))
		end)
		Tooltip(s, label, tooltip)
		refreshers[#refreshers + 1] = function()
			loading = true
			s:SetValue(ns.db[key] or ns.DEFAULTS[key])
			value:SetText(format(ns.db[key] or ns.DEFAULTS[key]))
			loading = false
		end

		if sliderX == 0 then
			sliderX = 250
		else
			sliderX = 0
			y = y - 48
		end
	end

	local function RefreshAuras() ns.Auras.Update() end

	Header("Announcements")
	Button("Test", "Show a sample announcement.", function() ns.Display.Test() end)
	Button("Unlock / Lock", "Unlock to drag the announcements to a new spot (close this window first), then press again to lock.",
		function()
			local moving = ns.Display.ToggleMove()
			if moving then ns.Display.Test() end
			ns.Print(moving and "drag the blue box, then press Unlock / Lock again (or type /fprocs move)." or "position saved.")
		end)
	Button("Reset position", "Put the announcements back above your character.", function()
		ns.Display.ResetPosition()
	end)
	EndButtons()
	Slider("scale", "Size", "How big the announcements are.", 0.5, 2, 0.05,
		function(v) return ("%d%%"):format(math.floor(v * 100 + 0.5)) end,
		function() ns.Display.ApplyScale(true) end)
	Slider("hold", "Duration", "How long each announcement stays on screen before it fades.", 0.5, 5, 0.25,
		function(v) return ("%.2g sec"):format(v) end)
	Checkbox("sound", "Play a sound", "Play the proc chime with each announcement.")
	Checkbox("showIcons", "Show active proc icons",
		"Show an icon with a timer below the announcements for as long as a proc buff lasts.", RefreshAuras)

	Header("What to announce")
	Checkbox("detectBuffs", "Proc buffs",
		"Buffs you get by chance: Clearcasting, Flurry, Enrage, Shadow Trance... In combat this client hides most buffs from addons, so these are mostly caught out of combat - the spell-change option below covers many of them in combat.",
		RefreshAuras)
	Checkbox("detectChanges", "Spells that become free or instant",
		"Missile Barrage (Arcane Missiles costs nothing), Clearcasting (spells cost nothing), Nightfall (instant Shadow Bolt)... Works in combat.")
	Checkbox("detectAbilities", "Abilities that light up",
		"Abilities that become usable after something happens: Overpower, Revenge, Riposte, Execute...")
	Checkbox("glowButtons", "Make their action buttons glow",
		"Add the proc glow to action buttons of abilities that light up, until they're used.",
		function(on) if not on then ns.Glow.ClearAll() end end)
	Checkbox("detectDrain", "Life-drain heals",
		"Touch of the Grave and similar passives that heal you by chance. In a group, heals right after a healer casts a healing spell are skipped (theirs look the same).")
	Checkbox("detectTriggered", "Spells that go off by themselves",
		"Spells of yours that fire without you casting them.")
	Checkbox("detectGifts", "Long buffs from other players",
		"Arcane Intellect, Fortitude, Blessings, world buffs and other long buffs someone gives you.", RefreshAuras)

	local function RefreshReminders() ns.SelfBuffs.Refresh() end
	Header("Buff reminders")
	Checkbox("remindAnnounce", "Announce when one of your buffs is gone",
		"\"Water Shield is gone\", \"Demon Armor is gone\"... for your own long buffs (a minute or more), including in combat. Choose which buffs in the Buffs page (/fprocs buffs).",
		RefreshReminders)
	Checkbox("remindIcon", "Keep an icon up until you recast it",
		"A red, pulsing icon of the missing buff under the announcements. It goes away when you cast the buff (or an alternative, like Lightning Shield for Water Shield).",
		RefreshReminders)
	Slider("remindIconMinutes", "Hide the icon after",
		"Take the icon away after this long, even if you haven't recast the buff. Never: it stays until you do. "
			.. "Either way you aren't reminded about that buff again until you've recast it and lost it again.",
		0, 10, 1,
		function(v) return v == 0 and "Never" or ("%d min"):format(v) end,
		RefreshReminders)
	if sliderX ~= 0 then sliderX, y = 0, y - 48 end -- a slider on its own

	panel:SetScript("OnShow", function()
		for _, fn in ipairs(refreshers) do ns.SafeCall(fn) end
	end)

	category = Settings.RegisterCanvasLayoutCategory(panel, "FireProcs")
	Settings.RegisterAddOnCategory(category)
end

---------------------------------------------------------------------------
-- List pages: a scrolling list with one checkbox per entry.
--   items() returns { { key, label, checked }, ... }
--   onToggle(key, checked) is called when one is clicked.
---------------------------------------------------------------------------
local ROW_HEIGHT = 26

local function BuildList(name, helpText, emptyText, items, onToggle)
	local panel = CreateFrame("Frame")
	panel:Hide()

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText(name)

	local help = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	help:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
	help:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
	help:SetJustifyH("LEFT")
	help:SetText(helpText)

	local ok, scroll = pcall(CreateFrame, "ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
	if not ok then scroll = CreateFrame("ScrollFrame", nil, panel) end
	scroll:SetPoint("TOPLEFT", help, "BOTTOMLEFT", 0, -12)
	scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -30, 12)
	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		local max = self:GetVerticalScrollRange()
		self:SetVerticalScroll(math.max(0, math.min(max, self:GetVerticalScroll() - delta * ROW_HEIGHT * 2)))
	end)

	local child = CreateFrame("Frame", nil, scroll)
	child:SetSize(1, 1)
	scroll:SetScrollChild(child)

	local empty = child:CreateFontString(nil, "ARTWORK", "GameFontDisable")
	empty:SetPoint("TOPLEFT", 4, -4)
	empty:SetText(emptyText)

	local rows = {}
	local function Row(i)
		local row = rows[i]
		if row then return row end
		row = CreateFrame("CheckButton", nil, child, "UICheckButtonTemplate")
		row:SetSize(24, 24)
		row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
		row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		row.label:SetPoint("LEFT", row, "RIGHT", 4, 0)
		row:SetScript("OnClick", function(self)
			ns.SafeCall(onToggle, self.key, self:GetChecked() and true or false)
		end)
		rows[i] = row
		return row
	end

	local function Refresh()
		local list = items()
		table.sort(list, function(a, b) return a.key:lower() < b.key:lower() end)
		child:SetWidth(math.max(scroll:GetWidth(), 1))
		child:SetHeight(math.max(#list * ROW_HEIGHT, 1))
		empty:SetShown(#list == 0)
		for i, item in ipairs(list) do
			local row = Row(i)
			row.key = item.key
			row:SetChecked(item.checked)
			row.label:SetText(item.label)
			row:Show()
		end
		for i = #list + 1, #rows do rows[i]:Hide() end
	end
	panel:SetScript("OnShow", function() ns.SafeCall(Refresh) end)

	return Settings.RegisterCanvasLayoutSubcategory(category, panel, name)
end

-- "Procs" page: one checkbox per proc seen.
local function BuildProcs()
	return BuildList("Procs",
		"Every proc FireProcs has announced so far. Untick one to stop announcing it.",
		"No procs seen yet - they show up here once they've been announced.",
		function()
			local db, list, added = ns.db, {}, {}
			local function Add(name)
				if added[name] then return end
				added[name] = true
				list[#list + 1] = {
					key = name, checked = not db.muted[name],
					label = db.muted[name] == "auto" and (name .. "  |cff888888(muted automatically: happens too often)|r") or name,
				}
			end
			for name in pairs(db.seen) do Add(name) end
			for name in pairs(db.muted) do Add(name) end
			return list
		end,
		function(name, on)
			local db = ns.db
			if on then
				db.muted[name] = nil
				ns.ResetProcHistory(name)
			else
				db.muted[name] = true
				ns.Glow.Set(name, false)
			end
			ns.Auras.Update()
		end)
end

-- "Buffs" page: one checkbox per buff reminder.
local function BuildBuffs()
	return BuildList("Buffs",
		"Your own long buffs FireProcs reminds you about when they're gone (see Buff reminders on the main page), "
			.. "and short ones you keep up yourself, like seals, which are only reminded about when they drop during "
			.. "a fight (the icon goes when you recast it or the fight ends). "
			.. "Buffs are added here the first time you cast them. Untick one to never be reminded about it.",
		"None yet - cast one of your long buffs (Water Shield, Demon Armor...) and it shows up here.",
		function()
			local list = {}
			for name, e in pairs(ns.db.selfBuffs) do
				local label = (e.icon and ("|T" .. e.icon .. ":16|t ") or "") .. name
				if e.combat then label = label .. "  |cff888888(only when it drops in combat)|r" end
				local group = ns.SelfBuffs.GroupOf(name)
				local alts = {}
				for other in pairs(ns.db.selfBuffs) do
					if other ~= name and ns.SelfBuffs.GroupOf(other) == group then alts[#alts + 1] = other end
				end
				if #alts > 0 then
					table.sort(alts)
					label = label .. "  |cff888888(or " .. table.concat(alts, ", ") .. ")|r"
				end
				list[#list + 1] = { key = name, label = label, checked = e.on ~= false }
			end
			return list
		end,
		function(name, on)
			ns.db.selfBuffs[name].on = on
			ns.SelfBuffs.Refresh()
		end)
end

---------------------------------------------------------------------------
function Options.Open(page)
	local cat = (page == "procs" and procsCategory) or (page == "buffs" and buffsCategory) or category
	if not cat then
		ns.Print("the options panel isn't available on this client - see /fprocs help for commands.")
		return
	end
	local id = cat.GetID and cat:GetID() or cat.ID
	if not (id and pcall(Settings.OpenToCategory, id)) then
		pcall(Settings.OpenToCategory, cat)
	end
end

ns.On("PLAYER_LOGIN", function()
	if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then return end
	BuildMain()
	if Settings.RegisterCanvasLayoutSubcategory then
		procsCategory = BuildProcs()
		buffsCategory = BuildBuffs()
	end
end)

-- If the game ever blocks FireProcs again, say which function so it can be fixed.
local function ReportBlocked(addon, func)
	if addon == "FireProcs" then
		ns.Print(("the game blocked FireProcs from calling %s - please report this."):format(tostring(func)))
	end
end
ns.On("ADDON_ACTION_BLOCKED", ReportBlocked)
ns.On("ADDON_ACTION_FORBIDDEN", ReportBlocked)
