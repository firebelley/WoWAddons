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
local ATLAS_TRACKED = "Waypoint-MapPin-Tracked"
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
	GameTooltip:AddLine(ns.IsTracked(pin) and "Click to stop tracking" or "Click to track", 0.25, 1, 0.25)
	GameTooltip:AddLine(f.owner and "Shift-right-click to hide it" or "Shift-right-click to remove it (for your group too)",
		0.25, 1, 0.25)
	GameTooltip:Show()
end

-- Click a pin to track it (an arrow on the minimap), shift-right-click to
-- remove it. A pin takes clicks a little beyond its edge, so it's easy to
-- hit. A pin made mid-fight gets its clicks once the fight ends.
local HIT_PAD = 0.35 -- extra click area around a pin, as a share of its size
local clicksPending = {}
local function EnableClicks(f)
	if InCombatLockdown and InCombatLockdown() then
		clicksPending[f] = true
		return
	end
	f:EnableMouse(true)
end
local combatEnd = CreateFrame("Frame")
combatEnd:RegisterEvent("PLAYER_REGEN_ENABLED")
combatEnd:SetScript("OnEvent", function()
	for f in pairs(clicksPending) do
		clicksPending[f] = nil
		EnableClicks(f)
	end
end)

-- Hover and clicks for a frame standing for a pin (f.owner, f.id, f.pin):
-- the pins, and the minimap's arrow to the tracked one.
function ns.PinMouse(f)
	EnableClicks(f)
	f:SetScript("OnEnter", ShowTooltip)
	f:SetScript("OnLeave", function() GameTooltip:Hide() end)
	f:SetScript("OnMouseUp", function(self, button)
		if not self.id then return end
		if button == "RightButton" and IsShiftKeyDown() then
			GameTooltip:Hide()
			ns.Remove(self.owner, self.id)
		elseif button == "LeftButton" and self:IsMouseOver() then
			ns.Track(self.owner, self.id)
			if GameTooltip:IsOwned(self) then ShowTooltip(self) end
		end
	end)
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
	local pad = math.floor(size * HIT_PAD + 0.5)
	f:SetHitRectInsets(-pad, -pad, -pad, -pad)
	ns.PinMouse(f)
	return f
end

function ns.SetPinFrame(f, owner, id, pin)
	f.owner, f.id, f.pin = owner, id, pin
	local tracked = ns.IsTracked(pin)
	if tracked ~= f.tracked then
		f.tracked = tracked
		local atlas = tracked and ATLAS_TRACKED or ATLAS
		if HasAtlas(atlas) then f.icon:SetAtlas(atlas) end
		f.icon:SetDesaturated(true)
	end
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
	-- Guild dots: under the pins, sized like the game's group member dots (which
	-- don't follow the map's pin size).
	if ns.Guild then ns.Guild.DrawMap(canvas, map, 1 / canvasScale, math.max(0, level - 1)) end
	-- Your group's quest areas: under everything.
	if ns.Quests then ns.Quests.DrawMap(WM, canvas, map) end
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

---------------------------------------------------------------------------
-- The paste box (the map's top right corner): coordinates in any form drop
-- a pin there on the map being looked at - at once when pasted, or on Enter
-- when typed. It empties after each pin, ready for the next.
---------------------------------------------------------------------------

local BOX_WIDTH = 120

local function PlacePasted(box)
	local text = strtrim(box:GetText() or "")
	if text == "" then return box:ClearFocus() end
	local x, y = ns.Coords(text)
	if not (x and y) then
		ns.Print("type two numbers, like 45.2, 60.1.")
		return
	end
	local map = WM:GetMapID()
	if x > 100 or y > 100 or not map then
		ns.Print("can't place a pin there.")
		return
	end
	if ns.Add(map, x / 100, y / 100) then
		if SOUNDKIT and SOUNDKIT.UI_MAP_WAYPOINT_CONTROL_CLICK then
			pcall(PlaySound, SOUNDKIT.UI_MAP_WAYPOINT_CONTROL_CLICK)
		end
		box:SetText("")
		box:ClearFocus()
	else
		ns.Print("pins can't go on this map - open a zone's map.")
	end
end

local function CreatePasteBox()
	local container = WM.GetCanvasContainer and WM:GetCanvasContainer() or WM.ScrollContainer
	if not container then return end
	-- On the map's border frame: above the map and its pins.
	local box = CreateFrame("EditBox", nil, WM.BorderFrame or WM, "InputBoxTemplate")
	box:SetSize(BOX_WIDTH, 20)
	box:SetPoint("TOPRIGHT", container, "TOPRIGHT", -10, -6)
	box:SetAutoFocus(false)
	box:SetMaxLetters(60)
	local hint = box:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	hint:SetPoint("LEFT", 2, 0)
	hint:SetText("Paste coordinates")
	local function UpdateHint() hint:SetShown(box:GetText() == "" and not box:HasFocus()) end
	local before = 0 -- the text's length before the last change
	box:SetScript("OnTextChanged", function(self, userInput)
		local text = self:GetText() or ""
		local pasted = userInput and #text - before > 1 -- (more than one character at once)
		before = #text
		UpdateHint()
		if pasted and ns.Coords(text) then PlacePasted(self) end
	end)
	box:SetScript("OnEnterPressed", PlacePasted)
	box:SetScript("OnEscapePressed", function(self)
		self:SetText("")
		self:ClearFocus()
	end)
	box:SetScript("OnEditFocusGained", UpdateHint)
	box:SetScript("OnEditFocusLost", UpdateHint)
	box:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:SetText("Paste coordinates", 1, 1, 1)
		GameTooltip:AddLine("Drops a pin there on this map.", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	box:SetScript("OnLeave", function() GameTooltip:Hide() end)
	UpdateHint()
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
	-- A shift-right-click that misses a pin does nothing, rather than zoom out.
	if WM.AddCanvasClickHandler then
		WM:AddCanvasClickHandler(function(_, button)
			return button == "RightButton" and IsShiftKeyDown()
		end, 1000)
	end
	local sc = WM.ScrollContainer
	if sc then
		sc:HookScript("OnMouseDown", OnMouseDown)
		sc:HookScript("OnMouseUp", OnMouseUp)
	end
	local ok, err = pcall(CreatePasteBox)
	if not ok and ns.debug then ns.Print("paste box: " .. tostring(err)) end
	Map.Refresh()
end

ns.OnChange(Map.Refresh)

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(_, event, name)
	if event == "PLAYER_LOGIN" or name == "Blizzard_WorldMap" then Setup() end
end)
