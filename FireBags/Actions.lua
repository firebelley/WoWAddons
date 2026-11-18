-- Buttons down the bag window's side, under its tabs, for spells you use on
-- items (Disenchant, Prospecting...) or anything else: drag a spell, item or
-- macro onto one. While something's on the cursor an empty one shows at the
-- end. Drag one off to remove it (with the pick-up modifier when action bars
-- are locked). Each character has their own.
--
-- Casting takes secure buttons, and a window holding secure buttons can't be
-- opened or closed in combat. So they leave the window when combat starts
-- (just before the lockdown) and come back when it ends.
local _, ns = ...
local API = ns.API

local MAX = 8
local GAP = 8 -- between the tabs and the buttons
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"

local window = ns.inventory
local away = CreateFrame("Frame")
away:Hide()

local list     -- this character's: { kind = "spell"|"item"|"macro", id = n, name = s }
local holder
local buttons = {}
local cursorHas -- something that can go on a button is on the cursor
local pending   -- a change waiting for combat to end

local function Locked() return InCombatLockdown() end

local function Fn(t, name, global)
	return (t and t[name]) or _G[global or name]
end

---------------------------------------------------------------------------
-- What's on the cursor, as an entry
---------------------------------------------------------------------------
local function CursorEntry()
	local kind, a, _, c = GetCursorInfo()
	if kind == "spell" then
		local id = tonumber(c) or tonumber(a)
		if id then return { kind = "spell", id = id } end
	elseif kind == "item" then
		if tonumber(a) then return { kind = "item", id = tonumber(a) } end
	elseif kind == "macro" then
		local name = a and GetMacroInfo(a)
		if name then return { kind = "macro", name = name } end
	end
end

local function Pickup(entry)
	if entry.kind == "spell" then
		local fn = Fn(C_Spell, "PickupSpell")
		if fn then fn(entry.id) end
	elseif entry.kind == "item" then
		local fn = Fn(C_Item, "PickupItem")
		if fn then fn(entry.id) end
	elseif entry.kind == "macro" then
		PickupMacro(entry.name)
	end
end

local function BarsLocked()
	if Settings and Settings.GetValue then
		local ok, locked = pcall(Settings.GetValue, "lockActionBars")
		if ok and locked ~= nil then return locked end
	end
	return GetCVarBool("lockActionBars")
end

---------------------------------------------------------------------------
-- Showing one
---------------------------------------------------------------------------
local function Icon(entry)
	if entry.kind == "spell" then
		local fn = Fn(C_Spell, "GetSpellTexture")
		return fn and fn(entry.id)
	elseif entry.kind == "item" then
		return select(5, API.GetItemInfoInstant(entry.id))
	elseif entry.kind == "macro" then
		return select(2, GetMacroInfo(entry.name))
	end
end

local function Cooldown(entry)
	if entry.kind == "spell" then
		if C_Spell and C_Spell.GetSpellCooldown then
			local info = C_Spell.GetSpellCooldown(entry.id)
			if info then return info.startTime, info.duration, info.isEnabled, info.modRate end
		elseif GetSpellCooldown then
			return GetSpellCooldown(entry.id)
		end
	elseif entry.kind == "item" then
		local fn = Fn(C_Item, "GetItemCooldown") or Fn(C_Container, "GetItemCooldown")
		if fn then return fn(entry.id) end
	end
end

local function Usable(entry)
	if entry.kind == "spell" then
		local fn = Fn(C_Spell, "IsSpellUsable", "IsUsableSpell")
		if fn then return fn(entry.id) end
	elseif entry.kind == "item" then
		local fn = Fn(C_Item, "IsUsableItem")
		if fn then return fn(entry.id) end
	end
	return true
end

local function ItemCount(id)
	local fn = Fn(C_Item, "GetItemCount")
	return fn and fn(id) or 0
end

local function Update(b)
	local entry = b.entry
	if not entry then
		b.icon:SetTexture(nil)
		b.count:SetText("")
		b.cooldown:Clear()
		return
	end
	b.icon:SetTexture(Icon(entry) or QUESTION)

	local count = entry.kind == "item" and ItemCount(entry.id)
	b.count:SetText(count and count > 1 and count or "")
	b.icon:SetDesaturated(count == 0)

	local usable, noMana = Usable(entry)
	if usable then
		b.icon:SetVertexColor(1, 1, 1)
	elseif noMana then
		b.icon:SetVertexColor(0.5, 0.5, 1)
	else
		b.icon:SetVertexColor(0.4, 0.4, 0.4)
	end

	-- Cooldowns turn secret in combat (the buttons are only up out of it, but
	-- one can come just as it starts): left as they are until it ends.
	local ok, start, duration, enabled, modRate = pcall(Cooldown, entry)
	if ok and issecretvalue and (issecretvalue(start) or issecretvalue(duration) or issecretvalue(enabled)) then
		return
	end
	if ok and start and duration and duration > 0 and enabled ~= false and enabled ~= 0 then
		b.cooldown:SetCooldown(start, duration, modRate)
	else
		b.cooldown:Clear()
	end
end

local function UpdateAll()
	if not (holder and window:IsShown()) then return end
	for _, b in ipairs(buttons) do
		if b:IsVisible() then Update(b) end -- (not while they're away for combat)
	end
end

local function ShowTooltip(b)
	local entry = b.entry
	if not entry then
		if GameTooltip:IsOwned(b) then GameTooltip:Hide() end
		return
	end
	GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
	if entry.kind == "spell" then
		GameTooltip:SetSpellByID(entry.id)
	elseif entry.kind == "item" then
		GameTooltip:SetItemByID(entry.id)
	else
		GameTooltip:SetText(entry.name, 1, 1, 1)
	end
	GameTooltip:Show()
end

-- What a click does.
local function SetAction(b, entry)
	b.entry = entry
	if not entry then
		b:SetAttribute("type", nil)
	elseif entry.kind == "spell" then
		b:SetAttribute("type", "spell")
		b:SetAttribute("spell", entry.id)
	elseif entry.kind == "item" then
		b:SetAttribute("type", "item")
		b:SetAttribute("item", "item:" .. entry.id)
	elseif entry.kind == "macro" then
		b:SetAttribute("type", "macro")
		b:SetAttribute("macro", entry.name)
	end
end

---------------------------------------------------------------------------
-- Layout
---------------------------------------------------------------------------
local Make

local function Layout()
	if not (holder and list) then return end
	if Locked() then
		pending = true
		return
	end
	pending = false

	-- Under the last tab showing (the junk tab comes and goes).
	local tabs = 0
	for _, tab in ipairs(window.tabs) do
		if tab:IsShown() then tabs = tabs + 1 end
	end
	local x, y = window:TabOffset(tabs)
	holder:ClearAllPoints()
	holder:SetPoint("TOPLEFT", window, "TOPRIGHT", x, y - GAP)

	local shown = #list
	if cursorHas and shown < MAX then shown = shown + 1 end
	for i = 1, math.max(shown, #buttons) do
		local b = buttons[i] or Make(i)
		if i <= shown then
			SetAction(b, list[i])
			b:Show()
			Update(b)
		else
			SetAction(b, nil)
			b:Hide()
		end
	end
	if GameTooltip:GetOwner() and GameTooltip:GetOwner():GetParent() == holder then
		ShowTooltip(GameTooltip:GetOwner())
	end
end

---------------------------------------------------------------------------
-- Dragging on and off
---------------------------------------------------------------------------
-- The cursor's spell/item/macro onto button i; what was there goes on the cursor.
local function Drop(i)
	if Locked() then return end
	local entry = CursorEntry()
	if entry then
		ClearCursor()
		local old = list[i]
		list[math.min(i, #list + 1)] = entry
		if old then Pickup(old) end
	end
	Layout()
end

local function DragStart(b)
	if Locked() or not b.entry then return end
	if BarsLocked() and not IsModifiedClick("PICKUPACTION") then return end
	local entry = table.remove(list, b.index)
	Pickup(entry)
	Layout()
end

function Make(i)
	local b = CreateFrame("Button", "FireBagsAction" .. i, holder, "SecureActionButtonTemplate")
	ns.StyleTab(b)
	b.index = i
	b:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, -(i - 1) * ns.TAB_PITCH)
	b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	b.cooldown = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
	b.cooldown:SetAllPoints()
	b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	b.count:SetPoint("BOTTOMRIGHT", -2, 2)

	-- Act on release only (a drop on the down would be cast by the up). The
	-- game takes an addon's clicks for key presses, which follow the "cast on
	-- key down" setting unless told otherwise.
	b:RegisterForClicks("AnyUp")
	b:SetAttribute("useOnKeyDown", false)
	b:RegisterForDrag("LeftButton")
	b:SetScript("OnDragStart", DragStart)
	b:SetScript("OnReceiveDrag", function(self) Drop(self.index) end)
	-- A click with something on the cursor drops it instead of casting.
	b:SetScript("PreClick", function(self)
		if not Locked() and CursorEntry() then
			self.dropping = true
			self:SetAttribute("type", nil)
		end
	end)
	b:SetScript("PostClick", function(self)
		if self.dropping then
			self.dropping = nil
			Drop(self.index)
		end
	end)
	b:SetScript("OnEnter", ShowTooltip)
	b:SetScript("OnLeave", GameTooltip_Hide)

	buttons[i] = b
	return b
end

---------------------------------------------------------------------------
-- Combat: off the window, then back
---------------------------------------------------------------------------
local function Attach()
	if Locked() or not list then return end
	if not holder then
		holder = CreateFrame("Frame", nil, window)
		holder:SetSize(1, 1)
	end
	holder:SetParent(window)
	holder:SetFrameStrata(window:GetFrameStrata())
	holder:Show()
	Layout()
end

ns.On("PLAYER_LOGIN", function()
	local key = ns.CharacterKey()
	ns.db.chars[key] = ns.db.chars[key] or {}
	ns.db.chars[key].actions = ns.db.chars[key].actions or {}
	list = ns.db.chars[key].actions
	Attach()
end)

ns.On("PLAYER_REGEN_DISABLED", function()
	if not holder then return end
	holder:SetParent(away)
	holder:ClearAllPoints()
end)

ns.On("PLAYER_REGEN_ENABLED", function()
	if not holder or holder:GetParent() ~= window then
		Attach()
	elseif pending then
		Layout()
	end
end)

local updateJunkTab = ns.UpdateJunkTab
function ns.UpdateJunkTab()
	updateJunkTab()
	Layout()
end

---------------------------------------------------------------------------
-- Keeping up
---------------------------------------------------------------------------
local function CursorChanged()
	local has = CursorEntry() ~= nil
	if has == cursorHas then return end
	cursorHas = has
	Layout()
end
ns.On("CURSOR_CHANGED", CursorChanged)
ns.On("ACTIONBAR_SHOWGRID", CursorChanged)
ns.On("ACTIONBAR_HIDEGRID", CursorChanged)

window:HookScript("OnShow", UpdateAll)
for _, event in ipairs({
	"SPELL_UPDATE_COOLDOWN", "BAG_UPDATE_COOLDOWN", "SPELL_UPDATE_USABLE", "BAG_UPDATE_DELAYED",
	"SPELLS_CHANGED", "ACTIONBAR_UPDATE_COOLDOWN", "PLAYER_TARGET_CHANGED",
}) do
	ns.On(event, UpdateAll)
end
ns.On("UPDATE_MACROS", UpdateAll)
ns.On("GET_ITEM_INFO_RECEIVED", UpdateAll)
