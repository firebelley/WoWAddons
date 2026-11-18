-- Your guild on the map: guild members with FireWaypoints show as dots in
-- their class color on the world map and the minimap, and see you. Not group
-- members (the game shows those itself). One switch in the options turns it
-- off both ways.
--
-- Everyone sends where they are to the guild (addon messages): every second
-- while moving with a guild member in the same zone (whose minimap shows
-- you), every few seconds otherwise, now and then while standing still.
-- (Messages go to the whole guild, so it's how often you send that changes,
-- not who to.) A dot goes when
-- its player hasn't been heard from for a while (logged off, or in an
-- instance, where the game hides your position) or says they've stopped.
local _, ns = ...

local Guild = {}
ns.Guild = Guild

local PREFIX = "FireWPG"
local CHECK = 1        -- seconds between looks at where you are
local NEAR = 1         -- seconds between sends while moving, a guild member in your zone
local FAR = 3          -- ...and with none
local HEARTBEAT = 15   -- seconds between sends while standing still
local STALE = 40       -- seconds without word before a dot goes
local MOVED = 0.0005   -- share of the map to move before sending again (a few yards)
local MAP_SIZE = 11 -- as the game's group member dots
local MINIMAP_SIZE = 10
local ATLAS = "WhiteCircle-RaidBlips"
local FALLBACK = "Interface\\COMMON\\Indicator-Gray"

local members = {} -- [name] = { map, x, y, class, level, t }
local last         -- what you last sent: { map, x, y, t }, or nil (nothing, or that you'd stopped)

function Guild.On() return ns.db ~= nil and ns.db.guild ~= false end
function Guild.Scale() return ns.db and ns.db.guildScale or 1 end

local function Redraw()
	if ns.Map and ns.Map.Refresh then ns.Map.Refresh() end
end

---------------------------------------------------------------------------
-- Sending where you are
---------------------------------------------------------------------------

local function Send(text)
	if not (IsInGuild and IsInGuild()) then return end
	local send = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
	if send then pcall(send, PREFIX, text, "GUILD") end
end

local function Stop()
	if last then
		Send("X")
		last = nil
	end
end

-- Is a guild member (not in your group: the game shows you to those) in this zone?
local function SameZone(map)
	for name, m in pairs(members) do
		if m.map == map and not ns.InGroup(name) then return true end
	end
	return false
end

local function Tick()
	if not (ns.db and IsInGuild and IsInGuild()) then return end
	if not Guild.On() then return Stop() end
	local map, x, y = ns.PlayerPos()
	if not map then return Stop() end -- an instance: the game hides where you are
	local now = GetTime()
	if last and last.map == map then
		local still = math.abs(last.x - x) < MOVED and math.abs(last.y - y) < MOVED
		if now - last.t < (still and HEARTBEAT or SameZone(map) and NEAR or FAR) then return end
	end
	local _, class = UnitClass("player")
	Send(("P\t%d,%d,%d,%s,%d"):format(map, math.floor(x * 10000 + 0.5), math.floor(y * 10000 + 0.5),
		class or "", UnitLevel("player") or 0))
	last = { map = map, x = x, y = y, t = now }
end

---------------------------------------------------------------------------
-- Hearing where they are
---------------------------------------------------------------------------

local function Expire()
	local now, gone = GetTime(), false
	for name, m in pairs(members) do
		if now - m.t > STALE then
			members[name] = nil
			gone = true
		end
	end
	if gone then Redraw() end
end

local function OnMessage(prefix, text, channel, sender)
	if prefix ~= PREFIX or channel ~= "GUILD" then return end
	if ns.IsSecret(text) or ns.IsSecret(sender) then return end
	local from = ns.SenderKey(sender)
	if not from then return end
	local kind, rest = strsplit("\t", text)
	if kind == "X" then
		if members[from] then
			members[from] = nil
			Redraw()
		end
		return
	end
	if kind ~= "P" or not Guild.On() then return end
	local map, x, y, class, level = (rest or ""):match("^(%d+),(%d+),(%d+),(%u*),(%d+)$")
	map, x, y, level = tonumber(map), tonumber(x), tonumber(y), tonumber(level)
	if not (map and x and y) or x > 10000 or y > 10000 then return end
	members[from] = { map = map, x = x / 10000, y = y / 10000, class = class ~= "" and class or nil,
		level = level, t = GetTime() }
	Redraw()
end

-- Guild members to show: fn(name, member). Not group members.
function Guild.ForEach(fn)
	if not Guild.On() then return end
	for name, m in pairs(members) do
		if not ns.InGroup(name) then fn(name, m) end
	end
end

-- The switch in the options: off stops sending and hides the dots.
function Guild.Changed()
	if not Guild.On() then
		wipe(members)
		Stop()
	else
		Tick()
	end
	Redraw()
end

---------------------------------------------------------------------------
-- Dots (the map and minimap draw them)
---------------------------------------------------------------------------

local function Color(m)
	local c = m.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[m.class]
	if c then return c.r, c.g, c.b end
	return 0.25, 1, 0.25
end

local function ShowTooltip(f)
	local m = f.member
	if not m then return end
	GameTooltip:SetOwner(f, "ANCHOR_RIGHT")
	GameTooltip:SetText(f.name, Color(m))
	local where = ns.MapName(m.map)
	GameTooltip:AddLine((m.level and m.level > 0) and ("Level %d, %s"):format(m.level, where) or where, 1, 1, 1)
	local d = ns.Distance(m)
	if d then GameTooltip:AddLine(("%d yards away"):format(d), 0.7, 0.7, 0.7) end
	GameTooltip:Show()
end

-- Hover only: clicks go through to the map. Made mid-fight: once it ends.
local pending = {}
local function Hover(f)
	if InCombatLockdown and InCombatLockdown() then
		pending[f] = true
		return
	end
	if f.SetMouseClickEnabled and f.SetMouseMotionEnabled then
		f:SetMouseMotionEnabled(true)
		f:SetMouseClickEnabled(false)
	else
		f:EnableMouse(true)
	end
end

local function HasAtlas(name)
	return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

local function CreateDot(parent, size)
	local f = CreateFrame("Frame", nil, parent)
	f:SetSize(size, size)
	f.icon = f:CreateTexture(nil, "ARTWORK")
	f.icon:SetAllPoints()
	if HasAtlas(ATLAS) then f.icon:SetAtlas(ATLAS) else f.icon:SetTexture(FALLBACK) end
	f:SetScript("OnEnter", ShowTooltip)
	f:SetScript("OnLeave", function() GameTooltip:Hide() end)
	Hover(f)
	return f
end

local function SetDot(f, name, m)
	f.name, f.member = name, m
	f.icon:SetVertexColor(Color(m))
	if GameTooltip:IsOwned(f) then ShowTooltip(f) end
end

local mapPool, minimapPool = {}, {}

-- On the world map's canvas (scale and level as its pins have them).
function Guild.DrawMap(canvas, map, scale, level)
	local w, h = canvas:GetWidth(), canvas:GetHeight()
	local size = MAP_SIZE * Guild.Scale()
	local n = 0
	if map then
		Guild.ForEach(function(name, m)
			local x, y = ns.PosOnMap(m, map)
			if not x then return end
			n = n + 1
			local f = mapPool[n]
			if not f then
				f = CreateDot(canvas, MAP_SIZE)
				mapPool[n] = f
			end
			SetDot(f, name, m)
			f:SetSize(size, size)
			f:SetScale(scale)
			f:SetFrameLevel(level)
			f:ClearAllPoints()
			f:SetPoint("CENTER", canvas, "TOPLEFT", w * x / scale, -h * y / scale)
			f:Show()
		end)
	end
	for i = n + 1, #mapPool do mapPool[i]:Hide() end
end

-- On the minimap: only those on it (no edge dots). map nil: hide them all.
-- cos, sin: the minimap's turn; perYard, half: its scale and radius.
function Guild.DrawMinimap(holder, map, px, py, perYard, cos, sin, half)
	local n = 0
	if map then
		local size = MINIMAP_SIZE * Guild.Scale()
		local edge = half - size / 2
		Guild.ForEach(function(name, m)
			local dx, dy = ns.Offset(m, map, px, py)
			if not dx then return end
			local east, north = dx, -dy
			east, north = east * cos + north * sin, -east * sin + north * cos
			local x, y = east * perYard, north * perYard
			if x * x + y * y > edge * edge then return end
			n = n + 1
			local f = minimapPool[n]
			if not f then
				f = CreateDot(holder, MINIMAP_SIZE)
				minimapPool[n] = f
			end
			SetDot(f, name, m)
			f:SetSize(size, size)
			f:SetFrameLevel(holder:GetFrameLevel()) -- under the pins
			f:ClearAllPoints()
			f:SetPoint("CENTER", Minimap, "CENTER", x, y)
			f:Show()
		end)
	end
	for i = n + 1, #minimapPool do minimapPool[i]:Hide() end
end

function Guild.Count()
	local n = 0
	Guild.ForEach(function() n = n + 1 end)
	return n
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("CHAT_MSG_ADDON")
events:SetScript("OnEvent", function(_, event, ...)
	if event == "CHAT_MSG_ADDON" then
		OnMessage(...)
	elseif event == "PLAYER_LOGIN" then
		local register = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
		if register then pcall(register, PREFIX) end
		C_Timer.NewTicker(CHECK, function()
			local ok, err = pcall(Tick)
			if not ok and ns.debug then ns.Print("guild: " .. tostring(err)) end
			Expire()
		end)
	elseif event == "PLAYER_ENTERING_WORLD" then
		C_Timer.After(1, Tick) -- in or out of an instance: say so soon
	elseif event == "PLAYER_REGEN_ENABLED" then
		for f in pairs(pending) do
			pending[f] = nil
			Hover(f)
		end
	end
end)
