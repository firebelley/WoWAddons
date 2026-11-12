-- FireThreat: the enemies you're fighting, coloured by what you should do
-- about them. Red always means "act":
--  * Tanking: green = attacking you, yellow = someone's about to pull it,
--    red = attacking someone else (go get it).
--  * Otherwise (damage, healing): green = someone else has it, yellow = you're
--    about to pull it (ease off), red = attacking you.
-- The role is worked out from your stance/form/Righteous Fury (or the group
-- role, if one is set), or can be chosen in the options.
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
	role = "auto",         -- "auto" | "tank" | "dps" (damage or healing)
	flash = true,          -- red pulse on red rows
	markNameplates = true, -- red arrow over red enemies' nameplates
	warnLost = true,       -- tanking: warning when an enemy leaves you for someone else
	warnAggro = true,      -- otherwise: warning when you pull an enemy off someone
	warnSound = true,      -- ...with a sound
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
local onOther = {} -- [nameplate token] = true while that enemy is on someone in your group
local warnedAt = {}
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

---------------------------------------------------------------------------
-- Role
---------------------------------------------------------------------------
local RIGHTEOUS_FURY = 25780
local WARRIOR_DEFENSIVE, DRUID_BEAR, DRUID_DIRE_BEAR = 18, 5, 8 -- shapeshift form IDs

-- Auras can be hidden in combat, so a "no" only counts out of combat.
local hasFury = false
local function HasRighteousFury()
	local fn = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID
	if not fn then return false end
	local ok, aura = pcall(fn, RIGHTEOUS_FURY)
	if ok and aura and not IsSecret(aura) then
		hasFury = true
	elseif ok and not UnitAffectingCombat("player") then
		hasFury = false
	end
	return hasFury
end

local function FormID()
	local id = GetShapeshiftFormID and GetShapeshiftFormID()
	if id ~= nil and not IsSecret(id) then return id end
end

-- Whether you're tanking (true) or not, and how that was decided.
function ns.IsTank()
	if db.role == "tank" then return true, "chosen" end
	if db.role == "dps" then return false, "chosen" end
	local assigned = UnitGroupRolesAssigned and UnitGroupRolesAssigned("player")
	if assigned and not IsSecret(assigned) then
		if assigned == "TANK" then return true, "group role" end
		if assigned == "DAMAGER" or assigned == "HEALER" then return false, "group role" end
	end
	local _, class = UnitClass("player")
	if class == "WARRIOR" then
		local id = FormID()
		if id then return id == WARRIOR_DEFENSIVE, "stance" end
		return GetShapeshiftForm() == 2, "stance"
	elseif class == "DRUID" then
		local id = FormID()
		if id then return id == DRUID_BEAR or id == DRUID_DIRE_BEAR, "form" end
		return GetShapeshiftForm() == 1, "form"
	elseif class == "PALADIN" then
		return HasRighteousFury(), "Righteous Fury"
	end
	return false, "class"
end

-- Sort ranks: smaller = higher in the list.
-- Tanking: loose (on someone else), shaky (about to be pulled), mine, other.
local RANK_LOOSE, RANK_SHAKY, RANK_MINE, RANK_OTHER = 1, 2, 3, 4
-- Not tanking: on you, you're about to pull it, safe (someone else has it), other.
local RANK_ONME, RANK_CLOSE, RANK_SAFE = 1, 2, 3

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

-- Everything shown for one enemy. e.look is its colour: "good", "warn",
-- "bad" (act on it) or "other".
local function Assess(unit, group, tank)
	local s = Status("player", unit)
	local e = { unit = unit, status = s, mine = s ~= nil and s >= 2 }
	if s == 2 and tank then
		for _, who in ipairs(group) do
			if UnitExists(who) and not IsMe(who) and Status(who, unit) == 1 then
				e.puller = who
				break
			end
		end
	elseif not e.mine then
		for _, who in ipairs(group) do
			if UnitExists(who) and not IsMe(who) then
				local hs = Status(who, unit)
				if hs and hs >= 2 then
					e.holder = who
					break
				end
			end
		end
	end
	local inFight = e.holder or s
	if tank then
		if s == 3 then e.rank, e.look = RANK_MINE, "good"
		elseif s == 2 then e.rank, e.look = RANK_SHAKY, "warn"
		elseif inFight then
			-- Attacking someone in your group: that's the one to grab.
			e.rank, e.look = RANK_LOOSE, "bad"
			e.priority = VictimPriority(e.holder)
		else e.rank, e.look = RANK_OTHER, "other" end
	else
		if e.mine then e.rank, e.look = RANK_ONME, "bad"
		elseif s == 1 then e.rank, e.look = RANK_CLOSE, "warn" -- more threat than whoever it's on
		elseif inFight then e.rank, e.look = RANK_SAFE, "good"
		else e.rank, e.look = RANK_OTHER, "other" end
	end
	return e
end

-- Every enemy in combat with a nameplate, most urgent first.
local function Enemies(tank)
	local group, list = Group(), {}
	local now = GetTime()
	for i = 1, MAX_PLATES do
		local unit = "nameplate" .. i
		if UnitExists(unit) and Yes(UnitCanAttack("player", unit)) and not Yes(UnitIsDead(unit))
			and Yes(UnitAffectingCombat(unit)) then
			addedAt[unit] = addedAt[unit] or now
			local e = Assess(unit, group, tank)
			if e.rank ~= RANK_OTHER or db.showOthers then list[#list + 1] = e end
		end
	end
	table.sort(list, function(a, b)
		if a.rank ~= b.rank then return a.rank < b.rank end
		if a.priority and b.priority and a.priority ~= b.priority then return a.priority < b.priority end
		return (addedAt[a.unit] or 0) < (addedAt[b.unit] or 0)
	end)
	return list
end

-- A raid-warning style message about an enemy (throttled per enemy).
-- format gets the enemy's name, then the holder's.
local function Warn(e, format)
	local now = GetTime()
	if now - (warnedAt[e.unit] or -100) < WARN_THROTTLE then return end
	warnedAt[e.unit] = now
	local name = UnitName(e.unit)
	if not name or IsSecret(name) then name = "An enemy" end
	local msg = format:format(name, e.holder and ShortName(e.holder) or "someone")
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
	good = { 0.15, 0.75, 0.2 },
	warn = { 1, 0.75, 0 },
	bad = { 0.9, 0.15, 0.1 },
	other = { 0.4, 0.4, 0.4 },
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

	local c = COLOR[e.look]
	b.bar:SetStatusBarColor(c[1], c[2], c[3])
	-- Your threat as a share of what pulling it takes (full when it's on you):
	-- hidden from addons, but the game can still draw it.
	local value = e.mine and 100 or 0
	if e.status then
		local ok, _, _, pct = pcall(UnitDetailedThreatSituation, "player", unit)
		if ok and pct ~= nil then value = pct end
	end
	if not pcall(b.bar.SetValue, b.bar, value) then b.bar:SetValue(e.mine and 100 or 0) end

	local holder = e.holder and ShortName(e.holder)
	local text = ""
	if e.rank == RANK_OTHER then
		text = "|cffaaaaaanot your fight|r"
	elseif e.tank then
		if e.rank == RANK_SHAKY then
			text = ("|cffffcc00%s pulling|r"):format(e.puller and ShortName(e.puller) or "someone")
		elseif e.rank == RANK_LOOSE then
			text = holder and ("|cffff5555> " .. holder .. "|r") or "|cffff5555not on you|r"
		end
	else
		if e.rank == RANK_ONME then
			text = "|cffff5555on you!|r"
		elseif e.rank == RANK_CLOSE then
			text = holder and ("|cffffcc00pulling from " .. holder .. "|r") or "|cffffcc00pulling soon|r"
		elseif holder then
			text = "|cff88dd88> " .. holder .. "|r"
		end
	end
	b.info:SetText(text)

	SetFlash(b, e.look == "bad" and db.flash)
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
			if e.look == "bad" and e.unit ~= hoveredUnit then
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

-- Remembers who each enemy is on, and warns when one changes in a way that
-- matters: tanking, when one leaves you; otherwise, when you pull one.
local function TrackChanges(list, tank)
	local seen = {}
	for _, e in ipairs(list) do
		local unit = e.unit
		seen[unit] = true
		if e.mine then
			if onOther[unit] and not tank and db.warnAggro then Warn(e, "%s is attacking you!") end
			wasMine[unit], onOther[unit] = true, nil
		elseif e.holder then
			-- (Without a holder yet - fleeing, mid-swap - keep waiting.)
			if wasMine[unit] and tank and db.warnLost then Warn(e, "%s is on %s!") end
			wasMine[unit], onOther[unit] = nil, true
		end
	end
	-- Dead or out of combat: forget it without a warning.
	for unit in pairs(wasMine) do
		if not seen[unit] then wasMine[unit] = nil end
	end
	for unit in pairs(onOther) do
		if not seen[unit] then onOther[unit] = nil end
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
	local tank = ns.IsTank()
	local list = Enemies(tank)
	TrackChanges(list, tank)

	-- Not tanking and on your own, everything is on you anyway: nothing to show.
	local allowed = unlocked or tank or IsInGroup() or UnitExists("pet")
	local shown = allowed and math.min(#list, db.maxRows) or 0
	local counts = { good = 0, warn = 0, bad = 0, other = 0 }
	for _, e in ipairs(list) do
		counts[e.look] = counts[e.look] + 1
	end
	for i = 1, shown do
		list[i].tank = tank
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
		local parts = { tank and "Tanking " or "Threat " }
		if tank then
			local mine = counts.good + counts.warn
			if mine > 0 then parts[#parts + 1] = ("|cff44dd44%d on you|r"):format(mine) end
			if counts.bad > 0 then parts[#parts + 1] = ("|cffff4444%d loose|r"):format(counts.bad) end
		else
			if counts.bad > 0 then parts[#parts + 1] = ("|cffff4444%d on you|r"):format(counts.bad) end
			if counts.warn > 0 then parts[#parts + 1] = ("|cffffcc00%d close|r"):format(counts.warn) end
			if counts.bad + counts.warn == 0 then parts[#parts + 1] = "|cff44dd44safe|r" end
		end
		titleBar.text:SetText(table.concat(parts, "  "))
		SetTitleShown(true)
	elseif now - lastActive < HOLD_AFTER then
		titleBar.text:SetText((tank and "Tanking" or "Threat") .. "  |cff44dd44all clear|r")
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
		ns.Print("enemy nameplates are off - press V to turn them on.")
	end
end

-- /fthreat debug: what FireThreat can see right now. Run it mid-fight.
local function Debug()
	local function yn(v)
		if IsSecret(v) then return "hidden" end
		return v and "yes" or "no"
	end
	local tank, why = ns.IsTank()
	ns.Print(("debug: in combat %s, enemy nameplates setting %s, role %s (%s), form %s"):format(
		yn(UnitAffectingCombat("player")), tostring(GetCVar("nameplateShowEnemies")),
		tank and "tank" or "not tank", why, tostring(FormID())))
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
events:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" and arg1 == ADDON then
		FireThreatDB = FireThreatDB or {}
		db = FireThreatDB
		db.hoverKeys = nil -- from the clickable version
		db.onlyTanking = nil -- replaced by roles
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
		onOther[arg1] = nil
		warnedAt[arg1] = nil
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
