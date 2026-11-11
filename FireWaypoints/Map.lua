-- Pins on the world map, and shift-click to drop one.
--
-- The pins are FireWaypoints' own frames laid over the map's canvas (nothing
-- is added to the map's own pin system), positioned whenever the map changes,
-- zooms or resizes. Clicks are seen by hooking the map's mouse handlers, after
-- the map has handled them.
local _, ns = ...

local Map = {}
ns.Map = Map

local PIN_SIZE = 26
local CLICK_SLOP = 8 -- pixels the cursor may move for it to still be a click
local ATLAS = "Waypoint-MapPin-Untracked"
local FALLBACK = "Interface\\COMMON\\Indicator-Yellow"

---------------------------------------------------------------------------
-- A pin's look and tooltip (the minimap uses these too)
---------------------------------------------------------------------------

local function HasAtlas(name)
	return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

local function ShowTooltip(f)
	local pin = f.pin
	if not pin then return end
	GameTooltip:SetOwner(f, "ANCHOR_RIGHT")
	local r, g, b = ns.OwnerColor(f.owner)
	GameTooltip:SetText(f.owner and ("%s's pin %d"):format(f.owner, f.id) or ("Your pin %d"):format(f.id), r, g, b)
	GameTooltip:AddLine(("%s  %.1f, %.1f"):format(ns.MapName(pin.map), pin.x * 100, pin.y * 100), 1, 1, 1)
	local d = ns.Distance(pin)
	if d then GameTooltip:AddLine(("%d yards away"):format(d), 0.7, 0.7, 0.7) end
	GameTooltip:AddLine(f.owner and "Right-click to hide it" or "Right-click to remove it (for your group too)",
		0.25, 1, 0.25)
	GameTooltip:Show()
end

function ns.CreatePinFrame(parent, size)
	local f = CreateFrame("Frame", nil, parent)
	f:SetSize(size, size)
	f.icon = f:CreateTexture(nil, "ARTWORK")
	f.icon:SetAllPoints()
	if HasAtlas(ATLAS) then
		f.icon:SetAtlas(ATLAS)
	else
		f.icon:SetTexture(FALLBACK)
	end
	f.icon:SetDesaturated(true) -- tinted by owner below
	f.label = f:CreateFontString(nil, "OVERLAY")
	local font = GameFontNormal:GetFont()
	f.label:SetFont(font, math.max(9, math.floor(size * 0.45)), "OUTLINE")
	f.label:SetPoint("BOTTOMLEFT", f, "RIGHT", -size * 0.15, -size * 0.1)
	f:EnableMouse(true)
	-- Left clicks go through to the map (or minimap) underneath.
	if f.SetPassThroughButtons then pcall(f.SetPassThroughButtons, f, "LeftButton") end
	f:SetScript("OnEnter", ShowTooltip)
	f:SetScript("OnLeave", function() GameTooltip:Hide() end)
	f:SetScript("OnMouseUp", function(self, button)
		if button == "RightButton" and self.id then
			GameTooltip:Hide()
			ns.Remove(self.owner, self.id)
		end
	end)
	return f
end

function ns.SetPinFrame(f, owner, id, pin)
	f.owner, f.id, f.pin = owner, id, pin
	local r, g, b = ns.OwnerColor(owner)
	f.icon:SetVertexColor(r, g, b)
	f.label:SetText(id)
	f.label:SetTextColor(r, g, b)
end

---------------------------------------------------------------------------
-- The world map
---------------------------------------------------------------------------

local WM, canvas
local pool = {}

local function FrameLevel()
	local mgr = WM.GetPinFrameLevelsManager and WM:GetPinFrameLevelsManager()
	if mgr and mgr.GetValidFrameLevel then
		local ok, level = pcall(mgr.GetValidFrameLevel, mgr, "PIN_FRAME_LEVEL_WAYPOINT_LOCATION")
		if ok and type(level) == "number" then return level + 1 end
	end
	return canvas:GetFrameLevel() + 100
end

function Map.Refresh()
	if not (WM and WM:IsShown()) then return end
	local map = WM:GetMapID()
	local canvasScale = WM.GetCanvasScale and WM:GetCanvasScale() or 1
	local scale = (1 / canvasScale) * (WM.GetGlobalPinScale and WM:GetGlobalPinScale() or 1)
	local w, h = canvas:GetWidth(), canvas:GetHeight()
	local level = FrameLevel()
	local n = 0
	if map then
		ns.ForEach(function(owner, id, pin)
			local x, y = ns.PosOnMap(pin, map)
			if not x then return end
			n = n + 1
			local f = pool[n]
			if not f then
				f = ns.CreatePinFrame(canvas, PIN_SIZE)
				pool[n] = f
			end
			ns.SetPinFrame(f, owner, id, pin)
			f:SetScale(scale)
			f:SetFrameLevel(level)
			f:ClearAllPoints()
			f:SetPoint("CENTER", canvas, "TOPLEFT", w * x / scale, -h * y / scale)
			f:Show()
		end)
	end
	for i = n + 1, #pool do pool[i]:Hide() end
end

-- Shift-click: where the button went down (by the time it comes up, a click
-- on a continent may already have opened the zone under it).
local down

local function OnMouseDown(_, button)
	down = nil
	if button ~= "LeftButton" or not IsShiftKeyDown() then return end
	local map = WM:GetMapID()
	local x, y = WM:GetNormalizedCursorPosition()
	if map and x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1 then
		local cx, cy = GetCursorPosition()
		down = { map = map, x = x, y = y, cx = cx, cy = cy }
	end
end

local function OnMouseUp(_, button)
	local d = down
	down = nil
	if not d or button ~= "LeftButton" then return end
	local cx, cy = GetCursorPosition()
	if (cx - d.cx) ^ 2 + (cy - d.cy) ^ 2 > CLICK_SLOP * CLICK_SLOP then return end -- a drag
	if ns.Add(d.map, d.x, d.y) then
		if SOUNDKIT and SOUNDKIT.UI_MAP_WAYPOINT_CONTROL_CLICK then
			pcall(PlaySound, SOUNDKIT.UI_MAP_WAYPOINT_CONTROL_CLICK)
		end
	else
		ns.Print("pins can't go on this map - open a zone's map.")
	end
end

local function Setup()
	if WM or not WorldMapFrame or not WorldMapFrame.GetCanvas then return end
	WM = WorldMapFrame
	canvas = WM:GetCanvas()
	local refresh = function() Map.Refresh() end
	for _, method in ipairs({ "OnMapChanged", "OnCanvasScaleChanged", "OnCanvasSizeChanged" }) do
		if type(WM[method]) == "function" then hooksecurefunc(WM, method, refresh) end
	end
	WM:HookScript("OnShow", refresh)
	local sc = WM.ScrollContainer
	if sc then
		sc:HookScript("OnMouseDown", OnMouseDown)
		sc:HookScript("OnMouseUp", OnMouseUp)
	end
	Map.Refresh()
end

ns.OnChange(Map.Refresh)

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(_, event, name)
	if event == "PLAYER_LOGIN" or name == "Blizzard_WorldMap" then Setup() end
end)
