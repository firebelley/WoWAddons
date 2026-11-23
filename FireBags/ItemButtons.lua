-- Item slot buttons.
--   Live buttons:   Blizzard's container item button template, so clicking,
--                   dragging, splitting stacks and tooltips all work as normal.
--   Cached buttons: display-only, for the bank snapshot when you're away.
local _, ns = ...
local API = ns.API

local SLOT = ns.SLOT_SIZE
-- Empty slots look like Blizzard's combined bags: a blank slot with a faded,
-- grey bag icon on it (one bag icon for every slot, not each bag's own).
local EMPTY_SLOT_ATLAS = "bags-item-slot-blank"
local EMPTY_SLOT_TEXTURE = "Interface\\Buttons\\UI-EmptySlot-Disabled"
local EMPTY_ICON = "Interface\\Icons\\INV_Misc_Bag_08"
local EMPTY_ICON_SHADE = { 0.5, 0.5, 0.5, 0.45 } -- multiplied by the section's tint
local BORDER_TEXTURE = "Interface\\Common\\WhiteIconFrame"
local GLOW_ATLAS = "bags-glow-white"
local GLOW_FALLBACK = "Interface\\Buttons\\UI-ActionButton-Border"
local LOOT_ICON = "Interface\\Cursor\\Pickup" -- the loot hand cursor
local LOCK_ICON = "Interface\\AddOns\\FireBags\\Lock" -- Lock.tga
local JUNK_ICON = "Interface\\AddOns\\FireBags\\Junk" -- Junk.tga (not a coin: FireAuction marks valuable items with one)

-- Alt held, and neither Shift nor Ctrl.
local function AltOnly()
	return IsAltKeyDown() and not IsShiftKeyDown() and not IsControlKeyDown()
end

local IB = {}
ns.ItemButtons = IB

---------------------------------------------------------------------------
-- For other addons (FireAuction marks valuable items this way):
--   FireBags.AddButtonHook(function(button, link, isBound) ... end)
-- runs after every item button update; link is nil for an empty slot, and
-- isBound is nil when unknown (the bank snapshot).
--   FireBags.UpdateButtons() redraws every visible button.
---------------------------------------------------------------------------
local buttonHooks = {}
FireBags = FireBags or {}

function FireBags.AddButtonHook(fn)
	buttonHooks[#buttonHooks + 1] = fn
	FireBags.UpdateButtons()
end

function FireBags.UpdateButtons()
	IB.Invalidate() -- (something not read from the slot changed: redraw all)
	for _, w in ipairs(ns.windows or {}) do w:RequestButtonUpdate() end
end

---------------------------------------------------------------------------
-- Creation helpers
---------------------------------------------------------------------------
local function HasIcon(b)
	return b.icon or (b:GetName() and _G[b:GetName() .. "IconTexture"])
end

-- Tries each template in turn; modern clients define item button templates as
-- the "ItemButton" frame type, older ones as plain "Button".
local function CreateItemButton(name, parent, templates)
	for i, template in ipairs(templates) do
		if API.TemplateExists(template) ~= false then
			local frameName = i == 1 and name or (name .. "_" .. i)
			local ok, b = pcall(CreateFrame, "ItemButton", frameName, parent, template)
			if not ok or not b then
				ok, b = pcall(CreateFrame, "Button", frameName, parent, template)
			end
			if ok and b and HasIcon(b) then return b end
		end
	end
	error("FireBags: no usable item button template")
end

local function AddDecorations(b)
	b:SetSize(SLOT, SLOT)

	local bg = b:CreateTexture(nil, "BACKGROUND", nil, -1)
	bg:SetAllPoints()
	if API.AtlasExists(EMPTY_SLOT_ATLAS) then
		bg:SetAtlas(EMPTY_SLOT_ATLAS)
	else
		bg:SetTexture(EMPTY_SLOT_TEXTURE)
		bg:SetTexCoord(0.140625, 0.859375, 0.140625, 0.859375) -- the slot inside the 64px texture
	end

	-- Blizzard's template fills an empty slot's item icon with its own slot art
	-- (on Forever, the "wings" bags-item-slot64), drawn over ours. No art for
	-- empty slots means the icon just hides and FireBags' own look shows.
	b.GetItemButtonBackgroundTexture = function() return nil end
	b.emptyBackgroundAtlas, b.emptyBackgroundTexture = nil, nil

	local emptyIcon = b:CreateTexture(nil, "BACKGROUND", nil, 0)
	emptyIcon:SetPoint("TOPLEFT", 2, -2)
	emptyIcon:SetPoint("BOTTOMRIGHT", -2, 2)
	emptyIcon:SetTexture(EMPTY_ICON)
	emptyIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	emptyIcon:SetDesaturated(true)
	b.fbEmptyIcon = emptyIcon

	-- The window tints empty slots by section (special bags, keyring).
	function b:fbSetTint(r, g, bl)
		bg:SetVertexColor(r, g, bl)
		local s = EMPTY_ICON_SHADE
		emptyIcon:SetVertexColor(r * s[1], g * s[2], bl * s[3], s[4])
	end
	b.fbBackground = bg

	local border = b:CreateTexture(nil, "OVERLAY", nil, 1)
	border:SetAllPoints()
	border:SetTexture(BORDER_TEXTURE)
	border:Hide()
	b.fbBorder = border

	-- New item glow: a soft pulsing glow in the item's quality colour.
	local glow = b:CreateTexture(nil, "OVERLAY", nil, 2)
	if API.AtlasExists(GLOW_ATLAS) then
		glow:SetAtlas(GLOW_ATLAS)
		glow:SetAllPoints()
	else
		glow:SetTexture(GLOW_FALLBACK)
		glow:SetBlendMode("ADD")
		glow:SetPoint("CENTER")
		glow:SetSize(SLOT * 1.75, SLOT * 1.75)
	end
	glow:Hide()
	b.fbGlow = glow

	local anim = glow:CreateAnimationGroup()
	anim:SetLooping("BOUNCE")
	local fade = anim:CreateAnimation("Alpha")
	fade:SetFromAlpha(1)
	fade:SetToAlpha(0.3)
	fade:SetDuration(0.9)
	fade:SetSmoothing("IN_OUT")
	b.fbGlowAnim = anim

	-- Quest markers: "!" for items that start a quest, gold border for quest items.
	local quest = b:CreateTexture(nil, "OVERLAY", nil, 3)
	quest:SetAllPoints()
	quest:Hide()
	b.fbQuest = quest

	-- Openable items (clams, lockboxes...): a small loot hand in the top corner.
	local loot = b:CreateTexture(nil, "OVERLAY", nil, 4)
	loot:SetTexture(LOOT_ICON)
	loot:SetSize(15, 15)
	loot:SetPoint("TOPLEFT", 2, -2)
	loot:Hide()
	b.fbLoot = loot

	-- Locked in place (Marks.lua): a small padlock in the bottom corner.
	local lock = b:CreateTexture(nil, "OVERLAY", nil, 5)
	-- FireBags' own padlock: white with a black outline (shows on any item
	-- art), tinted bright blue.
	lock:SetTexture(LOCK_ICON)
	lock:SetVertexColor(0.35, 0.8, 1)
	lock:SetSize(17, 17)
	lock:SetPoint("BOTTOMLEFT", 0, 0)
	lock:Hide()
	b.fbLock = lock

	-- Junk (grey, or marked as junk): a red bin in the top corner, in place
	-- of Blizzard's coin.
	local junk = b:CreateTexture(nil, "OVERLAY", nil, 5)
	junk:SetTexture(JUNK_ICON)
	junk:SetVertexColor(1, 0.4, 0.3)
	junk:SetSize(16, 16)
	junk:SetPoint("TOPLEFT", 0, 0)
	junk:Hide()
	b.fbJunk = junk
	if b.JunkIcon then b.JunkIcon:SetAlpha(0) end

	-- Search: darkens items that don't match.
	local dim = b:CreateTexture(nil, "OVERLAY", nil, 7)
	dim:SetAllPoints()
	dim:SetColorTexture(0, 0, 0, 0.75)
	dim:Hide()
	b.fbDim = dim

	-- Hide template extras we drive ourselves.
	local templateQuest = b.IconQuestTexture or (b:GetName() and _G[b:GetName() .. "IconQuestTexture"])
	if templateQuest then templateQuest:SetAlpha(0) end
	if b.IconBorder then b.IconBorder:SetAlpha(0) end
	if b.NewItemTexture then b.NewItemTexture:SetAlpha(0) end
	if b.BattlepayItemTexture then b.BattlepayItemTexture:SetAlpha(0) end
end

local function SetGlow(b, on, quality)
	if on and ns.db.newItemGlow then
		local c = quality and quality >= 2 and ITEM_QUALITY_COLORS[quality]
		if c then
			b.fbGlow:SetVertexColor(c.r, c.g, c.b)
		else
			b.fbGlow:SetVertexColor(1, 0.85, 0.4)
		end
		b.fbGlow:Show()
		if not b.fbGlowAnim:IsPlaying() then b.fbGlowAnim:Play() end
	else
		b.fbGlowAnim:Stop()
		b.fbGlow:Hide()
	end
end

local QUEST_BANG = TEXTURE_ITEM_QUEST_BANG or "Interface\\ContainerFrame\\UI-Icon-QuestBang"
local QUEST_BORDER = TEXTURE_ITEM_QUEST_BORDER or "Interface\\ContainerFrame\\UI-Icon-QuestBorder"

-- "bang" (starts a quest you don't have), "border" (quest item) or nil.
function IB.QuestKind(bag, slot, info)
	if not info then return nil end
	local isQuestItem, questID, isActive = API.GetQuestInfo(bag, slot)
	if questID and not isActive then return "bang" end
	if questID or isQuestItem then return "border" end
	if isQuestItem == nil then
		-- No quest info from this client: fall back to the item's class.
		local classID = select(6, API.GetItemInfoInstant(info.itemID or info.hyperlink))
		if classID == 12 then return "border" end
	end
	return nil
end

---------------------------------------------------------------------------
-- Search
---------------------------------------------------------------------------
local searchText = nil -- lowercase, nil when not searching

-- Matches the item's name, type or subtype ("herb", "cloth", "potion"...).
local function MatchesSearch(link)
	if not searchText then return true end
	if not link then return false end
	local name, _, _, _, _, itemType, itemSubType = API.GetItemInfo(link)
	name = name or link:match("%[(.-)%]") or ""
	return name:lower():find(searchText, 1, true) ~= nil
		or (itemType and itemType:lower():find(searchText, 1, true) ~= nil)
		or (itemSubType and itemSubType:lower():find(searchText, 1, true) ~= nil)
end

function IB.SetSearch(text)
	text = text and strtrim(text):lower() or ""
	searchText = text ~= "" and text or nil
	for _, w in ipairs(ns.windows) do w:UpdateButtons() end
end

---------------------------------------------------------------------------
-- Can't use: the game writes what you don't meet (class, level, armor or
-- weapon type, profession...) in red on the item's tooltip. Read once per
-- item link; again when you level up or learn something.
---------------------------------------------------------------------------
local unusable = {} -- [link] = true / false
local unusablePending = false -- an item wasn't loaded yet (read it when it is)
local issecret = issecretvalue or function() return false end

local function IsRed(c)
	if type(c) ~= "table" then return false end
	local r, g, bl = c.r, c.g, c.b
	if issecret(r) or type(r) ~= "number" then return false end
	return r > 0.95 and g < 0.2 and bl < 0.2
end

local scanner
local function ScanLines(link) -- returns true/false, or nil if it can't tell yet
	local T = C_TooltipInfo
	if T and T.GetHyperlink then
		local ok, data = pcall(T.GetHyperlink, link)
		if not (ok and type(data) == "table" and type(data.lines) == "table" and #data.lines > 1) then return nil end
		for _, line in ipairs(data.lines) do
			if issecret(line.leftText) then return nil end
			if IsRed(line.leftColor) or IsRed(line.rightColor) then return true end
		end
		return false
	end
	-- (Older clients: a hidden tooltip of our own.)
	if not scanner then
		scanner = CreateFrame("GameTooltip", "FireBagsScanTooltip", nil, "GameTooltipTemplate")
	end
	scanner:SetOwner(WorldFrame, "ANCHOR_NONE")
	scanner:SetHyperlink(link)
	local n = scanner:NumLines()
	if n < 2 then return nil end
	for i = 1, n do
		for _, side in ipairs({ "Left", "Right" }) do
			local fs = _G["FireBagsScanTooltipText" .. side .. i]
			if fs and fs:IsShown() then
				local r, g, bl = fs:GetTextColor()
				if IsRed({ r = r, g = g, b = bl }) then return true end
			end
		end
	end
	return false
end

function IB.Unusable(link)
	if not link then return false end
	local known = unusable[link]
	if known ~= nil then return known end
	if not API.GetItemInfo(link) then
		unusablePending = true
		return false
	end
	local result = ScanLines(link)
	if result == nil then
		unusablePending = true
		return false
	end
	unusable[link] = result
	return result
end

-- Something you learned may make items usable: those are read again.
-- (A second after: the level and skills are up to date by then. Not in
-- combat, where weapon skills go up often and it'd redraw for nothing.)
local recheckPending = false
local function Recheck()
	recheckPending = false
	if InCombatLockdown() then recheckPending = true return end
	local any = false
	for link, v in pairs(unusable) do
		if v then unusable[link] = nil any = true end
	end
	if any then FireBags.UpdateButtons() end
end
local function RecheckSoon()
	if recheckPending then return end
	recheckPending = true
	C_Timer.After(1, Recheck)
end
for _, event in ipairs({
	"PLAYER_LEVEL_UP", "SKILL_LINES_CHANGED", "LEARNED_SPELL_IN_TAB", "NEW_RECIPE_LEARNED",
	"CHARACTER_POINTS_CHANGED",
}) do
	ns.On(event, RecheckSoon)
end
ns.On("PLAYER_REGEN_ENABLED", function() if recheckPending then C_Timer.After(1, Recheck) end end)

---------------------------------------------------------------------------
-- Shared visuals for both kinds of button.
-- v: texture, count, quality, locked, isNew, isJunk, questKind, hasLoot, link
---------------------------------------------------------------------------
-- A button is only redrawn when something it shows has changed (redrawing a
-- whole bag's worth takes long enough to hitch the game, and the bags are
-- redrawn on every change to them). What isn't in v: the search, the item's
-- lock mark, the glow option, and the rest (junk marks, other addons' hooks)
-- by a version number, bumped when any of those change.
local VISUAL_KEYS = { "texture", "count", "quality", "locked", "isNew", "isJunk", "questKind", "hasLoot", "link", "isBound", "unusable" }
local visualVersion = 0

function IB.Invalidate()
	visualVersion = visualVersion + 1
end

-- (Items loading can change whether they match the search, or show whether
-- they can be used.)
ns.On("GET_ITEM_INFO_RECEIVED", function()
	if searchText or unusablePending then
		unusablePending = false
		IB.Invalidate()
	end
end)

local function Unchanged(b, v, mark)
	local last = b.fbShown
	if not (last and last.version == visualVersion and last.search == searchText
		and last.mark == mark and last.glowOption == ns.db.newItemGlow) then
		return false
	end
	for _, k in ipairs(VISUAL_KEYS) do
		if last[k] ~= v[k] then return false end
	end
	return true
end

local function ApplyVisual(b, v)
	local mark = (b.fbBag and ns.Marks.IsLocked(b.fbBag, b.fbSlot)) or false
	if Unchanged(b, v, mark) then return end
	v.version, v.search, v.mark, v.glowOption = visualVersion, searchText, mark, ns.db.newItemGlow
	b.fbShown = v

	local texture = v.texture
	SetItemButtonTexture(b, texture)
	b.fbEmptyIcon:SetShown(not texture)
	SetItemButtonCount(b, v.count or 0)
	SetItemButtonDesaturated(b, v.locked or false)
	-- (Red like a vendor's items you can't use.)
	local icon = HasIcon(b)
	if texture and v.unusable then
		icon:SetVertexColor(0.9, 0.15, 0.15)
	else
		icon:SetVertexColor(1, 1, 1)
	end

	if texture and v.questKind then
		b.fbQuest:SetTexture(v.questKind == "bang" and QUEST_BANG or QUEST_BORDER)
		b.fbQuest:Show()
	else
		b.fbQuest:Hide()
	end

	local quality = v.quality
	if texture and not v.questKind and quality and quality >= 2 and ITEM_QUALITY_COLORS[quality] then
		local c = ITEM_QUALITY_COLORS[quality]
		b.fbBorder:SetVertexColor(c.r, c.g, c.b)
		b.fbBorder:Show()
	else
		b.fbBorder:Hide()
	end

	b.fbJunk:SetShown(texture and v.isJunk or false)
	b.fbLoot:SetShown(texture and v.hasLoot or false)
	b.fbLock:SetShown(texture and mark or false)
	b.fbDim:SetShown(texture and not MatchesSearch(v.link) or false)
	SetGlow(b, texture and v.isNew, quality)

	local link = texture and v.link or nil
	for _, fn in ipairs(buttonHooks) do
		ns.SafeCall(fn, b, link, v.isBound)
	end
end

local function RefreshTooltip(b)
	if GameTooltip:IsOwned(b) and b:GetScript("OnEnter") then
		b:GetScript("OnEnter")(b)
	end
end

---------------------------------------------------------------------------
-- Guarding locked items (Marks.lua): one can't be sold, deposited, mailed,
-- traded, posted or disenchanted. Blizzard's click handler is what would hand
-- it over (and replacing that would stop items being used), so:
--   - While a vendor, bank, mailbox, trade, auction house or guild bank is
--     open, its button takes no right-clicks (those hand it over). It can
--     still be picked up and moved round your bags; while it's on the cursor
--     those windows are covered by a catcher that puts it back.
--   - While a spell wants an item (Disenchant, Prospecting...), its button
--     takes no clicks or drags at all.
-- Alt-clicks still work, to unlock it.
---------------------------------------------------------------------------
local HANDOVER_FRAMES = {
	"MerchantFrame", "MailFrame", "TradeFrame", "AuctionHouseFrame", "AuctionFrame",
	"GuildBankFrame", "VoidStorageFrame",
}

local function Shown(name)
	local f = _G[name]
	return type(f) == "table" and f.IsShown and f:IsShown() and f or nil
end

-- "all", "right" (right-clicks only), or false.
function IB.Guarding()
	if SpellIsTargeting and SpellIsTargeting() then return "all" end
	if ns.Junk.atMerchant or ns.atBank then return "right" end
	for _, name in ipairs(HANDOVER_FRAMES) do
		if Shown(name) then return "right" end
	end
	return false
end

function IB.ApplyGuard(b, locked, guarding)
	local guard = locked and guarding or false
	if b.fbGuard == guard then return end
	b.fbGuard = guard
	if guard == "all" then
		b:RegisterForClicks() -- (none)
		b:RegisterForDrag()
	elseif guard == "right" then
		b:RegisterForClicks("LeftButtonUp")
		b:RegisterForDrag("LeftButton")
	else
		b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		b:RegisterForDrag("LeftButton")
	end
end

-- A locked item on the cursor: the windows it could be handed over to catch
-- it and put it back (dropped on the bank window too, if it's from your bags).
local picked -- { bag, slot } last picked up from a FireBags slot (older clients)
local function LockedOnCursor() -- the bag it's from, or nil
	if not CursorHasItem() then return nil end
	local loc = C_Cursor and C_Cursor.GetCursorItem and C_Cursor.GetCursorItem()
	local bag, slot
	if loc and loc.IsBagAndSlot and loc:IsBagAndSlot() then
		bag, slot = loc:GetBagAndSlot()
	elseif picked then
		bag, slot = picked[1], picked[2]
	end
	if bag and ns.Marks.IsLocked(bag, slot) then return bag end
end

local catchers = {} -- [frame] = catcher
local function Refuse()
	ClearCursor() -- (back to its slot)
	UIErrorsFrame:AddMessage("Locked. Alt-click to unlock.", 1, 0.1, 0.1)
end
local function Catcher(target)
	local c = catchers[target]
	if not c then
		c = CreateFrame("Frame", nil, target)
		c:SetAllPoints(target)
		c:EnableMouse(true)
		c:SetScript("OnMouseUp", Refuse)
		c:SetScript("OnReceiveDrag", Refuse)
		catchers[target] = c
	end
	-- Over everything in that window (but not windows above it, like ours).
	c:SetFrameLevel(math.min(target:GetFrameLevel() + 300, 9000))
	return c
end

local function UpdateCatchers()
	local from = IB.Guarding() and LockedOnCursor()
	for _, c in pairs(catchers) do c:Hide() end
	if not from then return end
	for _, name in ipairs(HANDOVER_FRAMES) do
		local f = Shown(name)
		if f then Catcher(f):Show() end
	end
	if ns.atBank and ns.bank and ns.bank:IsShown() and ns.IsInventoryBag(from) then
		Catcher(ns.bank):Show()
	end
end
ns.On("CURSOR_CHANGED", function()
	if not CursorHasItem() then picked = nil end
	UpdateCatchers()
end)

-- When one of those opens or closes, or a spell starts or stops wanting an item.
local wasGuarding = false
local function UpdateGuards()
	local now = IB.Guarding()
	if now == wasGuarding then return end
	wasGuarding = now
	for _, w in ipairs(ns.windows or {}) do
		for _, b in pairs(w.fbLive or {}) do
			IB.ApplyGuard(b, b.hasItem and ns.Marks.IsLocked(b.fbBag, b.fbSlot), now)
		end
	end
	UpdateCatchers()
end
local function UpdateGuardsSoon() C_Timer.After(0.1, UpdateGuards) end -- (once frames have shown/hidden)
for _, event in ipairs({
	"PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE",
	"MERCHANT_SHOW", "MERCHANT_CLOSED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED",
	"MAIL_SHOW", "MAIL_CLOSED", "TRADE_SHOW", "TRADE_CLOSED",
	"AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "GUILDBANKFRAME_OPENED", "GUILDBANKFRAME_CLOSED",
}) do
	ns.On(event, UpdateGuardsSoon)
end

---------------------------------------------------------------------------
-- Live buttons
---------------------------------------------------------------------------
local function UpdateLive(b)
	local bag, slot = b.fbBag, b.fbSlot
	local info = API.GetSlotInfo(bag, slot)
	local texture = info and info.iconFileID

	ApplyVisual(b, {
		texture = texture,
		count = info and info.stackCount,
		quality = info and info.quality,
		locked = info and info.isLocked,
		isNew = ns.NewItems.IsNew(bag, slot),
		isJunk = info and (info.quality == 0 or ns.Marks.IsForSale(info.itemID, bag, slot)) and not info.hasNoValue,
		questKind = IB.QuestKind(bag, slot, info),
		hasLoot = info and info.hasLoot,
		link = info and info.hyperlink,
		isBound = info and info.isBound or false,
		unusable = texture and ns.db.redUnusable and IB.Unusable(info.hyperlink) or false,
	})
	b.hasItem = texture and 1 or nil
	b.readable = info and info.isReadable

	IB.ApplyGuard(b, texture and ns.Marks.IsLocked(bag, slot), IB.Guarding())

	if b.fbCooldown == nil then b.fbCooldown = b.Cooldown or _G[b:GetName() .. "Cooldown"] or false end
	local cooldown = b.fbCooldown
	if cooldown then
		-- (Only when it changed, like the rest.)
		local start, duration, enable
		if texture then start, duration, enable = API.GetCooldown(bag, slot) end
		start, duration = start or 0, duration or 0
		if start ~= b.fbCdStart or duration ~= b.fbCdDuration or enable ~= b.fbCdEnable then
			b.fbCdStart, b.fbCdDuration, b.fbCdEnable = start, duration, enable
			if texture then
				CooldownFrame_Set(cooldown, start, duration, enable)
			else
				cooldown:Hide()
			end
		end
	end

	RefreshTooltip(b)
end

-- A spell waiting for an item (Disenchant...): the cursor shows whether it
-- can go on the one hovered only once its look is refreshed, which the game
-- leaves until the cursor crosses the world (so not when the spell came from
-- a button by the window, or started over a slot). Refreshed here.
local function RefreshTargetCursor(b) -- b: the slot hovered (else the one under the cursor)
	if not (SpellIsTargeting and SpellIsTargeting()) then return end
	if not b then
		local foci = GetMouseFoci and GetMouseFoci()
		b = foci and foci[1] or (GetMouseFocus and GetMouseFocus())
	end
	if b and b.fbUpdate == UpdateLive then ResetCursor() end
end

ns.On("CURRENT_SPELL_CAST_CHANGED", function()
	C_Timer.After(0, RefreshTargetCursor)
	UpdateGuards()
end)

-- Blizzard's template works out which bag a button belongs to from its
-- parent's ID, so each bag gets an invisible holder frame per window.
local function GetHolder(window, bag)
	window.fbHolders = window.fbHolders or {}
	local holder = window.fbHolders[bag]
	if not holder then
		holder = CreateFrame("Frame", nil, window)
		holder:SetID(bag)
		holder:SetAllPoints(window)
		window.fbHolders[bag] = holder
	end
	return holder
end

function IB.AcquireLive(window, bag, slot)
	window.fbLive = window.fbLive or {}
	local key = bag .. ":" .. slot
	local b = window.fbLive[key]
	if b then return b end

	local templates = { "ContainerFrameItemButtonTemplate" }
	if bag == ns.BANK_CONTAINER then
		-- The main bank slots use their own template on most clients.
		table.insert(templates, 1, "BankItemButtonGenericTemplate")
	end

	local name = ("%sItem%d_%d"):format(window:GetName(), bag + 100, slot)
	b = CreateItemButton(name, GetHolder(window, bag), templates)
	b:SetID(slot)
	-- Don't call b:SetBagID(): from addon code it stores a tainted bag number,
	-- and Blizzard's click handler passes that to UseContainerItem, which then
	-- gets blocked (e.g. learning a recipe). Without it the button reads the
	-- bag from its holder's ID, which stays clean.
	b.fbBag, b.fbSlot = bag, slot
	b.fbUpdate = UpdateLive
	AddDecorations(b)

	-- Hovering a new item marks it as seen.
	b:HookScript("OnEnter", function(self)
		RefreshTargetCursor(self)
		if ns.NewItems.IsNew(self.fbBag, self.fbSlot) then
			ns.NewItems.Clear(self.fbBag, self.fbSlot)
			SetGlow(self, false)
		end
	end)

	-- Alt-click: left locks the item in place, right marks it as junk
	-- (Marks.lua). The game does nothing else with an Alt-click on a bag item.
	local function AltClick(self, button)
		if button == "LeftButton" then
			ns.Marks.ToggleLock(self.fbBag, self.fbSlot)
		elseif button == "RightButton" then
			local info = API.GetSlotInfo(self.fbBag, self.fbSlot)
			if info then ns.Marks.ToggleSell(info.itemID, info.hyperlink, self.fbBag, self.fbSlot) end
		end
	end
	b:HookScript("OnClick", function(self, button)
		if CursorHasItem() then
			picked = { self.fbBag, self.fbSlot }
			UpdateCatchers()
		elseif AltOnly() then
			AltClick(self, button)
		end
	end)
	b:HookScript("OnDragStart", function(self)
		if CursorHasItem() then
			picked = { self.fbBag, self.fbSlot }
			UpdateCatchers()
		end
	end)

	-- Clicks a guarded button doesn't take (above) come here.
	b:HookScript("OnMouseUp", function(self, button)
		if not self.fbGuard or CursorHasItem() then return end
		if self.fbGuard == "right" and button ~= "RightButton" then return end
		if AltOnly() then
			AltClick(self, button)
		else
			UIErrorsFrame:AddMessage("Locked. Alt-click to unlock.", 1, 0.1, 0.1)
		end
	end)

	window.fbLive[key] = b
	return b
end

---------------------------------------------------------------------------
-- Cached (snapshot) buttons
---------------------------------------------------------------------------
local function UpdateCached(b)
	local item = b.fbItem
	ApplyVisual(b, {
		texture = item and item.i,
		count = item and item.c,
		quality = item and item.q,
		isJunk = item and (item.q == 0 or ns.Marks.IsForSale(tonumber(item.l and item.l:match("item:(%d+)")), b.fbBag, b.fbSlot, true)),
		questKind = item and item.k,
		hasLoot = item and item.o,
		link = item and item.l,
		unusable = item and ns.db.redUnusable and IB.Unusable(item.l) or false,
	})
	local cooldown = b.Cooldown or _G[b:GetName() .. "Cooldown"]
	if cooldown then cooldown:Hide() end
	RefreshTooltip(b)
end

local function CachedOnEnter(self)
	local item = self.fbItem
	if not item then return end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetHyperlink(item.l)
	GameTooltip:Show()
end

local function CachedOnClick(self, button)
	-- Alt-right-click marks it as junk, as in your bags.
	if self.fbItem and button == "RightButton" and AltOnly() then
		local link = self.fbItem.l
		ns.Marks.ToggleSell(tonumber(link and link:match("item:(%d+)")), link)
		return
	end
	-- Shift-click to link in chat, ctrl-click to preview, like normal items.
	if self.fbItem and HandleModifiedItemClick then
		HandleModifiedItemClick(self.fbItem.l)
	end
end

function IB.AcquireCached(window, bag, slot)
	window.fbCached = window.fbCached or {}
	local key = bag .. ":" .. slot
	local b = window.fbCached[key]
	if b then return b end

	-- Same button type as live slots (so they look identical), with every
	-- script that would touch the real bag replaced or removed.
	local name = ("%sCached%d_%d"):format(window:GetName(), bag + 100, slot)
	b = CreateItemButton(name, window, { "ContainerFrameItemButtonTemplate", "ItemButtonTemplate" })
	b:UnregisterAllEvents()
	for _, script in ipairs({ "OnEvent", "OnShow", "OnHide", "OnUpdate", "OnDragStart", "OnReceiveDrag", "PreClick", "PostClick" }) do
		if b:HasScript(script) then b:SetScript(script, nil) end
	end
	b.fbBag, b.fbSlot = bag, slot
	b.fbUpdate = UpdateCached
	b.UpdateTooltip = CachedOnEnter
	AddDecorations(b)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:SetScript("OnEnter", CachedOnEnter)
	b:SetScript("OnLeave", GameTooltip_Hide)
	b:SetScript("OnClick", CachedOnClick)

	window.fbCached[key] = b
	return b
end
