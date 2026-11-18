-- The extra bars' buttons (Bars.lua): the game's look (its button template),
-- with their own upkeep. The game's full action button registers itself in
-- lists the game's own bars share; one made by an addon taints those, and
-- with them Edit Mode, stance and page changes. These keep to themselves.
--
-- What they show, as the game's: icon, count and charges, cooldown, out of
-- range and unusable colors, checked (current or auto-repeat), the attack
-- flash, the equipped border, macro names, the key bound, the tooltip. Drag
-- spells on and off (locked bars: with the pick-up modifier). Keys: hover one
-- in Quick Keybind mode and press a key (Escape clears it).
local _, ns = ...

local buttons = {} -- [button] = true
local bySlot = {}  -- [slot] = button
local hovered      -- the button under the mouse, for binding a key
local binding      -- Quick Keybind mode
local FLASH = 0.4  -- seconds per blink of the attack flash

local api = C_ActionBar or {}

local function Call(name, ...)
	local fn = api[name] or _G[name]
	if fn then return fn(...) end
end

local function Command(b) return "CLICK " .. b:GetName() .. ":LeftButton" end

local function HasAction(b) return b.action ~= nil and Call("HasAction", b.action) and true or false end

-- The game counts range checks per slot: turn one on once, off once.
local function RangeCheck(b, on)
	on = on and true or false
	if (b.rangeOn or false) == on or not (api.EnableActionRangeCheck and b.rangeSlot) then return end
	api.EnableActionRangeCheck(b.rangeSlot, on)
	b.rangeOn = on
end

---------------------------------------------------------------------------
-- Showing the action
---------------------------------------------------------------------------

local function UpdateHotkey(b)
	local hotkey = b.HotKey
	local key = GetBindingKey(Command(b))
	local text = key and GetBindingText(key, 1) or ""
	if text == "" then
		hotkey:SetText(RANGE_INDICATOR)
		hotkey:Hide()
	else
		local width = b:GetWidth()
		hotkey:SetSize(width - 8, 10)
		hotkey:ClearAllPoints()
		hotkey:SetPoint("TOPRIGHT", b, "TOPRIGHT", b.hotkeyTextKeyboardX or -4, b.hotkeyTextKeyboardY or -5)
		hotkey:SetText(text)
		hotkey:Show()
	end
end

local function UpdateRange(b, checks, inRange)
	local hotkey, normal, red = b.HotKey, ACTIONBAR_HOTKEY_FONT_COLOR, RED_FONT_COLOR
	if hotkey:GetText() == RANGE_INDICATOR then
		hotkey:SetShown(checks and true or false)
	end
	if checks and not inRange then
		if red then hotkey:SetVertexColor(red:GetRGB()) end
	elseif normal then
		hotkey:SetVertexColor(normal:GetRGB())
	end
end

local function UpdateCooldown(b)
	local action = b.action
	if not HasAction(b) then
		b.cooldown:Clear()
		b.chargeCooldown:Clear()
		return
	end
	-- Duration objects: cooldowns are secret in combat; these still show them.
	if api.GetActionCooldownDuration and b.cooldown.SetCooldownFromDurationObject then
		local d = api.GetActionCooldownDuration(action)
		if d then b.cooldown:SetCooldownFromDurationObject(d, true) else b.cooldown:Clear() end
		local c = api.GetActionChargeDuration and api.GetActionChargeDuration(action)
		if c then b.chargeCooldown:SetCooldownFromDurationObject(c, true) else b.chargeCooldown:Clear() end
	elseif api.GetActionCooldown then
		pcall(function()
			local info = api.GetActionCooldown(action)
			if info and info.isEnabled and info.duration > 0 then
				b.cooldown:SetCooldown(info.startTime, info.duration, info.modRate)
			else
				b.cooldown:Clear()
			end
		end)
	end
end

local function UpdateUsable(b)
	local icon = b.icon
	local usable, noMana = Call("IsUsableAction", b.action)
	if usable then
		icon:SetVertexColor(1, 1, 1)
	elseif noMana then
		icon:SetVertexColor(0.5, 0.5, 1)
	else
		icon:SetVertexColor(0.4, 0.4, 0.4)
	end
end

local flashing = {}
local flasher = CreateFrame("Frame")
flasher.elapsed = 0
flasher:SetScript("OnUpdate", function(self, elapsed)
	self.elapsed = self.elapsed + elapsed
	if self.elapsed < FLASH then return end
	self.elapsed = 0
	for b in pairs(flashing) do b.Flash:SetShown(not b.Flash:IsShown()) end
end)

local function UpdateState(b)
	local action = b.action
	b:SetChecked((Call("IsCurrentAction", action) or Call("IsAutoRepeatAction", action)) and true or false)
	local flash = (Call("IsAttackAction", action) and Call("IsCurrentAction", action))
		or Call("IsAutoRepeatAction", action)
	if flash then
		flashing[b] = true
	else
		flashing[b] = nil
		b.Flash:Hide()
	end
end

local function Update(b)
	local action = b.action
	if HasAction(b) then
		b.icon:SetTexture(Call("GetActionTexture", action))
		b.icon:Show()
		b.Count:SetText(Call("GetActionDisplayCount", action) or "")
		local kind = GetActionInfo(action)
		b.Name:SetText(kind == "macro" and (Call("GetActionText", action) or "") or "")
		if b.Border then
			if Call("IsEquippedAction", action) then
				b.Border:SetVertexColor(0, 1, 0, 0.5)
				b.Border:Show()
			else
				b.Border:Hide()
			end
		end
		UpdateUsable(b)
		UpdateState(b)
		RangeCheck(b, Call("HasRangeRequirements", action))
	else
		b.icon:Hide()
		b.Count:SetText("")
		b.Name:SetText("")
		if b.Border then b.Border:Hide() end
		b:SetChecked(false)
		flashing[b] = nil
		b.Flash:Hide()
		RangeCheck(b, false)
		UpdateRange(b, false)
	end
	UpdateCooldown(b)
	UpdateHotkey(b)
	if b.UpdateFlyout then b:UpdateFlyout() end
	if GameTooltip:IsOwned(b) then b:GetScript("OnEnter")(b) end
end

-- Which of a bar's buttons show (empty ones hide): worked out once, on the
-- next frame, however many slots changed. A bag sort changes dozens in one.
local dirtyBars, barsQueued = {}, false
local function UpdateBars()
	barsQueued = false
	for bar in pairs(dirtyBars) do
		dirtyBars[bar] = nil
		if bar.UpdateShownButtons then bar:UpdateShownButtons() end
	end
end
local function BarChanged(bar)
	if not bar then return end
	dirtyBars[bar] = true
	if not barsQueued then
		barsQueued = true
		C_Timer.After(0, UpdateBars)
	end
end

-- Its slot (from its bar's page): changed, then the new one shown.
local function Slot(b)
	-- Until its bar gives it a page it'd read the main bar's: wait.
	if not b:GetAttribute("actionpage") then return end
	local action = b:CalculateAction()
	if action == b.action then return end
	if b.action and bySlot[b.action] == b then bySlot[b.action] = nil end
	RangeCheck(b, false)
	b.action = action
	b.rangeSlot = action
	bySlot[action] = b
	Update(b)
	BarChanged(b.bar)
end

---------------------------------------------------------------------------
-- Using it
---------------------------------------------------------------------------

local function ShowTooltip(b)
	if binding then
		GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
		local key = GetBindingKey(Command(b))
		GameTooltip:SetText(key and GetBindingText(key, 1) or "Press a key", 1, 1, 1)
		if key then GameTooltip:AddLine("Escape to unbind", 0.7, 0.7, 0.7) end
		GameTooltip:Show()
		return
	end
	if not HasAction(b) then return end
	if GetCVar("UberTooltips") == "1" and GameTooltip_SetDefaultAnchor then
		GameTooltip_SetDefaultAnchor(GameTooltip, b)
	else
		GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
	end
	GameTooltip:SetAction(b.action)
end

local function BarsLocked()
	if Settings and Settings.GetValue then
		local ok, locked = pcall(Settings.GetValue, "lockActionBars")
		if ok and locked ~= nil then return locked end
	end
	return GetCVarBool("lockActionBars")
end

local function DragStart(b)
	if not BarsLocked() or IsModifiedClick("PICKUPACTION") then
		PickupAction(b.action)
		Update(b)
	end
end

local function ReceiveDrag(b)
	PlaceAction(b.action)
	Update(b)
end

-- Quick Keybind mode: the key pressed over one of ours binds it. Keys over
-- anything else go on to the game's.
local catcher = CreateFrame("Frame", nil, UIParent)
catcher:SetFrameStrata("TOOLTIP")
catcher:EnableKeyboard(false)
catcher:SetScript("OnKeyDown", function(self, key)
	if not (binding and hovered) or key:match("^[LR]?SHIFT$") or key:match("^[LR]?CTRL$") or key:match("^[LR]?ALT$") then
		self:SetPropagateKeyboardInput(true)
		return
	end
	self:SetPropagateKeyboardInput(false)
	local command = Command(hovered)
	if key == "ESCAPE" then
		while GetBindingKey(command) do SetBinding(GetBindingKey(command)) end
	else
		local chord = CreateKeyChordStringUsingMetaKeyState and CreateKeyChordStringUsingMetaKeyState(key) or key
		SetBinding(chord, command)
	end
	if SaveBindings and GetCurrentBindingSet then SaveBindings(GetCurrentBindingSet()) end
	for b in pairs(buttons) do UpdateHotkey(b) end
	ShowTooltip(hovered)
end)

function ns.SetBindMode(on)
	binding = on
	catcher:EnableKeyboard(on and true or false)
	if not on then catcher:SetPropagateKeyboardInput(true) end
	for b in pairs(buttons) do b.bindHighlight:SetShown(on and true or false) end
end

---------------------------------------------------------------------------
-- Its frame, as the game draws its buttons: the main bar's thick frame, or
-- the other bars' thin one.
---------------------------------------------------------------------------

local STYLES = {
	main = { slotArt = true, normal = "UI-HUD-ActionBar-IconFrame", pushed = "UI-HUD-ActionBar-IconFrame-Down", w = 46, h = 45 },
	other = { slotArt = false, normal = "UI-HUD-ActionBar-IconFrame-AddRow", pushed = "UI-HUD-ActionBar-IconFrame-AddRow-Down", w = 51, h = 51 },
}

function ns.SetButtonStyle(b, style)
	local s = STYLES[style] or STYLES.main
	if b.SlotArt then b.SlotArt:SetShown(s.slotArt) end
	if b.SlotBackground then b.SlotBackground:SetShown(not s.slotArt) end
	for _, part in ipairs({ { b:GetNormalTexture(), s.normal }, { b:GetPushedTexture(), s.pushed } }) do
		local texture, atlas = part[1], part[2]
		if texture then
			texture:SetAtlas(atlas)
			texture:SetSize(s.w, s.h)
			texture:SetDrawLayer("OVERLAY")
			texture:ClearAllPoints()
			texture:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
		end
	end
end

---------------------------------------------------------------------------
-- Setting one up
---------------------------------------------------------------------------

function ns.SetupButton(b)
	buttons[b] = true
	b.HasAction = HasAction
	b:SetAttribute("type", "action")
	b:SetAttribute("checkselfcast", true)
	b:SetAttribute("checkfocuscast", true)
	b:SetAttribute("checkmouseovercast", true)
	b:RegisterForClicks("AnyUp", "AnyDown")
	b:RegisterForDrag("LeftButton", "RightButton")
	b:HookScript("OnEnter", function(self)
		hovered = self
		ShowTooltip(self)
	end)
	b:HookScript("OnLeave", function(self)
		if hovered == self then hovered = nil end
		GameTooltip:Hide()
	end)
	b:HookScript("OnDragStart", DragStart)
	b:SetScript("OnReceiveDrag", ReceiveDrag)
	b:HookScript("PostClick", function(self) UpdateState(self) end)
	b:HookScript("OnAttributeChanged", function(self, name)
		if name == "actionpage" or name == "action" then Slot(self) end
	end)
	b.bindHighlight = b:CreateTexture(nil, "OVERLAY")
	b.bindHighlight:SetAtlas("UI-HUD-ActionBar-IconFrame-Mouseover")
	b.bindHighlight:SetAllPoints()
	b.bindHighlight:SetAlpha(0.5)
	b.bindHighlight:Hide()
	if b.cooldown.SetHideCountdownNumbers then
		b.cooldown:SetHideCountdownNumbers(not GetCVarBool("countdownForCooldowns"))
	end
	Slot(b)
end

---------------------------------------------------------------------------
-- Keeping up
---------------------------------------------------------------------------

local function Each(fn) for b in pairs(buttons) do fn(b) end end

local events = CreateFrame("Frame")
for _, event in ipairs({
	"PLAYER_ENTERING_WORLD", "ACTIONBAR_SLOT_CHANGED", "UPDATE_BINDINGS", "ACTIONBAR_UPDATE_STATE",
	"ACTIONBAR_UPDATE_USABLE", "ACTION_USABLE_CHANGED", "SPELL_UPDATE_USABLE", "ACTIONBAR_UPDATE_COOLDOWN",
	"SPELL_UPDATE_CHARGES", "ACTION_RANGE_CHECK_UPDATE", "PLAYER_TARGET_CHANGED", "UNIT_INVENTORY_CHANGED",
	"BAG_UPDATE_DELAYED", "PLAYER_EQUIPMENT_CHANGED", "UPDATE_SHAPESHIFT_FORM", "UPDATE_MACROS", "SPELLS_CHANGED",
	"PLAYER_ENTER_COMBAT", "PLAYER_LEAVE_COMBAT", "START_AUTOREPEAT_SPELL", "STOP_AUTOREPEAT_SPELL",
	"TRADE_SKILL_SHOW", "TRADE_SKILL_CLOSE", "CVAR_UPDATE",
}) do
	pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event, a, b, c)
	if event == "ACTIONBAR_SLOT_CHANGED" then
		-- 0: all of them. Otherwise just ours, if it's one of ours.
		if a == 0 then
			Each(Update)
			Each(function(btn) BarChanged(btn.bar) end)
		elseif bySlot[a] then
			Update(bySlot[a])
			BarChanged(bySlot[a].bar)
		end
	elseif event == "ACTION_RANGE_CHECK_UPDATE" then
		local button = bySlot[a]
		if button then UpdateRange(button, c, b) end
	elseif event == "UPDATE_BINDINGS" then
		Each(UpdateHotkey)
	elseif event == "ACTIONBAR_UPDATE_COOLDOWN" or event == "SPELL_UPDATE_CHARGES" then
		Each(UpdateCooldown)
		if event == "SPELL_UPDATE_CHARGES" then Each(function(btn) btn.Count:SetText(HasAction(btn) and Call("GetActionDisplayCount", btn.action) or "") end) end
	elseif event == "ACTIONBAR_UPDATE_USABLE" or event == "ACTION_USABLE_CHANGED" or event == "SPELL_UPDATE_USABLE" then
		Each(function(btn) if HasAction(btn) then UpdateUsable(btn) end end)
	elseif event == "ACTIONBAR_UPDATE_STATE" or event == "PLAYER_ENTER_COMBAT" or event == "PLAYER_LEAVE_COMBAT"
		or event == "START_AUTOREPEAT_SPELL" or event == "STOP_AUTOREPEAT_SPELL"
		or event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_CLOSE" then
		Each(function(btn) if HasAction(btn) then UpdateState(btn) end end)
	elseif event == "CVAR_UPDATE" then
		Each(function(btn)
			if btn.cooldown.SetHideCountdownNumbers then
				btn.cooldown:SetHideCountdownNumbers(not GetCVarBool("countdownForCooldowns"))
			end
		end)
	else
		Each(Update)
	end
end)

-- TEMPORARY (Profile.lua)
Update = ns.Timed("Button Update", Update)
Slot = ns.Timed("Button Slot", Slot)
flasher:SetScript("OnUpdate", ns.Timed("Button flash", flasher:GetScript("OnUpdate")))
events:SetScript("OnEvent", ns.Timed("Buttons event", events:GetScript("OnEvent"), true))
