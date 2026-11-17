-- Pins on the minimap: where they are around you, or on the minimap's edge
-- (faded) pointing the way when they're further off. Follows a rotating
-- minimap. Hidden where the game doesn't give your position (instances).
local _, ns = ...

local Minimap_ = {}
ns.Minimap = Minimap_

local SIZE = 16
local EDGE_SIZE = 12
-- The arrow to the tracked pin: the game's navigation arrow (points up), at
-- its own size; else the minimap's guide arrow.
local ARROW_ATLAS = "Navigation-Tracked-Arrow"
local ARROW_FILE = "Interface\\Minimap\\ROTATING-MINIMAPGUIDEARROW"
local arrowW, arrowH = 24, 24
local ARROW_SCALE = 0.6 -- of the navigation arrow's own size
local INTERVAL = 0.05
-- Yards across the minimap at each zoom level, for clients without
-- C_Minimap.GetViewRadius.
local OUTDOOR = { [0] = 466.67, 400, 333.33, 266.67, 200, 133.33 }
local INDOOR = { [0] = 300, 240, 180, 120, 80, 50 }

local holder, pool, arrow = nil, {}, nil

local function Radius()
	if C_Minimap and C_Minimap.GetViewRadius then
		local ok, r = pcall(C_Minimap.GetViewRadius)
		if ok and type(r) == "number" and r > 0 and not ns.IsSecret(r) then return r end
	end
	local zoom = Minimap:GetZoom() or 0
	local list = (IsIndoors and IsIndoors()) and INDOOR or OUTDOOR
	return (list[zoom] or list[0]) / 2
end

local function Facing()
	if not (GetCVar and GetCVar("rotateMinimap") == "1") then return nil end
	local f = GetPlayerFacing and GetPlayerFacing()
	if not f or ns.IsSecret(f) then return nil end
	return f
end

local function HideAll(from)
	for i = from or 1, #pool do pool[i]:Hide() end
	if not from and arrow then arrow:Hide() end
	if not from and ns.Guild then ns.Guild.DrawMinimap(holder, nil) end
end

local function Update()
	if not ns.db or not ns.db.minimap then return HideAll() end
	local map, px, py = ns.PlayerPos()
	if not map then return HideAll() end
	local half = Minimap:GetWidth() / 2
	local perYard = half / Radius()
	local scale = ns.db.minimapScale or 1
	local size, edgeSize = SIZE * scale, EDGE_SIZE * scale
	local facing = Facing()
	local cos, sin = 1, 0
	if facing then cos, sin = math.cos(facing), math.sin(facing) end
	local n = 0
	local showArrow = false
	ns.ForEach(function(owner, id, pin)
		local dx, dy = ns.Offset(pin, map, px, py)
		if not dx then return end
		-- east and north, turned with the minimap when it rotates
		local east, north = dx, -dy
		if facing then east, north = east * cos + north * sin, -east * sin + north * cos end
		local x, y = east * perYard, north * perYard
		local dist = math.sqrt(x * x + y * y)
		local edge = half - edgeSize / 2 - 2
		local off = dist > edge
		if off and ns.IsTracked(pin) then
			-- The tracked pin, off the minimap: an arrow on the edge instead.
			local r = half - math.max(arrowW, arrowH) * scale / 2 + 4
			arrow:SetSize(arrowW * scale, arrowH * scale)
			arrow.owner, arrow.id, arrow.pin = owner, id, pin
			arrow:ClearAllPoints()
			arrow:SetPoint("CENTER", Minimap, "CENTER", x / dist * r, y / dist * r)
			arrow.icon:SetRotation(math.atan2(-x, y))
			arrow:Show()
			showArrow = true
			return
		end
		if off then x, y = x / dist * edge, y / dist * edge end
		n = n + 1
		local f = pool[n]
		if not f then
			f = ns.CreatePinFrame(holder, SIZE)
			pool[n] = f
		end
		ns.SetPinFrame(f, owner, id, pin)
		f:SetSize(off and edgeSize or size, off and edgeSize or size)
		f:SetAlpha(off and 0.6 or 1)
		f.label:SetShown(not off)
		f:ClearAllPoints()
		f:SetPoint("CENTER", Minimap, "CENTER", x, y)
		f:Show()
	end)
	HideAll(n + 1)
	if not showArrow then arrow:Hide() end
	if ns.Guild then ns.Guild.DrawMinimap(holder, map, px, py, perYard, cos, sin, half, scale) end
end

function Minimap_.Refresh()
	if holder then Update() end
end

local function Setup()
	if holder or not Minimap then return end
	holder = CreateFrame("Frame", nil, Minimap)
	holder:SetAllPoints(Minimap)
	holder:SetFrameLevel(Minimap:GetFrameLevel() + 5)
	arrow = CreateFrame("Frame", nil, holder)
	arrow:SetFrameLevel(holder:GetFrameLevel() + 2)
	arrow.icon = arrow:CreateTexture(nil, "OVERLAY")
	arrow.icon:SetAllPoints()
	ns.PinMouse(arrow)
	local info = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(ARROW_ATLAS)
	if info and info.width and info.width > 0 then
		arrow.icon:SetAtlas(ARROW_ATLAS, false, "TRILINEAR")
		arrowW, arrowH = info.width * ARROW_SCALE, info.height * ARROW_SCALE
	else
		arrow.icon:SetTexture(ARROW_FILE, nil, nil, "TRILINEAR")
	end
	-- Smooth edges when turned (no snapping to the pixel grid).
	if arrow.icon.SetSnapToPixelGrid then
		arrow.icon:SetSnapToPixelGrid(false)
		arrow.icon:SetTexelSnappingBias(0)
	end
	arrow:Hide()
	local elapsed = 0
	holder:SetScript("OnUpdate", function(_, dt)
		elapsed = elapsed + dt
		if elapsed < INTERVAL then return end
		elapsed = 0
		local ok, err = pcall(Update)
		if not ok and ns.debug then ns.Print("minimap: " .. tostring(err)) end
	end)
end

ns.OnChange(Minimap_.Refresh)

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", Setup)
