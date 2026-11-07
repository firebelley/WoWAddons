-- FireThreat: the enemies you're fighting, sorted so the ones that aren't
-- attacking you are on top.
--
-- What this client allows (tested in-game):
--  * Enemies are found through nameplates (nameplate1..40).
--  * Threat *status* against a nameplate is readable (for you and your group);
--    threat *amounts* are hidden, but the game can still draw them as a bar.
--  * Nothing can target an enemy through its nameplate - not secure buttons,
--    not even "/target nameplate1" typed in chat - so the list can't be
--    clickable. Hovering an enemy in the list points an arrow at it instead.
local ADDON, ns = ...

local MAX_PLATES = 40
local ROW_W, ROW_H, ROW_GAP, TITLE_H = 220, 20, 2, 18
local UPDATE_RATE = 0.2

local HOLD_AFTER = 2 -- seconds the title stays up ("all clear") once the fight is over
local WARN_THROTTLE = 3

local DEFAULTS = {
	scale = 1, maxRows = 10,
	flash = true,          -- red pulse on rows of enemies not on you
	markNameplates = true, -- red arrow over those enemies' nameplates
	warnLost = true,       -- on-screen warning when an enemy leaves you for someone else
	warnSound = true,      -- ...with a sound
	onlyTanking = true,    -- show the list only once you've tanked something this fight
	showOthers = true,     -- list enemies fighting people outside your group
}
ns.DEFAULTS = DEFAULTS

local db
local frame, titleBar, preview, marker
local rows = {}
local plateMarks = {} -- pool of red arrows for nameplates
local unlocked = false
local hovered -- row under the mouse
local addedAt = {} -- [nameplate token] = when its nameplate appeared (keeps order steady)
local wasMine = {} -- [nameplate token] = true while that enemy is on you
local warnedAt = {}
local tankedThisFight = false
local lastActive = -100

function ns.Print(msg)
	print("|cffff7f3fFireThreat|r: " .. msg)
end

local function IsSecret(v)
	return issecretvalue ~= nil and issecretvalue(v)
end

local function Yes(v) -- a readable true
	return v and not IsSecret(v)
end

---------------------------------------------------------------------------
-- Threat
---------------------------------------------------------------------------

-- 3 = tanking it, 2 = tanking it but someone has more threat (about to pull
-- it), 1 = not tanking, more threat than whoever is, 0 = not tanking, nil =
-- not on its threat list.
local function Status(who, mob)
	local ok, s = pcall(UnitThreatSituation, who, mob)
	if ok and s ~= nil and not IsSecret(s) then return s end
end

-- Your group: the units whose threat is worth checking.
local function Group()
	local list = { "pet" }
	if IsInRaid() then
		for i = 1, 40 do
			list[#list + 1] = "raid" .. i
			list[#list + 1] = "raidpet" .. i
		end
	elseif IsInGroup() then
		for i = 1, 4 do
			list[#list + 1] = "party" .. i
			list[#list + 1] = "partypet" .. i
		end
	end
	return list
end

local function IsMe(unit)
	return Yes(UnitIsUnit(unit, "player"))
end

local function ShortName(unit)
	local name = UnitName(unit)
	if not name or IsSecret(name) then return "?" end
	return name
end

-- Sort ranks: smaller = higher in the list.
local RANK_LOOSE, RANK_SHAKY, RANK_MINE, RANK_OTHER = 1, 2, 3, 4

-- Which loose enemy to grab first, by who it's attacking. The class is the
-- only hint of who's healing on this client, but it's usually right.
local HEALER_CLASS = { PRIEST = true, DRUID = true, SHAMAN = true, PALADIN = true }
local CLOTH_CLASS = { MAGE = true, WARLOCK = true }
local function VictimPriority(unit)
	if not unit or not Yes(UnitIsPlayer(unit)) then return 4 end -- pets last
	local _, class = UnitClass(unit)
	if IsSecret(class) then return 3 end
	if HEALER_CLASS[class] then return 1 end
	if CLOTH_CLASS[class] then return 2 end
	return 3
end

-- Everything shown for one enemy.
local function Assess(unit, group)
	local e = { unit = unit, status = Status("player", unit) }
	if e.status and e.status >= 2 then
		e.rank = e.status == 3 and RANK_MINE or RANK_SHAKY
		if e.status == 2 then
			for _, who in ipairs(group) do
				if UnitExists(who) and not IsMe(who) and Status(who, unit) == 1 then
					e.puller = who
					break
				end
			end
		end
	else
		for _, who in ipairs(group) do
			if UnitExists(who) and not IsMe(who) then
				local s = Status(who, unit)
				if s and s >= 2 then
					e.holder = who
					break
				end
			end
		end
		-- Attacking someone in your group: that's the one to grab.
		e.rank = (e.holder or e.status) and RANK_LOOSE or RANK_OTHER
		e.priority = VictimPriority(e.holder)
	end
	return e
end

-- Every enemy in combat with a nameplate, most urgent first. Also returns
-- them all (the list may hide some, the nameplate arrows don't).
local function Enemies()
	local group, list = Group(), {}
	local now = GetTime()
	for i = 1, MAX_PLATES do
		local unit = "nameplate" .. i
		if UnitExists(unit) and Yes(UnitCanAttack("player", unit)) and not Yes(UnitIsDead(unit))
			and Yes(UnitAffectingCombat(unit)) then
			addedAt[unit] = addedAt[unit] or now
			local e = Assess(unit, group)
			if e.rank ~= RANK_OTHER or db.showOthers then list[#list + 1] = e end
		end
	end
	table.sort(list, function(a, b)
		if a.rank ~= b.rank then return a.rank < b.rank end
		if a.rank == RANK_LOOSE and a.priority ~= b.priority then return a.priority < b.priority end
		return (addedAt[a.unit] or 0) < (addedAt[b.unit] or 0)
	end)
	return list
end

-- An enemy that was on you just went to someone in your group.
local function WarnLost(e)
	local now = GetTime()
	if now - (warnedAt[e.unit] or -100) < WARN_THROTTLE then return end
	warnedAt[e.unit] = now
	local name = UnitName(e.unit)
	if not name or IsSecret(name) then name = "An enemy" end
	local msg = ("%s is on %s!"):format(name, ShortName(e.holder))
	local shown = RaidWarningFrame and RaidNotice_AddMessage and ChatTypeInfo and ChatTypeInfo.RAID_WARNING
		and pcall(RaidNotice_AddMessage, RaidWarningFrame, msg, ChatTypeInfo.RAID_WARNING)
	if not shown then UIErrorsFrame:AddMessage(msg, 1, 0.3, 0.3) end
	if db.warnSound then
		pcall(PlaySound, SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959, "Master")
	end
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------
local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
local COLOR = {
	[RANK_MINE] = { 0.15, 0.75, 0.2 },
	[RANK_SHAKY] = { 1, 0.75, 0 },
	[RANK_LOOSE] = { 0.9, 0.15, 0.1 },
	[RANK_OTHER] = { 0.4, 0.4, 0.4 },
}

local function SetFlash(b, on)
	if on then
		if not b.flash:IsShown() then
			b.flash:Show()
			b.pulse:Play()
		end
	elseif b.flash:IsShown() then
		b.pulse:Stop()
		b.flash:Hide()
	end
end

local function NewRow(i)
	local b = CreateFrame("Button", nil, frame)
	b:SetSize(ROW_W, ROW_H)
	b:SetPoint("TOPLEFT", 0, -(TITLE_H + 2 + (i - 1) * (ROW_H + ROW_GAP)))
	b:EnableMouse(true)

	local bg = b:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 0.6)

	local bar = CreateFrame("StatusBar", nil, b)
	bar:SetPoint("TOPLEFT", 1, -1)
	bar:SetPoint("BOTTOMRIGHT", -1, 3)
	bar:SetStatusBarTexture(BAR_TEXTURE)
	bar:SetMinMaxValues(0, 100)
	bar:SetAlpha(0.75)
	b.bar = bar

	local health = CreateFrame("StatusBar", nil, b)
	health:SetPoint("BOTTOMLEFT", 1, 1)
	health:SetPoint("BOTTOMRIGHT", -1, 1)
	health:SetHeight(2)
	health:SetStatusBarTexture(BAR_TEXTURE)
	health:SetStatusBarColor(0.2, 0.9, 0.2)
	b.health = health

	local over = CreateFrame("Frame", nil, b)
	over:SetAllPoints()
	over:SetFrameLevel(bar:GetFrameLevel() + 2)

	b.icon = over:CreateTexture(nil, "OVERLAY")
	b.icon:SetSize(14, 14)
	b.icon:SetPoint("LEFT", 3, 1)
	b.icon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
	b.icon:Hide()

	b.info = over:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	b.info:SetPoint("RIGHT", -4, 1)
	b.info:SetJustifyH("RIGHT")

	b.name = over:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	b.name:SetPoint("LEFT", 4, 1)
	b.name:SetPoint("RIGHT", b.info, "LEFT", -4, 0)
	b.name:SetJustifyH("LEFT")
	b.name:SetWordWrap(false)

	-- White outline on your current target; light highlight on hover.
	b.edges = {}
	for k, side in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" }, { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
		local t = over:CreateTexture(nil, "OVERLAY")
		t:SetColorTexture(1, 1, 1, 0.9)
		t:SetPoint(side[1], b, side[1])
		t:SetPoint(side[2], b, side[2])
		if k <= 2 then t:SetHeight(1) else t:SetWidth(1) end
		t:Hide()
		b.edges[k] = t
	end
	b.hl = over:CreateTexture(nil, "HIGHLIGHT")
	b.hl:SetAllPoints(b)
	b.hl:SetColorTexture(1, 1, 1, 0.12)

	-- Red pulse on enemies attacking someone else.
	b.flash = over:CreateTexture(nil, "ARTWORK")
	b.flash:SetAllPoints(b)
	b.flash:SetColorTexture(1, 0.1, 0.1, 0.35)
	b.flash:Hide()
	local ag = b.flash:CreateAnimationGroup()
	ag:SetLooping("BOUNCE")
	local a = ag:CreateAnimation("Alpha")
	a:SetFromAlpha(1)
	a:SetToAlpha(0.1)
	a:SetDuration(0.45)
	b.pulse = ag

	b:SetScript("OnEnter", function(self)
		hovered = self
		ns.UpdateMarker()
		if self.unit then
			GameTooltip_SetDefaultAnchor(GameTooltip, self)
			if pcall(GameTooltip.SetUnit, GameTooltip, self.unit) then GameTooltip:Show() end
		end
	end)
	b:SetScript("OnLeave", function(self)
		if hovered == self then hovered = nil end
		ns.UpdateMarker()
		GameTooltip:Hide()
	end)
	rows[i] = b
	return b
end

local function ShowRow(b, e)
	local unit = e.unit
	b.unit = unit
	if not pcall(b.name.SetText, b.name, UnitName(unit)) then b.name:SetText("Enemy") end
	pcall(b.health.SetMinMaxValues, b.health, 0, UnitHealthMax(unit))
	pcall(b.health.SetValue, b.health, UnitHealth(unit))

	local mark = GetRaidTargetIndex(unit)
	if mark and not IsSecret(mark) then
		SetRaidTargetIconTexture(b.icon, mark)
		b.icon:Show()
		b.name:SetPoint("LEFT", 20, 1)
	else
		b.icon:Hide()
		b.name:SetPoint("LEFT", 4, 1)
	end

	local isTarget = Yes(UnitIsUnit(unit, "target"))
	for _, edge in ipairs(b.edges) do edge:SetShown(isTarget) end

	local c = COLOR[e.rank]
	b.bar:SetStatusBarColor(c[1], c[2], c[3])
	local value = 100
	if e.rank == RANK_LOOSE or e.rank == RANK_OTHER then
		-- Your threat as a share of what pulling it takes: hidden from addons,
		-- but the game can still draw it.
		value = 0
		if e.status then
			local ok, _, _, pct = pcall(UnitDetailedThreatSituation, "player", unit)
			if ok and pct ~= nil then value = pct end
		end
	end
	if not pcall(b.bar.SetValue, b.bar, value) then b.bar:SetValue(0) end

	if e.rank == RANK_SHAKY then
		b.info:SetText(("|cffffcc00%s pulling|r"):format(e.puller and ShortName(e.puller) or "someone"))
	elseif e.holder then
		b.info:SetText("|cffff5555> " .. ShortName(e.holder) .. "|r")
	elseif e.rank == RANK_LOOSE then
		b.info:SetText("|cffff5555not on you|r")
	elseif e.rank == RANK_OTHER then
		b.info:SetText("|cffaaaaaanot your fight|r")
	else
		b.info:SetText("")
	end

	SetFlash(b, e.rank == RANK_LOOSE and db.flash)
	b:Show()
end

---------------------------------------------------------------------------
-- Arrows over nameplates: yellow (bouncing) for the enemy you're hovering in
-- the list, red for every enemy that isn't on you.
---------------------------------------------------------------------------
local function PlateFor(unit)
	local plate = unit and C_NamePlate and C_NamePlate.GetNamePlateForUnit
		and C_NamePlate.GetNamePlateForUnit(unit)
	if plate and not (plate.IsForbidden and plate:IsForbidden()) then return plate end
end

local function Attach(arrow, plate)
	arrow:ClearAllPoints()
	if plate and pcall(arrow.SetPoint, arrow, "BOTTOM", plate, "TOP", 0, 0) then
		arrow:Show()
		return true
	end
	arrow:Hide()
end

function ns.UpdateMarker()
	if not marker then return end
	Attach(marker, PlateFor(hovered and hovered:IsShown() and hovered.unit))
end

local function NewPlateMark()
	local m = CreateFrame("Frame", nil, UIParent)
	m:SetSize(24, 24)
	m:SetFrameStrata("HIGH")
	local t = m:CreateTexture(nil, "OVERLAY")
	t:SetAllPoints()
	t:SetTexture("Interface\\Buttons\\UI-MicroStream-Red")
	local ag = m:CreateAnimationGroup()
	ag:SetLooping("BOUNCE")
	local a = ag:CreateAnimation("Alpha")
	a:SetFromAlpha(1)
	a:SetToAlpha(0.35)
	a:SetDuration(0.45)
	m:SetScript("OnShow", function() ag:Play() end)
	m:SetScript("OnHide", function() ag:Stop() end)
	m:Hide()
	plateMarks[#plateMarks + 1] = m
	return m
end

local function UpdatePlateMarks(list, visible)
	local n = 0
	if db.markNameplates and visible then
		local hoveredUnit = hovered and hovered:IsShown() and hovered.unit
		for _, e in ipairs(list) do
			if e.rank == RANK_LOOSE and e.unit ~= hoveredUnit then
				local plate = PlateFor(e.unit)
				if plate then
					n = n + 1
					Attach(plateMarks[n] or NewPlateMark(), plate)
				end
			end
		end
	end
	for i = n + 1, #plateMarks do plateMarks[i]:Hide() end
end

---------------------------------------------------------------------------
-- Update
---------------------------------------------------------------------------

-- Remembers which enemies are on you, and warns when one goes to someone else.
local function TrackLost(list)
	local seen = {}
	for _, e in ipairs(list) do
		seen[e.unit] = true
		if e.rank == RANK_MINE or e.rank == RANK_SHAKY then
			wasMine[e.unit] = true
			if UnitAffectingCombat("player") then tankedThisFight = true end
		elseif wasMine[e.unit] and e.holder then
			-- (Without a holder yet - fleeing, mid-swap - keep waiting.)
			wasMine[e.unit] = nil
			if db.warnLost then WarnLost(e) end
		end
	end
	-- Dead or out of combat: forget it without a warning.
	for unit in pairs(wasMine) do
		if not seen[unit] then wasMine[unit] = nil end
	end
end

local function SetTitleShown(on)
	if on then
		titleBar.fade:Stop()
		titleBar:SetAlpha(1)
		titleBar:Show()
	elseif titleBar:IsShown() and not titleBar.fade:IsPlaying() then
		titleBar.fade:Play() -- hides it when done
	end
end

local function Update()
	if not frame then return end
	local list = Enemies()
	TrackLost(list)

	-- As DPS (never tanking anything) the list stays out of the way.
	local allowed = unlocked or not db.onlyTanking or tankedThisFight
	local shown = allowed and math.min(#list, db.maxRows) or 0
	local mine, loose = 0, 0
	for _, e in ipairs(list) do
		if e.rank == RANK_LOOSE then loose = loose + 1
		elseif e.rank ~= RANK_OTHER then mine = mine + 1 end
	end
	for i = 1, shown do
		ShowRow(rows[i] or NewRow(i), list[i])
	end
	for i = shown + 1, #rows do
		rows[i].unit = nil
		SetFlash(rows[i], false)
		rows[i]:Hide()
	end
	ns.UpdateMarker()
	UpdatePlateMarks(list, allowed)

	local now = GetTime()
	if shown > 0 then lastActive = now end
	if unlocked then
		titleBar.text:SetText("FireThreat - drag to move")
		SetTitleShown(true)
	elseif shown > 0 then
		local parts = { "Threat " }
		if mine > 0 then parts[#parts + 1] = ("|cff44dd44%d on you|r"):format(mine) end
		if loose > 0 then parts[#parts + 1] = ("|cffff4444%d loose|r"):format(loose) end
		titleBar.text:SetText(table.concat(parts, "  "))
		SetTitleShown(true)
	elseif now - lastActive < HOLD_AFTER then
		titleBar.text:SetText("Threat  |cff44dd44all clear|r")
	else
		SetTitleShown(false)
	end
end

function ns.Apply()
	if not frame then return end
	frame:SetScale(db.scale)
	preview:SetHeight(db.maxRows * (ROW_H + ROW_GAP))
	Update()
end

---------------------------------------------------------------------------
-- Moving
---------------------------------------------------------------------------
local function SavePosition()
	local point, _, relPoint, x, y = frame:GetPoint()
	db.pos = { point, relPoint, x, y }
end

local function ApplyPosition()
	frame:ClearAllPoints()
	local p = db.pos
	if p then
		frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
	else
		frame:SetPoint("LEFT", UIParent, "CENTER", 250, 0)
	end
end

function ns.ToggleMove()
	unlocked = not unlocked
	titleBar:EnableMouse(unlocked)
	preview:SetShown(unlocked)
	Update()
	return unlocked
end

function ns.ResetPosition()
	db.pos = nil
	ApplyPosition()
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------
local function Setup()
	frame = CreateFrame("Frame", "FireThreatFrame", UIParent)
	frame:SetSize(ROW_W, TITLE_H)
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	ApplyPosition()

	titleBar = CreateFrame("Frame", nil, frame)
	titleBar:SetPoint("TOPLEFT")
	titleBar:SetPoint("TOPRIGHT")
	titleBar:SetHeight(TITLE_H)
	local tbg = titleBar:CreateTexture(nil, "BACKGROUND")
	tbg:SetAllPoints()
	tbg:SetColorTexture(0, 0, 0, 0.6)
	titleBar.text = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	titleBar.text:SetPoint("LEFT", 4, 0)
	titleBar:EnableMouse(false)
	titleBar:Hide()
	-- Fades out a moment after the fight instead of vanishing.
	titleBar.fade = titleBar:CreateAnimationGroup()
	local fadeOut = titleBar.fade:CreateAnimation("Alpha")
	fadeOut:SetFromAlpha(1)
	fadeOut:SetToAlpha(0)
	fadeOut:SetDuration(0.6)
	titleBar.fade:SetScript("OnFinished", function() titleBar:Hide() end)
	titleBar:RegisterForDrag("LeftButton")
	titleBar:SetScript("OnDragStart", function() frame:StartMoving() end)
	titleBar:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		SavePosition()
	end)

	preview = CreateFrame("Frame", nil, frame)
	preview:SetPoint("TOPLEFT", 0, -(TITLE_H + 2))
	preview:SetPoint("RIGHT")
	local pbg = preview:CreateTexture(nil, "BACKGROUND")
	pbg:SetAllPoints()
	pbg:SetColorTexture(0.2, 0.5, 1, 0.25)
	preview:Hide()

	marker = CreateFrame("Frame", nil, UIParent)
	marker:SetSize(28, 28)
	marker:SetFrameStrata("HIGH")
	local arrow = marker:CreateTexture(nil, "OVERLAY")
	arrow:SetAllPoints()
	arrow:SetTexture("Interface\\Buttons\\UI-MicroStream-Yellow")
	local bob = marker:CreateAnimationGroup()
	bob:SetLooping("BOUNCE")
	local move = bob:CreateAnimation("Translation")
	move:SetOffset(0, 8)
	move:SetDuration(0.35)
	marker:SetScript("OnShow", function() bob:Play() end)
	marker:SetScript("OnHide", function() bob:Stop() end)
	marker:Hide()

	ns.Apply()
	local elapsed = 0
	frame:SetScript("OnUpdate", function(_, dt)
		elapsed = elapsed + dt
		if elapsed < UPDATE_RATE then return end
		elapsed = 0
		Update()
	end)

	if GetCVar("nameplateShowEnemies") == "0" then
		ns.Print("enemy nameplates are off, so no enemies will be listed. Press V (or turn them on in Options > Nameplates).")
	end
end

-- /fthreat debug: what FireThreat can see right now. Run it mid-fight.
local function Debug()
	local function yn(v)
		if IsSecret(v) then return "hidden" end
		return v and "yes" or "no"
	end
	ns.Print(("debug: in combat %s, enemy nameplates setting %s"):format(
		yn(UnitAffectingCombat("player")), tostring(GetCVar("nameplateShowEnemies"))))
	local any = false
	for i = 1, MAX_PLATES do
		local unit = "nameplate" .. i
		if UnitExists(unit) then
			any = true
			print(("  %s: attackable %s, dead %s, in combat %s, your threat status %s"):format(
				unit, yn(UnitCanAttack("player", unit)), yn(UnitIsDead(unit)), yn(UnitAffectingCombat(unit)),
				tostring(Status("player", unit))))
		end
	end
	if not any then print("  no enemy nameplates right now (are nameplates showing?)") end
end

---------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_TARGET_CHANGED")
events:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" and arg1 == ADDON then
		FireThreatDB = FireThreatDB or {}
		db = FireThreatDB
		db.hoverKeys = nil -- from the clickable version
		for k, v in pairs(DEFAULTS) do
			if db[k] == nil then db[k] = v end
		end
		ns.db = db
	elseif event == "PLAYER_LOGIN" then
		local ok, err = pcall(Setup)
		if not ok then ns.Print("|cffff4444setup failed:|r " .. tostring(err)) end
	elseif event == "NAME_PLATE_UNIT_REMOVED" then
		-- The token gets reused for another enemy later.
		addedAt[arg1] = nil
		wasMine[arg1] = nil
		warnedAt[arg1] = nil
	elseif event == "PLAYER_REGEN_DISABLED" then
		tankedThisFight = false -- a new fight: wait to see whether you tank it
	elseif event == "PLAYER_TARGET_CHANGED" then
		Update()
	end
end)

SLASH_FIRETHREAT1 = "/fthreat"
SLASH_FIRETHREAT2 = "/firethreat"
SlashCmdList.FIRETHREAT = function(input)
	local cmd = strtrim(input or ""):lower()
	if cmd == "move" then
		ns.Print(ns.ToggleMove() and "drag the title bar, then type /fthreat move again." or "position saved.")
	elseif cmd == "reset" then
		ns.ResetPosition()
	elseif cmd == "debug" then
		Debug()
	elseif cmd == "" or cmd == "options" or cmd == "config" then
		ns.OpenOptions()
	else
		ns.Print("/fthreat - options, /fthreat move - unlock/lock, /fthreat reset - default position")
	end
end
