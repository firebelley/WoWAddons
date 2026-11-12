-- Options > AddOns > FireCompanion (or /fcomp). A self-drawn ("canvas") page,
-- so the game's settings search never runs into it (see FireProcs/Options.lua).
local _, ns = ...

local ROW_H = 26
local category, panel

local function Tooltip(widget, title, text)
	widget:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(title, 1, 1, 1)
		if text then GameTooltip:AddLine(text, nil, nil, nil, true) end
		GameTooltip:Show()
	end)
	widget:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

local function Build()
	local db = ns.db
	panel = CreateFrame("Frame")
	panel:Hide()
	local refreshers = {}
	local y = -16

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, y)
	title:SetText("FireCompanion")
	y = y - 24

	local about = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	about:SetPoint("TOPLEFT", 16, y)
	about:SetPoint("RIGHT", -16, 0)
	about:SetJustifyH("LEFT")
	about:SetText("Summons a companion on login. If you dismiss it, it stays away until next login. "
		.. "Settings are per character.")
	y = y - 30

	local function Checkbox(key, label, tooltip)
		local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
		cb:SetSize(26, 26)
		cb:SetPoint("TOPLEFT", 16, y)
		local text = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		text:SetPoint("LEFT", cb, "RIGHT", 4, 1)
		text:SetText(label)
		cb:SetHitRectInsets(0, -(text:GetStringWidth() + 8), 0, 0)
		cb:SetScript("OnClick", function(self) db[key] = self:GetChecked() and true or false end)
		Tooltip(cb, label, tooltip)
		refreshers[#refreshers + 1] = function() cb:SetChecked(db[key]) end
		y = y - 28
	end

	Checkbox("enabled", "Summon a companion when you log in")
	Checkbox("afterDeath", "Bring it back after you die", "Once you're alive again, unless you'd dismissed it before dying.")
	y = y - 8

	local which = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	which:SetPoint("TOPLEFT", 16, y)
	which:SetText("Which companion")
	y = y - 20

	-- Radio-style choices; picking a pet in the list below is the fourth.
	local radios = {}
	local function Radio(mode, label, tooltip)
		local ok, rb = pcall(CreateFrame, "CheckButton", nil, panel, "UIRadioButtonTemplate")
		if not ok then rb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate") end
		rb:SetSize(18, 18)
		rb:SetPoint("TOPLEFT", 22, y)
		local text = rb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		text:SetPoint("LEFT", rb, "RIGHT", 6, 0)
		rb.label = text
		rb.baseLabel = label
		text:SetText(label)
		rb:SetHitRectInsets(0, -300, 0, 0)
		rb:SetScript("OnClick", function()
			db.mode = mode
			for _, fn in ipairs(refreshers) do fn() end
		end)
		Tooltip(rb, label, tooltip)
		radios[mode] = rb
		y = y - 22
	end
	Radio("last", "The one you had out last", "Whatever you last summoned, by any means.")
	Radio("favorite", "A random favorite", "Mark favorites in the Pet Journal. With no favorites, any companion.")
	Radio("random", "A random companion")
	Radio("pet", "This one:", "Click a companion in the list below.")
	refreshers[#refreshers + 1] = function()
		for mode, rb in pairs(radios) do rb:SetChecked(db.mode == mode) end
		local last = ns.LastPet()
		radios.last.label:SetText(radios.last.baseLabel .. (last and ("  |cff999999(" .. last.name .. ")|r") or ""))
		local pick = ns.PetInfo(db.petID)
		radios.pet.label:SetText(radios.pet.baseLabel .. "  " .. (pick and pick.name or "|cff999999click one below|r"))
	end
	y = y - 8

	-- The list of your companions.
	local box = CreateFrame("Frame", nil, panel, "BackdropTemplate")
	box:SetPoint("TOPLEFT", 16, y)
	box:SetPoint("BOTTOMRIGHT", -16, 16)
	if box.SetBackdrop then
		box:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 14,
			insets = { left = 4, right = 4, top = 4, bottom = 4 },
		})
		box:SetBackdropColor(0, 0, 0, 0.5)
		box:SetBackdropBorderColor(0.5, 0.5, 0.5)
	end

	local ok, scroll = pcall(CreateFrame, "ScrollFrame", nil, box, "UIPanelScrollFrameTemplate")
	local hasBar = ok
	if not ok then scroll = CreateFrame("ScrollFrame", nil, box) end
	scroll:SetPoint("TOPLEFT", 6, -6)
	scroll:SetPoint("BOTTOMRIGHT", hasBar and -28 or -6, 6)
	local child = CreateFrame("Frame", nil, scroll)
	child:SetSize(1, 1)
	scroll:SetScrollChild(child)
	scroll:SetScript("OnSizeChanged", function(self, w) child:SetWidth(w) end)
	if not hasBar then
		scroll:EnableMouseWheel(true)
		scroll:SetScript("OnMouseWheel", function(self, delta)
			local max = math.max(0, child:GetHeight() - self:GetHeight())
			self:SetVerticalScroll(math.min(max, math.max(0, self:GetVerticalScroll() - delta * ROW_H * 2)))
		end)
	end

	local empty = box:CreateFontString(nil, "ARTWORK", "GameFontDisable")
	empty:SetPoint("CENTER")
	empty:SetText("You don't have any companions yet.")

	local rows = {}
	local function Row(i)
		local r = rows[i]
		if r then return r end
		r = CreateFrame("Button", nil, child)
		r:SetHeight(ROW_H)
		r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
		r:SetPoint("RIGHT")
		r.sel = r:CreateTexture(nil, "BACKGROUND")
		r.sel:SetAllPoints()
		r.sel:SetColorTexture(1, 0.82, 0, 0.18)
		local hl = r:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.08)
		r.icon = r:CreateTexture(nil, "ARTWORK")
		r.icon:SetSize(ROW_H - 4, ROW_H - 4)
		r.icon:SetPoint("LEFT", 4, 0)
		r.name = r:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		r.name:SetPoint("LEFT", r.icon, "RIGHT", 8, 0)
		r.note = r:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		r.note:SetPoint("RIGHT", -8, 0)
		r:SetScript("OnClick", function(self)
			db.mode, db.petID = "pet", self.pet.id
			if self.pet.summonable then ns.Summon(self.pet.id) end
			for _, fn in ipairs(refreshers) do fn() end
		end)
		r:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			if not (GameTooltip.SetCompanionPet and pcall(GameTooltip.SetCompanionPet, GameTooltip, self.pet.id)) then
				GameTooltip:SetText(self.pet.name, 1, 1, 1)
				if self.pet.species then GameTooltip:AddLine(self.pet.species) end
			end
			GameTooltip:AddLine("Click to always summon this one (and summon it now).", 0.4, 1, 0.4, true)
			GameTooltip:Show()
		end)
		r:SetScript("OnLeave", function() GameTooltip:Hide() end)
		rows[i] = r
		return r
	end

	local function RefreshList()
		local pets = ns.OwnedPets()
		local outID = C_PetJournal and C_PetJournal.GetSummonedPetGUID and C_PetJournal.GetSummonedPetGUID()
		for i, p in ipairs(pets) do
			local r = Row(i)
			r.pet = p
			r.icon:SetTexture(p.icon)
			r.icon:SetDesaturated(not p.summonable)
			r.name:SetText(p.name .. (p.species and ("  |cff999999" .. p.species .. "|r") or ""))
			r.name:SetTextColor(p.summonable and 1 or 0.5, p.summonable and 1 or 0.5, p.summonable and 1 or 0.5)
			local notes = {}
			if p.favorite then notes[#notes + 1] = "|cffffd100favorite|r" end
			if p.id == outID then notes[#notes + 1] = "|cff40c040out now|r" end
			if not p.summonable then notes[#notes + 1] = "|cff999999can't summon|r" end
			r.note:SetText(table.concat(notes, "  "))
			r.sel:SetShown(db.mode == "pet" and db.petID == p.id)
			r:Show()
		end
		for i = #pets + 1, #rows do rows[i]:Hide() end
		child:SetHeight(math.max(1, #pets * ROW_H))
		empty:SetShown(#pets == 0)
	end
	refreshers[#refreshers + 1] = RefreshList

	panel:SetScript("OnShow", function()
		for _, fn in ipairs(refreshers) do fn() end
	end)
	-- Keep the "out now" / "last" text current while the page is open.
	ns.OnPetChanged = function()
		if panel:IsVisible() then
			for _, fn in ipairs(refreshers) do fn() end
		end
	end

	category = Settings.RegisterCanvasLayoutCategory(panel, "FireCompanion")
	Settings.RegisterAddOnCategory(category)
end

function ns.OpenOptions()
	if not category then
		ns.Print("/fcomp summon, /fcomp status")
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
