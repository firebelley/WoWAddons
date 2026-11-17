-- Floating windows beside the auction house (the purchase tracker, seeding):
-- Blizzard's own window frame, dragged anywhere (remembered). They show
-- while the item's Quick buy session is on, and can't be closed meanwhile.
local _, ns = ...

-- A floating window: Blizzard's portrait frame (portrait, title bar, close
-- button), the same as the auction house's - a plain dark box if this client
-- lacks it - with a darker inset from insetTop down for its rows. Above the
-- auction house window, below popups. Dragged anywhere; where it goes is
-- saved in ns.db[pointKey], else defaultPoint() places it. No close button.
function ns.SideWindow(name, width, insetTop, pointKey, defaultPoint)
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
	if type(f.CloseButton) == "table" then f.CloseButton:Hide() end
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
