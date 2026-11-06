-- Shared window builder for the bag and bank windows: Blizzard frame styling,
-- title/portrait, side tabs, saved position, and the section grid layout.
local _, ns = ...
local API = ns.API

local SLOT = 37
local SPACING = 4
local SECTION_TITLE = 18
local SECTION_GAP = 8
local FOOTER_HEIGHT = 20
local TAB_SIZE = 32
local TAB_GAP = 12
local MIN_WIDTH = 250

ns.SLOT_SIZE = SLOT
ns.windows = {}

-- Empty-slot tints so special sections are easy to tell apart.
local SECTION_TINT = {
	main = { 1, 1, 1 },
	keyring = { 1, 0.9, 0.5 },
	default = { 0.65, 0.85, 1 },
}

---------------------------------------------------------------------------
-- Frame styling
--
-- Try Blizzard's own window templates first (same look as the default bag,
-- bank and character windows). If none exist on this client, fall back to a
-- simple dark backdrop.
---------------------------------------------------------------------------
local TEMPLATES = { "PortraitFrameFlatTemplate", "PortraitFrameTemplate", "ButtonFrameTemplate" }

-- Content insets and where the status line / tabs go, per style.
local METRICS_BLIZZARD = { left = 12, right = 12, top = 64, bottom = 12, statusX = 62, statusY = -30, tabX = 0, tabTop = -40, titleInfoX = 62, titleInfoY = -11 }
local METRICS_FALLBACK = { left = 10, right = 10, top = 50, bottom = 10, statusX = 12, statusY = -30, tabX = -2, tabTop = -34, titleInfoX = 12, titleInfoY = -16 }

local function Mix(target, source)
	for k, v in pairs(source) do target[k] = v end
end

local function ApplyFallbackStyle(f)
	if not f.SetBackdrop and BackdropTemplateMixin then
		Mix(f, BackdropTemplateMixin)
		f:HookScript("OnSizeChanged", f.OnBackdropSizeChanged)
	end
	if f.SetBackdrop then
		f:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 16,
			insets = { left = 4, right = 4, top = 4, bottom = 4 },
		})
		f:SetBackdropColor(0.05, 0.05, 0.07, 0.92)
		f:SetBackdropBorderColor(0.4, 0.4, 0.45, 1)
	end

	f.fbTitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.fbTitle:SetPoint("TOP", 0, -10) -- centred, leaving the left for title info

	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 2, 2)
	f.CloseButton = close
end

local function CreateStyledFrame(name)
	for _, template in ipairs(TEMPLATES) do
		if API.TemplateExists(template) ~= false then
			local ok, f = pcall(CreateFrame, "Frame", name, UIParent, template)
			if ok and f then
				if f.CloseButton then
					if f.Inset then f.Inset:Hide() end
					if ButtonFrameTemplate_HideButtonBar and f.Inset then
						pcall(ButtonFrameTemplate_HideButtonBar, f)
					end
					return f, METRICS_BLIZZARD
				end
				-- The template didn't actually apply; style this frame ourselves.
				ApplyFallbackStyle(f)
				return f, METRICS_FALLBACK
			end
		end
	end
	local f = CreateFrame("Frame", name, UIParent)
	ApplyFallbackStyle(f)
	return f, METRICS_FALLBACK
end

local function SetWindowTitle(f, text)
	if f.SetTitle then
		f:SetTitle(text)
		return
	end
	local t = (f.TitleContainer and f.TitleContainer.TitleText) or f.TitleText or f.fbTitle
	if t then t:SetText(text) end
end

local function SetWindowPortrait(f, icon)
	if f.SetPortraitToAsset then
		f:SetPortraitToAsset(icon)
		return
	end
	local p = (f.PortraitContainer and f.PortraitContainer.portrait) or f.portrait
	if p then
		if SetPortraitToTexture then SetPortraitToTexture(p, icon) else p:SetTexture(icon) end
	end
end

---------------------------------------------------------------------------
-- Window methods
---------------------------------------------------------------------------
local Window = {}

function Window:SetStatus(text)
	self.statusText:SetText(text or "")
end

-- A message shown instead of slots (e.g. "visit a banker...").
function Window:SetMessage(text)
	self.messageText:SetText(text or "")
	self.messageText:SetShown(text ~= nil)
end

-- Text on the left side of the title bar (e.g. gold).
function Window:SetTitleInfo(text)
	self.titleInfoText:SetText(text or "")
end

-- Text on the right side of the title bar (e.g. a currency). The returned
-- frame covers the text, for tooltips.
function Window:SetTitleRight(text)
	local fs = self.titleRight.text
	fs:SetText(text or "")
	self.titleRight:SetWidth(math.max(1, fs:GetStringWidth()))
	self.titleRight:SetShown(text ~= nil and text ~= "")
	return self.titleRight
end

function Window:SetFooter(text)
	if self.footerText then self.footerText:SetText(text or "") end
end

-- Side tabs: icon buttons sticking out of the window's right edge.
function Window:AddTab(opts)
	local tab = CreateFrame("Button", nil, self)
	tab:SetSize(TAB_SIZE, TAB_SIZE)
	tab:SetPoint("TOPLEFT", self, "TOPRIGHT", self.metrics.tabX,
		self.metrics.tabTop - #self.tabs * (TAB_SIZE + TAB_GAP))

	-- The spellbook's side-tab frame art.
	local art = tab:CreateTexture(nil, "BACKGROUND")
	art:SetTexture("Interface\\SpellBook\\SpellBook-SkillLineTab")
	art:SetSize(64, 64)
	art:SetPoint("TOPLEFT", -3, 11)

	tab.icon = tab:CreateTexture(nil, "ARTWORK")
	tab.icon:SetAllPoints()
	if API.AtlasExists(opts.atlas) then
		tab.icon:SetAtlas(opts.atlas)
	else
		tab.icon:SetTexture(opts.icon)
		tab.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	end

	local highlight = tab:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
	highlight:SetBlendMode("ADD")
	highlight:SetAllPoints()

	tab.selected = tab:CreateTexture(nil, "OVERLAY")
	tab.selected:SetTexture("Interface\\Buttons\\CheckButtonHilight")
	tab.selected:SetBlendMode("ADD")
	tab.selected:SetAllPoints()
	tab.selected:Hide()

	function tab:SetSelected(on) self.selected:SetShown(on) end
	function tab:SetEnabledLook(on) self.icon:SetDesaturated(not on) end

	tab:SetScript("OnMouseDown", function(self)
		self.icon:ClearAllPoints()
		self.icon:SetPoint("TOPLEFT", 1, -1)
		self.icon:SetPoint("BOTTOMRIGHT", 1, -1)
	end)
	tab:SetScript("OnMouseUp", function(self)
		self.icon:ClearAllPoints()
		self.icon:SetAllPoints()
	end)
	tab:SetScript("OnClick", opts.onClick)
	tab:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(opts.title)
		local text = type(opts.text) == "function" and opts.text() or opts.text
		if text then GameTooltip:AddLine(text, 1, 1, 1, true) end
		GameTooltip:Show()
	end)
	tab:SetScript("OnLeave", GameTooltip_Hide)

	table.insert(self.tabs, tab)
	-- Keep the tabs on screen when the window is dragged to the right edge.
	self:SetClampRectInsets(0, TAB_SIZE, 0, 0)
	return tab
end

---------------------------------------------------------------------------
-- Background: an opaque, tiling texture behind the slots.
---------------------------------------------------------------------------
local BACKGROUNDS = {
	rock = "Interface\\FrameGeneral\\UI-Background-Rock",
	marble = "Interface\\FrameGeneral\\UI-Background-Marble",
	dark = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
}
ns.BACKGROUNDS = BACKGROUNDS

function Window:ApplyBackground()
	if not self.fbBg then
		local bg = self:CreateTexture(nil, "BACKGROUND", nil, 2)
		if self.Bg then
			bg:SetAllPoints(self.Bg)
		else
			bg:SetPoint("TOPLEFT", 4, -4)
			bg:SetPoint("BOTTOMRIGHT", -4, 4)
		end
		self.fbBg = bg
	end
	local path = BACKGROUNDS[ns.db.background]
	if path then
		self.fbBg:SetTexture(path, "REPEAT", "REPEAT")
		self.fbBg:SetHorizTile(true)
		self.fbBg:SetVertTile(true)
		self.fbBg:Show()
	else
		self.fbBg:Hide() -- "default": the frame's own background
	end
end

---------------------------------------------------------------------------
-- Position
---------------------------------------------------------------------------
function Window:ApplyPosition()
	local anchor = self.opts.anchor
	local pos = ns.db.positions[self.opts.key] or self.opts.defaultPosition
	self:ClearAllPoints()
	self:SetPoint(anchor, UIParent, anchor, pos.x, pos.y)
end

-- Saved relative to the window's anchor corner, so the bag window grows up and
-- to the left and the bank window grows down and to the right.
function Window:SavePosition()
	local scale = self:GetEffectiveScale() / UIParent:GetEffectiveScale()
	local x, y
	if self.opts.anchor == "TOPLEFT" then
		x = self:GetLeft()
		y = self:GetTop() - UIParent:GetTop() / scale
	else
		x = self:GetRight() - UIParent:GetRight() / scale
		y = self:GetBottom()
	end
	ns.db.positions[self.opts.key] = { x = x, y = y }
	self:ApplyPosition()
end

---------------------------------------------------------------------------
-- Layout
--
-- sections: from ns.GroupSections. acquire(bag, slot, section) returns the
-- button for that slot; each button has an fbUpdate method.
---------------------------------------------------------------------------
function Window:LayoutSections(sections, acquire)
	local m = self.metrics
	local cols = ns.db[self.opts.columnsKey]

	for b in pairs(self.shownButtons) do b:Hide() end
	wipe(self.shownButtons)
	for _, label in ipairs(self.labels) do label:Hide() end

	local gridWidth = cols * SLOT + (cols - 1) * SPACING
	local width = math.max(MIN_WIDTH, m.left + m.right + gridWidth)
	local y = -m.top
	local labelIndex = 0
	local anySlots = false

	for i, section in ipairs(sections) do
		if section.numSlots > 0 then
			anySlots = true
			if section.title then
				labelIndex = labelIndex + 1
				local label = self.labels[labelIndex]
				if not label then
					label = self:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
					label:SetJustifyH("LEFT")
					self.labels[labelIndex] = label
				end
				label:ClearAllPoints()
				label:SetPoint("TOPLEFT", self, "TOPLEFT", m.left + 2, y - 2)
				local text = section.title
				if section.extra then text = text .. "  |cffffffff" .. section.extra .. "|r" end
				label:SetText(("%s  |cffaaaaaa%d/%d|r"):format(
					text, section.numSlots - section.numFree, section.numSlots))
				label:Show()
				y = y - SECTION_TITLE
			end

			local tint = SECTION_TINT[section.key]
				or (section.plain and SECTION_TINT.main)
				or SECTION_TINT.default
			local index = 0
			for _, entry in ipairs(section.bags) do
				for slot = 1, entry.numSlots do
					local b = acquire(entry.bag, slot, section)
					local col = index % cols
					local row = math.floor(index / cols)
					b:ClearAllPoints()
					b:SetPoint("TOPLEFT", self, "TOPLEFT",
						m.left + col * (SLOT + SPACING),
						y - row * (SLOT + SPACING))
					b.fbBackground:SetVertexColor(tint[1], tint[2], tint[3])
					b:Show()
					b:fbUpdate()
					self.shownButtons[b] = true
					index = index + 1
				end
			end

			local rows = math.ceil(index / cols)
			y = y - rows * (SLOT + SPACING) + SPACING
			if i < #sections then y = y - SECTION_GAP end
		end
	end

	if not anySlots and self.messageText:IsShown() then
		self.messageText:SetWidth(width - m.left - m.right)
		y = y - self.messageText:GetStringHeight() - 4
	end

	local height = -y + m.bottom + (self.footerText and FOOTER_HEIGHT or 0)
	self:SetSize(width, height)
end

-- Cheap refresh of visible buttons (locks, cooldowns) without relayout.
function Window:UpdateButtons()
	if not self:IsShown() then return end
	for b in pairs(self.shownButtons) do b:fbUpdate() end
end

-- Coalesce bursts of events into one layout pass.
function Window:RequestRefresh()
	self.dirty = true
	if not self:IsShown() or self.refreshPending then return end
	self.refreshPending = true
	C_Timer.After(0.05, function()
		self.refreshPending = false
		if self:IsShown() and self.dirty then
			self.dirty = false
			ns.SafeCall(self.opts.refresh, self)
		end
	end)
end

---------------------------------------------------------------------------
-- Constructor
--
-- opts: name, title, icon, key (for saved position), anchor ("TOPLEFT" or
-- "BOTTOMRIGHT"), defaultPosition {x, y}, columnsKey (db setting), footer
-- (bool), openSound, closeSound, refresh(window)
---------------------------------------------------------------------------
function ns.CreateWindow(opts)
	local f, metrics = CreateStyledFrame(opts.name)
	Mix(f, Window)
	f.opts = opts
	f.metrics = metrics
	f.tabs = {}
	f.labels = {}
	f.shownButtons = {}
	f.dirty = true

	f:Hide()
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:SetSize(MIN_WIDTH, 200)

	SetWindowTitle(f, opts.title)
	if opts.icon then SetWindowPortrait(f, opts.icon) end
	f.CloseButton:SetScript("OnClick", function() f:Hide() end)

	-- Text on the left of the title bar, just right of the portrait. It lives on
	-- a child frame so it draws above the template's title bar art.
	local titleInfo = CreateFrame("Frame", nil, f)
	titleInfo:SetAllPoints(f)
	titleInfo:SetFrameLevel(f.CloseButton:GetFrameLevel())
	f.titleInfoText = titleInfo:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.titleInfoText:SetJustifyH("LEFT")
	if f.TitleContainer then
		-- Modern templates: the title bar strip, so it's vertically centred.
		f.titleInfoText:SetPoint("LEFT", f.TitleContainer, "LEFT", 4, 0)
	else
		f.titleInfoText:SetPoint("LEFT", f, "TOPLEFT", metrics.titleInfoX, metrics.titleInfoY)
	end

	-- Right side of the title bar, just left of the close button.
	local titleRight = CreateFrame("Frame", nil, f)
	titleRight:SetFrameLevel(f.CloseButton:GetFrameLevel())
	titleRight:SetHeight(16)
	local TITLE_RIGHT_GAP = 8 -- space between the text and the close button
	titleRight:SetPoint("RIGHT", f.CloseButton, "LEFT", -TITLE_RIGHT_GAP, 0)
	titleRight.text = titleRight:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	titleRight.text:SetPoint("RIGHT")
	titleRight:Hide()
	f.titleRight = titleRight

	f.statusText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.statusText:SetPoint("TOPLEFT", metrics.statusX, metrics.statusY)
	f.statusText:SetJustifyH("LEFT")

	f.messageText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	f.messageText:SetPoint("TOPLEFT", metrics.left + 2, -metrics.top)
	f.messageText:SetJustifyH("LEFT")
	f.messageText:Hide()

	if opts.footer then
		f.footerText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		f.footerText:SetPoint("BOTTOMRIGHT", -metrics.right - 2, metrics.bottom)
	end

	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self)
		if not ns.db.locked then self:StartMoving() end
	end)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		self:SavePosition()
	end)

	f:HookScript("OnShow", function(self)
		self.dirty = false
		ns.SafeCall(self.opts.refresh, self)
		if opts.openSound then PlaySound(opts.openSound) end
	end)
	f:HookScript("OnHide", function()
		if opts.closeSound then PlaySound(opts.closeSound) end
	end)

	-- Escape closes the window.
	table.insert(UISpecialFrames, opts.name)
	table.insert(ns.windows, f)
	return f
end

function ns.ApplyWindowSettings()
	for _, w in ipairs(ns.windows) do
		w:SetScale(ns.db.scale)
		w:ApplyBackground()
		w:ApplyPosition()
		w:RequestRefresh()
	end
end

ns.On("PLAYER_LOGIN", function() ns.ApplyWindowSettings() end)
