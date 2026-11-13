-- Floating windows beside the auction house (the purchase tracker, seeding):
-- Blizzard's own window frame, dragged anywhere (remembered), each opened and
-- closed by a tab on the auction house window's right edge.
local _, ns = ...

local TAB_TOP, TAB_STEP = -36, 44 -- where the first tab goes, and the gap to the next

-- A tab on the auction house window's right edge (slot 1 at the top, 2 under
-- it...) that turns ns.db[key] on and off. The icon is always shown; a gold
-- outline marks it on. tab:Refresh() after ns.db[key] changes elsewhere.
function ns.SideTab(slot, icon, title, key, onToggle)
	local tab = CreateFrame("Button", nil, AuctionHouseFrame)
	tab:SetSize(32, 32)
	tab:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 0, TAB_TOP - (slot - 1) * TAB_STEP)
	local back = tab:CreateTexture(nil, "BACKGROUND")
	back:SetSize(64, 64)
	back:SetPoint("TOPLEFT", -3, 11)
	back:SetTexture("Interface\\SpellBook\\SpellBook-SkillLineTab")
	local image = tab:CreateTexture(nil, "ARTWORK")
	image:SetAllPoints()
	image:SetTexture(icon)
	local outline = tab:CreateTexture(nil, "OVERLAY")
	outline:SetAllPoints()
	outline:SetTexture("Interface\\Buttons\\CheckButtonHilight")
	outline:SetBlendMode("ADD")
	tab:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	function tab.Refresh() outline:SetShown(ns.db[key] and true or false) end
	tab:SetScript("OnClick", function()
		ns.db[key] = not ns.db[key]
		tab.Refresh()
		if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB then PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB) end
		if onToggle then ns.SafeCall(onToggle) end
	end)
	tab:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(title, 1, 1, 1)
		GameTooltip:AddLine("Click to show or hide.", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	tab:SetScript("OnLeave", function() GameTooltip:Hide() end)
	tab.Refresh()
	tab:Hide()
	return tab
end

-- A floating window: Blizzard's portrait frame (portrait, title bar, close
-- button), the same as the auction house's - a plain dark box if this client
-- lacks it - with a darker inset from insetTop down for its rows. Above the
-- auction house window, below popups. Dragged anywhere; where it goes is
-- saved in ns.db[pointKey], else defaultPoint() places it. Closing it turns
-- ns.db[key] off (and refreshes `tab`, set later).
function ns.SideWindow(name, width, insetTop, pointKey, defaultPoint, key)
	local ok, f = pcall(CreateFrame, "Frame", name, AuctionHouseFrame, "PortraitFrameTemplate")
	if not ok then
		f = CreateFrame("Frame", name, AuctionHouseFrame, BackdropTemplateMixin and "BackdropTemplate")
		if f.SetBackdrop then
			f:SetBackdrop({
				bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
				edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
				tile = true, tileSize = 16, edgeSize = 16,
				insets = { left = 4, right = 4, top = 4, bottom = 4 },
			})
			f:SetBackdropColor(0.06, 0.06, 0.06, 0.95)
		end
		f.fallbackIcon = f:CreateTexture(nil, "ARTWORK")
		f.fallbackIcon:SetSize(40, 40)
		f.fallbackIcon:SetPoint("TOPLEFT", 12, -12)
		f.fallbackTitle = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
		f.fallbackTitle:SetPoint("TOPLEFT", 62, -8)
	end
	f:SetFrameStrata("HIGH")
	if ok then
		local insetOK, inset = pcall(CreateFrame, "Frame", nil, f, "InsetFrameTemplate")
		if insetOK and inset then
			inset:SetPoint("TOPLEFT", 4, insetTop)
			inset:SetPoint("BOTTOMRIGHT", -6, 4)
			if inset.SetFrameLevel and f.GetFrameLevel then inset:SetFrameLevel(f:GetFrameLevel() or 1) end
		end
	end
	f:SetSize(width, 200)
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self) self:StartMoving() end)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		self:SetUserPlaced(false) -- the position is saved here
		local point, _, relPoint, x, y = self:GetPoint()
		ns.db[pointKey] = { point, relPoint, x, y }
	end)
	-- The close button turns it off, like its tab.
	if type(f.CloseButton) == "table" then
		f.CloseButton:SetScript("OnClick", function()
			ns.db[key] = false
			if f.tab then f.tab.Refresh() end
			f:Hide()
		end)
	end
	f:ClearAllPoints()
	local p = ns.db[pointKey]
	if p then f:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else defaultPoint(f) end
	f:Hide()
	return f
end

function ns.SideWindowTitle(f, text)
	if f.SetTitle then pcall(f.SetTitle, f, text) end
	if type(f.fallbackTitle) == "table" then f.fallbackTitle:SetText(text) end
end

function ns.SideWindowIcon(f, texture)
	if f.SetPortraitToAsset then pcall(f.SetPortraitToAsset, f, texture) end
	if type(f.fallbackIcon) == "table" then f.fallbackIcon:SetTexture(texture) end
end
