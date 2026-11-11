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
-- Shared visuals for both kinds of button.
-- v: texture, count, quality, locked, isNew, isJunk, questKind, hasLoot, link
---------------------------------------------------------------------------
local function ApplyVisual(b, v)
	local texture = v.texture
	SetItemButtonTexture(b, texture)
	b.fbEmptyIcon:SetShown(not texture)
	SetItemButtonCount(b, v.count or 0)
	SetItemButtonDesaturated(b, v.locked or false)

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

	if b.JunkIcon then b.JunkIcon:SetShown(texture and v.isJunk or false) end
	b.fbLoot:SetShown(texture and v.hasLoot or false)
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
		isJunk = info and info.quality == 0 and not info.hasNoValue,
		questKind = IB.QuestKind(bag, slot, info),
		hasLoot = info and info.hasLoot,
		link = info and info.hyperlink,
		isBound = info and info.isBound or false,
	})
	b.hasItem = texture and 1 or nil
	b.readable = info and info.isReadable

	local cooldown = b.Cooldown or _G[b:GetName() .. "Cooldown"]
	if cooldown then
		if texture then
			local start, duration, enable = API.GetCooldown(bag, slot)
			CooldownFrame_Set(cooldown, start or 0, duration or 0, enable)
		else
			cooldown:Hide()
		end
	end

	RefreshTooltip(b)
end

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
		if ns.NewItems.IsNew(self.fbBag, self.fbSlot) then
			ns.NewItems.Clear(self.fbBag, self.fbSlot)
			SetGlow(self, false)
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
		isJunk = item and item.q == 0,
		questKind = item and item.k,
		hasLoot = item and item.o,
		link = item and item.l,
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

local function CachedOnClick(self)
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
