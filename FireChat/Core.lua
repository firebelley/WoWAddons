-- FireChat: restyles Blizzard's own chat windows. It never draws or reads
-- messages itself: on Forever, chat text is secret in dungeons, raids and PvP,
-- so Blizzard's code has to keep showing it.
--
-- Taint rules (Blizzard's chat code handles secret values, so these matter):
--   * Only widget calls on Blizzard objects (SetTexture, SetAlpha, SetPoint...).
--     Never write fields on Blizzard frames or Blizzard globals
--     (e.g. CHAT_FRAME_TAB_*_ALPHA): tainted values would reach UIFrameFade.
--   * Never call UIFrameFadeIn/Out or ChatFrameUtil.SetTabAlphas; our own
--     animator fades only regions Blizzard doesn't fade (tab text, buttons).
--   * Hook with hooksecurefunc / HookScript only.
local ADDON, ns = ...

local DEFAULTS = {
	hoverOnly = true, -- tabs and buttons only while the mouse is over the chat
	outline = true,   -- outlined text instead of a drop shadow
}
local LINE_SPACING = 2
local FADE_IN, FADE_OUT = 0.15, 0.4 -- seconds

ns.db = nil
local skinned = {} -- chatFrame -> { tab, buttons = { ... } }

-------------------------------------------------------------------------------
-- Alpha animator for the regions we own.
-------------------------------------------------------------------------------
local fades = {} -- region -> target alpha
local animator = CreateFrame("Frame")
animator:Hide()
animator:SetScript("OnUpdate", function(self, elapsed)
	local busy = false
	for region, target in pairs(fades) do
		local a = region:GetAlpha()
		if a < target then
			a = math.min(target, a + elapsed / FADE_IN)
		else
			a = math.max(target, a - elapsed / FADE_OUT)
		end
		region:SetAlpha(a)
		if a == target then fades[region] = nil else busy = true end
	end
	if not busy then self:Hide() end
end)

local function FadeTo(region, target, instant)
	if not region then return end
	if instant or math.abs(region:GetAlpha() - target) < 0.001 then
		fades[region] = nil
		region:SetAlpha(target)
	else
		fades[region] = target
		animator:Show()
	end
end

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------
-- A texture Blizzard never shows again: emptied and hidden.
local function Kill(tex)
	if not tex then return end
	tex:SetTexture(nil)
	tex:Hide()
end

-- A texture Blizzard may Show/Hide or tint: emptied only.
local function Blank(tex)
	if tex then tex:SetTexture(nil) end
end

local function Hook(fname, fn)
	if type(_G[fname]) == "function" then hooksecurefunc(fname, fn) end
end

local function IsAlerting(tab)
	if ChatFrameUtil and ChatFrameUtil.IsTabAlerting then
		local ok, alerting = pcall(ChatFrameUtil.IsTabAlerting, tab)
		if ok then return alerting end
	end
	return tab.alerting
end

local BORDERS = {
	"TopLeftTexture", "BottomLeftTexture", "TopRightTexture", "BottomRightTexture",
	"LeftTexture", "RightTexture", "BottomTexture", "TopTexture",
}

-------------------------------------------------------------------------------
-- Tabs: text only, with a thin line under the selected one. The line is
-- Blizzard's own "selected" texture, so it keeps Blizzard's show/hide and tint.
-------------------------------------------------------------------------------
local function Underline(tex, tab, alpha)
	if not tex then return end
	tex:SetColorTexture(1, 1, 1, alpha)
	tex:SetBlendMode("BLEND")
	tex:ClearAllPoints()
	local text = tab:GetFontString()
	tex:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -3)
	tex:SetPoint("TOPRIGHT", text, "BOTTOMRIGHT", 0, -3)
	tex:SetHeight(1)
end

local function SkinTab(tab)
	Blank(tab.Left); Blank(tab.Middle); Blank(tab.Right)
	Blank(tab.ActiveLeft); Blank(tab.ActiveRight)
	Blank(tab.HighlightLeft); Blank(tab.HighlightRight)
	Underline(tab.ActiveMiddle, tab, 1)
	Underline(tab.HighlightMiddle, tab, 0.4)
end

-- Selected tab white, others grey. Whisper tabs keep their chat color.
local function ColorTab(tab, selected)
	if not tab or tab.selectedColorTable then return end
	local fs = tab:GetFontString()
	if not fs then return end
	if selected then
		fs:SetTextColor(1, 1, 1)
	else
		fs:SetTextColor(0.6, 0.6, 0.6)
	end
end

-------------------------------------------------------------------------------
-- Input box: a flat dark bar; while typing, a colored edge in the chat type's
-- color (Blizzard's focus texture, which Blizzard tints and shows on focus).
-------------------------------------------------------------------------------
local function SkinEditBox(eb)
	if not eb then return end
	local name = eb:GetName()
	if name then
		Kill(_G[name .. "Left"]); Kill(_G[name .. "Mid"]); Kill(_G[name .. "Right"])
	end
	Blank(eb.focusLeft); Blank(eb.focusRight)

	local bg = eb:CreateTexture(nil, "BACKGROUND")
	bg:SetColorTexture(0, 0, 0, 0.6)
	bg:SetPoint("TOPLEFT", 6, -6)
	bg:SetPoint("BOTTOMRIGHT", -6, 6)
	bg:SetShown(eb:HasFocus())
	eb:HookScript("OnEditFocusGained", function() bg:Show() end)
	eb:HookScript("OnEditFocusLost", function() bg:Hide() end)

	local edge = eb.focusMid
	if edge then
		edge:SetColorTexture(1, 1, 1, 1)
		edge:SetBlendMode("BLEND")
		edge:ClearAllPoints()
		edge:SetPoint("TOPLEFT", bg, "TOPLEFT")
		edge:SetPoint("BOTTOMLEFT", bg, "BOTTOMLEFT")
		edge:SetWidth(2)
	end
end

-------------------------------------------------------------------------------
-- Font
-------------------------------------------------------------------------------
local function ApplyFont(cf)
	local file, size, flags = cf:GetFont()
	if not file then return end
	local want = ns.db.outline and "OUTLINE" or ""
	if (flags or "") ~= want then cf:SetFont(file, size, want) end
	if ns.db.outline then
		cf:SetShadowOffset(0, 0)
	else
		cf:SetShadowOffset(1, -1)
	end
	cf:SetSpacing(LINE_SPACING)
end

-------------------------------------------------------------------------------
-- Show/hide tabs and buttons with Blizzard's own mouse-over state.
-------------------------------------------------------------------------------
local function Update(cf, instant)
	local s = skinned[cf]
	if not s then return end
	local show = (not ns.db.hoverOnly) or cf.hasBeenFaded and true or false
	local tab = s.tab
	if tab then
		-- An unread-message tab stays readable.
		FadeTo(tab:GetFontString(), (show or IsAlerting(tab)) and 1 or 0, instant)
		FadeTo(tab.ActiveMiddle, show and 1 or 0, instant)
	end
	for _, b in ipairs(s.buttons) do FadeTo(b, show and 1 or 0, instant) end
end

local function Skin(cf)
	if skinned[cf] then return end
	local name = cf:GetName()
	if not name then return end
	local s = { tab = _G[name .. "Tab"], buttons = {} }
	skinned[cf] = s

	-- Window and button-bar borders. The window background stays: it follows
	-- the opacity set in the tab's right-click menu.
	for _, k in ipairs(BORDERS) do
		Kill(_G[name .. k])
		Kill(_G[name .. "ButtonFrame" .. k])
	end
	Kill(_G[name .. "ButtonFrameBackground"])

	-- Scroll bar: track and thumb only (it already shows only on mouse-over).
	local bar = cf.ScrollBar
	if bar then
		for _, k in ipairs({ "Back", "Forward" }) do
			local b = bar[k]
			if b then b:SetAlpha(0); b:EnableMouse(false) end
		end
	end

	if s.tab then
		SkinTab(s.tab)
		ColorTab(s.tab, s.tab.ActiveMiddle and s.tab.ActiveMiddle:IsShown())
	end
	SkinEditBox(cf.editBox or _G[name .. "EditBox"])

	local bf = cf.buttonFrame
	if bf and bf.minimizeButton then tinsert(s.buttons, bf.minimizeButton) end
	if cf == DEFAULT_CHAT_FRAME then
		-- The "..." tab fades like the tabs; voice mute/deafen (only shown in a
		-- voice channel) stay on the button bar.
		for _, b in ipairs({ ChatFrameMenuButton,
			ChatFrameToggleVoiceDeafenButton, ChatFrameToggleVoiceMuteButton }) do
			tinsert(s.buttons, b)
		end
	end

	ApplyFont(cf)
	Update(cf, true)
end

local function SkinAll()
	for _, frameName in ipairs(CHAT_FRAMES or {}) do
		local cf = _G[frameName]
		if cf then Skin(cf) end
	end
end

-------------------------------------------------------------------------------
-- "..." tab: Blizzard's own chat menu button (Say, Party, Emotes, Languages...)
-- moved to the right end of the tab row and drawn as a tab. Being Blizzard's
-- button, clicks and the menu stay Blizzard's code. Friends and Channels are
-- added to that menu through Menu.ModifyMenu, the menu system's addon hook.
-- The friends and channels buttons are hidden.
-------------------------------------------------------------------------------
local hidden = CreateFrame("Frame")
hidden:Hide()

local function HideButton(b)
	if b and b:GetParent() ~= hidden then b:SetParent(hidden) end
end

local menuTab
local function PlaceMenuTab()
	local b = ChatFrameMenuButton
	local bg = DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.Background
	if not (b and bg) then return end
	b:ClearAllPoints()
	-- Left of the dock's overflow arrow when there are too many tabs.
	local overflow = GENERAL_CHAT_DOCK and GENERAL_CHAT_DOCK.overflowButton
	if overflow and overflow:IsShown() then
		b:SetPoint("RIGHT", overflow, "LEFT", -2, 0)
	else
		b:SetPoint("BOTTOMRIGHT", bg, "TOPRIGHT", 0, 0)
	end
end

local function OnlineFriends()
	local n = 0
	if C_FriendList and C_FriendList.GetNumOnlineFriends then
		n = n + (C_FriendList.GetNumOnlineFriends() or 0)
	end
	if BNGetNumFriends then
		local ok, _, online = pcall(BNGetNumFriends)
		if ok then n = n + (online or 0) end
	end
	return n
end

local function SetupMenuTab()
	local b = ChatFrameMenuButton
	if not b or menuTab then return end
	menuTab = b
	for _, get in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetDisabledTexture", "GetHighlightTexture" }) do
		local t = b[get] and b[get](b)
		if t then t:SetTexture(nil) end
	end
	b:SetSize(26, 22)
	local text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	text:SetPoint("CENTER", 0, 0)
	text:SetText("...")
	text:SetTextColor(0.6, 0.6, 0.6)
	b:HookScript("OnEnter", function() text:SetTextColor(1, 1, 1) end)
	b:HookScript("OnLeave", function() text:SetTextColor(0.6, 0.6, 0.6) end)
	PlaceMenuTab()
	Hook("FCFDock_UpdateTabs", PlaceMenuTab)

	HideButton(ChatFrameChannelButton)
	HideButton(QuickJoinToastButton)

	if Menu and Menu.ModifyMenu then
		Menu.ModifyMenu("MENU_CHAT_SHORTCUTS", function(_, root)
			root:CreateDivider()
			if ToggleFriendsFrame then
				local n = OnlineFriends()
				local label = FRIENDS or "Friends"
				if n > 0 then label = ("%s (%d)"):format(label, n) end
				root:CreateButton(label, function() ToggleFriendsFrame() end)
			end
			if ToggleChannelFrame then
				root:CreateButton(CHAT_CHANNELS or "Channels", function() ToggleChannelFrame() end)
			end
		end)
	end
end

-------------------------------------------------------------------------------
-- Edit Mode box: Blizzard pads it for the button bar (left), tab art (top) and
-- scroll bar (right). Fit it to what's drawn now: background, tab names, and
-- the input bar underneath. Edit Mode reads these anchors for snapping and
-- keeping the window on screen, so both follow.
-------------------------------------------------------------------------------
local function FitEditModeBox()
	local cf = DEFAULT_CHAT_FRAME
	local sel = cf and cf.Selection
	if not sel then return end
	sel:ClearAllPoints()
	-- TOPLEFT must be point 1 and BOTTOMRIGHT point 2 (Edit Mode reads them so).
	sel:SetPoint("TOPLEFT", cf, "TOPLEFT", -4, 26)
	sel:SetPoint("BOTTOMRIGHT", cf, "BOTTOMRIGHT", 16, -30)
	if cf.UpdateClampOffsets then cf:UpdateClampOffsets() end
end

function ns.Refresh()
	for cf in pairs(skinned) do
		ApplyFont(cf)
		Update(cf)
	end
end

-------------------------------------------------------------------------------
-- Hooks
-------------------------------------------------------------------------------
local function InstallHooks()
	Hook("FCF_FadeInChatFrame", function(cf)
		Update(cf)
		-- Faded-out lines come back while the mouse is over the chat.
		if cf.ResetAllFadeTimes then cf:ResetAllFadeTimes() end
	end)
	Hook("FCF_FadeOutChatFrame", function(cf) Update(cf) end)
	Hook("FCF_StartAlertFlash", function(cf) Update(cf) end)
	Hook("FCF_StopAlertFlash", function(cf) Update(cf) end)
	Hook("FCFTab_UpdateColors", ColorTab)
	-- New windows (whispers in their own tab, "New Window").
	Hook("FCF_OpenTemporaryWindow", SkinAll)
	Hook("FCF_OpenNewWindow", SkinAll)
end

-------------------------------------------------------------------------------
-- Startup
-------------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" and arg1 == ADDON then
		FireChatDB = FireChatDB or {}
		for k, v in pairs(DEFAULTS) do
			if FireChatDB[k] == nil then FireChatDB[k] = v end
		end
		ns.db = FireChatDB
		ns.Options.Init()
	elseif event == "ADDON_LOADED" and arg1 == "Blizzard_QuickJoin" then
		if menuTab then HideButton(QuickJoinToastButton) end
	elseif event == "PLAYER_LOGIN" then
		InstallHooks()
		SetupMenuTab()
		SkinAll()
		FitEditModeBox()
	end
end)

SLASH_FIRECHAT1 = "/fchat"
SLASH_FIRECHAT2 = "/firechat"
SlashCmdList.FIRECHAT = function() ns.Options.Open() end
