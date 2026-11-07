-- The options panel: Options > AddOns > FireProcs (or /fprocs config).
--
-- Main page: Blizzard's standard settings controls (look and behave like the
-- game's own options). "Procs" sub-page: every proc seen so far, each with a
-- checkbox to keep or stop announcing it.
local _, ns = ...

local Options = {}
ns.Options = Options

local category, procsCategory

local function VarType(value)
	local vt = Settings.VarType
	if type(value) == "number" then return vt and vt.Number or "number" end
	return vt and vt.Boolean or "boolean"
end

local function OnChange(setting, fn)
	if not fn then return end
	if setting.SetValueChangedCallback then
		setting:SetValueChangedCallback(function(_, value) ns.SafeCall(fn, value) end)
	elseif Settings.SetOnValueChangedCallback then
		Settings.SetOnValueChangedCallback(setting:GetVariable(), function(_, _, value) ns.SafeCall(fn, value) end)
	end
end

---------------------------------------------------------------------------
-- Main page
---------------------------------------------------------------------------
local function BuildMain()
	local db = ns.db
	category = Settings.RegisterVerticalLayoutCategory("FireProcs")
	local layout = SettingsPanel and SettingsPanel.GetLayout and SettingsPanel:GetLayout(category)

	local function Header(text)
		if layout and CreateSettingsListSectionHeaderInitializer then
			layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text))
		end
	end

	local function Button(label, buttonText, tooltip, onClick)
		if layout and CreateSettingsButtonInitializer then
			layout:AddInitializer(CreateSettingsButtonInitializer(label, buttonText, function()
				ns.SafeCall(onClick)
			end, tooltip, true))
		end
	end

	local function Register(key, label)
		return Settings.RegisterAddOnSetting(category, "FireProcs_" .. key, key, db,
			VarType(ns.DEFAULTS[key]), label, ns.DEFAULTS[key])
	end

	local function Checkbox(key, label, tooltip, onChange)
		local setting = Register(key, label)
		Settings.CreateCheckbox(category, setting, tooltip)
		OnChange(setting, onChange)
	end

	local function Slider(key, label, tooltip, min, max, step, format, onChange)
		local setting = Register(key, label)
		local options = Settings.CreateSliderOptions(min, max, step)
		if MinimalSliderWithSteppersMixin and options.SetLabelFormatter then
			options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, format)
		end
		Settings.CreateSlider(category, setting, options, tooltip)
		OnChange(setting, onChange)
	end

	local function RefreshAuras() ns.Auras.Update() end

	Header("Announcements")
	Button("Preview", "Test", "Show a sample announcement.", function() ns.Display.Test() end)
	Button("Position", "Unlock / Lock", "Unlock to drag the announcements to a new spot (close this window first), then press again to lock.",
		function()
			local moving = ns.Display.ToggleMove()
			if moving then ns.Display.Test() end
			ns.Print(moving and "drag the blue box, then press Unlock / Lock again (or type /fprocs move)." or "position saved.")
		end)
	Button("", "Reset position", "Put the announcements back above your character.", function()
		ns.Display.ResetPosition()
	end)
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
		"Touch of the Grave and similar passives that heal you by chance. Only while you're not in a group (healers' heals look the same).")
	Checkbox("detectTriggered", "Spells that go off by themselves",
		"Spells of yours that fire without you casting them.")
	Checkbox("detectGifts", "Long buffs from other players",
		"Arcane Intellect, Fortitude, Blessings, world buffs and other long buffs someone gives you.", RefreshAuras)

	Settings.RegisterAddOnCategory(category)
end

---------------------------------------------------------------------------
-- "Procs" page: one checkbox per proc seen.
---------------------------------------------------------------------------
local ROW_HEIGHT = 26

local function BuildProcs()
	local panel = CreateFrame("Frame")
	panel:Hide()

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("Procs")

	local help = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	help:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
	help:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
	help:SetJustifyH("LEFT")
	help:SetText("Every proc FireProcs has announced so far. Untick one to stop announcing it.")

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
	empty:SetText("No procs seen yet - they show up here once they've been announced.")

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
			local db, name = ns.db, self.procName
			if self:GetChecked() then
				db.muted[name] = nil
				ns.ResetProcHistory(name)
			else
				db.muted[name] = true
				ns.Glow.Set(name, false)
			end
			ns.Auras.Update()
		end)
		rows[i] = row
		return row
	end

	local function Refresh()
		local db = ns.db
		local names, added = {}, {}
		for name in pairs(db.seen) do names[#names + 1] = name; added[name] = true end
		for name in pairs(db.muted) do
			if not added[name] then names[#names + 1] = name end
		end
		table.sort(names, function(a, b) return a:lower() < b:lower() end)

		child:SetWidth(math.max(scroll:GetWidth(), 1))
		child:SetHeight(math.max(#names * ROW_HEIGHT, 1))
		empty:SetShown(#names == 0)
		for i, name in ipairs(names) do
			local row = Row(i)
			row.procName = name
			row:SetChecked(not db.muted[name])
			row.label:SetText(db.muted[name] == "auto"
				and (name .. "  |cff888888(muted automatically: happens too often)|r") or name)
			row:Show()
		end
		for i = #names + 1, #rows do rows[i]:Hide() end
	end
	panel:SetScript("OnShow", function() ns.SafeCall(Refresh) end)

	procsCategory = Settings.RegisterCanvasLayoutSubcategory(category, panel, "Procs")
end

---------------------------------------------------------------------------
function Options.Open(page)
	local cat = page == "procs" and procsCategory or category
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
	if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterAddOnSetting) then return end
	BuildMain()
	if Settings.RegisterCanvasLayoutSubcategory then BuildProcs() end
end)
