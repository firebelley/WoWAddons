-- A coin on the edge of the minimap: click for the price window, right-click
-- for options, drag to move it around the minimap.
local _, ns = ...

local MB = {}
ns.MinimapButton = MB

local ICON = "Interface\\Icons\\INV_Misc_Coin_01"
local button

local function Place()
	local angle = math.rad(ns.db.minimapAngle or 200)
	local radius = Minimap:GetWidth() / 2 + 5 -- the same distance as other addons' minimap buttons
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

-- While dragging, follow the cursor around the minimap's edge.
local function FollowCursor()
	local mx, my = Minimap:GetCenter()
	local scale = Minimap:GetEffectiveScale()
	local cx, cy = GetCursorPosition()
	ns.db.minimapAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
	Place()
end

local function Create()
	button = CreateFrame("Button", "FireAuctionMinimapButton", Minimap)
	button:SetSize(31, 31)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	-- The same look as the game's own round minimap buttons.
	local bg = button:CreateTexture(nil, "BACKGROUND")
	bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	bg:SetSize(20, 20)
	bg:SetPoint("TOPLEFT", 7, -5)
	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetTexture(ICON)
	icon:SetSize(17, 17)
	icon:SetPoint("TOPLEFT", 7, -6)
	icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT")

	button:SetScript("OnClick", function(_, mouse)
		if mouse == "RightButton" then
			ns.Options.Open()
		else
			ns.Window.Toggle()
		end
	end)
	ns.ClickSound(button)
	button:SetScript("OnDragStart", function(self)
		self:LockHighlight()
		self:SetScript("OnUpdate", FollowCursor)
		GameTooltip:Hide()
	end)
	button:SetScript("OnDragStop", function(self)
		self:UnlockHighlight()
		self:SetScript("OnUpdate", nil)
	end)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("FireAuction", 1, 1, 1)
		GameTooltip:AddLine(ns.LastScanText(ns.Realm()) or "Not scanned yet - open the auction house.", 0.7, 0.7, 0.7)
		if ns.Sales then
			local _, sold, unknown = ns.SafeCall(ns.Sales.AddLines, GameTooltip, 10)
			local _, listed = ns.SafeCall(ns.Sales.AddListings, GameTooltip, 10)
			-- Your gold: now, once the sales' mail is collected, and if everything listed sells too.
			sold = type(sold) == "number" and sold or nil
			listed = type(listed) == "number" and listed or nil
			local money = GetMoney and GetMoney()
			if money and (sold or listed) then
				local atLeast = unknown and "at least " or ""
				GameTooltip:AddLine(" ")
				GameTooltip:AddDoubleLine("Gold now", ns.Money(money), 1, 0.82, 0, 1, 1, 1)
				local total = money
				if sold then
					total = total + sold
					GameTooltip:AddDoubleLine("With sales", atLeast .. ns.Money(total), 1, 0.82, 0, 1, 1, 1)
				end
				if listed then
					GameTooltip:AddDoubleLine("If listings sell", (sold and atLeast or "") .. ns.Money(total + listed),
						1, 0.82, 0, 1, 1, 1)
				end
			end
		end
		GameTooltip:AddLine(" ")
		GameTooltip:AddDoubleLine("Click", "Price window", 1, 0.82, 0, 1, 1, 1)
		GameTooltip:AddDoubleLine("Right-click", "Options", 1, 0.82, 0, 1, 1, 1)
		GameTooltip:AddDoubleLine("Drag", "Move", 1, 0.82, 0, 1, 1, 1)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)
	Place()
end

function MB.Update()
	if ns.db.minimapButton then
		if not button then Create() end
		button:Show()
	elseif button then
		button:Hide()
	end
end

ns.On("PLAYER_LOGIN", function()
	if Minimap then MB.Update() end
end)
