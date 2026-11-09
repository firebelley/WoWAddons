-- The unified bag window.
local _, ns = ...
local IB = ns.ItemButtons

-- Special bags whose title shows how much they hold, by bag family.
local COUNT_WORDS = { [1] = "arrows", [2] = "bullets", [4] = "shards" }

local function AddTotals(sections)
	for _, section in ipairs(sections) do
		local word = COUNT_WORDS[section.family]
		if word then
			local total = 0
			for _, entry in ipairs(section.bags) do
				for slot = 1, entry.numSlots do
					local info = ns.API.GetSlotInfo(entry.bag, slot)
					if info then total = total + (info.stackCount or 1) end
				end
			end
			local n = BreakUpLargeNumbers and BreakUpLargeNumbers(total) or total
			section.extra = n .. " " .. word
		end
	end
end

---------------------------------------------------------------------------
-- Currency in the title bar (right side)
---------------------------------------------------------------------------
local CURRENCY_NAME = "Merchant's Favor"
local MAX_CURRENCY_ID = 5000

local function GetCurrencyInfo(id)
	if not (C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo) then return nil end
	local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, id)
	return ok and info or nil
end

-- Finds the currency's ID by name (once; remembered in saved settings).
local function FindCurrencyID(name)
	local cached = ns.db.currencyIDs and ns.db.currencyIDs[name]
	if cached then return cached end
	if not (C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo) then return nil end

	local found
	-- The currency list (what's on the Currency tab) is the quick way...
	if C_CurrencyInfo.GetCurrencyListSize and C_CurrencyInfo.GetCurrencyListLink then
		for i = 1, C_CurrencyInfo.GetCurrencyListSize() do
			local item = C_CurrencyInfo.GetCurrencyListInfo(i)
			if item and item.name == name then
				local link = C_CurrencyInfo.GetCurrencyListLink(i)
				found = link and tonumber(link:match("currency:(%d+)"))
				break
			end
		end
	end
	-- ...but skips collapsed categories, so fall back to checking every ID.
	if not found then
		for id = 1, MAX_CURRENCY_ID do
			local info = GetCurrencyInfo(id)
			if info and info.name == name then
				found = id
				break
			end
		end
	end

	if found then
		ns.db.currencyIDs = ns.db.currencyIDs or {}
		ns.db.currencyIDs[name] = found
	end
	return found
end

local currencyID, searched

local function UpdateCurrency(window)
	if not currencyID and not searched then
		searched = true -- only search once per session
		currencyID = FindCurrencyID(CURRENCY_NAME)
	end
	local info = currencyID and GetCurrencyInfo(currencyID)
	if not info then
		window:SetTitleRight(nil)
		return
	end
	local amount = BreakUpLargeNumbers and BreakUpLargeNumbers(info.quantity or 0) or (info.quantity or 0)
	local icon = info.iconFileID and ("|T" .. info.iconFileID .. ":0:0:2:0|t") or ""
	window:SetTitleRight(amount .. icon)
end

local function Refresh(window)
	UpdateCurrency(window)
	ns.NewItems.Update()
	local sections = ns.GetInventorySections()
	AddTotals(sections)
	window:LayoutSections(sections, function(bag, slot)
		return IB.AcquireLive(window, bag, slot)
	end)
	local main = sections[1]
	window:SetStatus(("%d/%d free"):format(main.numFree, main.numSlots))
	window:SetTitleInfo(ns.API.FormatMoney(GetMoney()))
end

local window = ns.CreateWindow({
	name = "FireBagsFrame",
	title = "Bags",
	icon = "Interface\\Icons\\INV_Misc_Bag_08",
	key = "inventory",
	anchor = "BOTTOMRIGHT",
	defaultPosition = { x = -60, y = 110 },
	columnsKey = "columns",
	openSound = SOUNDKIT and SOUNDKIT.IG_BACKPACK_OPEN or 862,
	closeSound = SOUNDKIT and SOUNDKIT.IG_BACKPACK_CLOSE or 863,
	refresh = Refresh,
})
ns.inventory = window

window:HookScript("OnHide", function()
	-- Keep Blizzard's (hidden) bag state in step with ours.
	ns.CloseBlizzardBags()
	-- Closing your bags means you've seen what's new.
	ns.NewItems.ClearAll()
end)

---------------------------------------------------------------------------
-- Tabs
---------------------------------------------------------------------------
window:AddTab({
	title = "Sort Bags",
	text = "Special bags are sorted within themselves.",
	atlas = "bags-button-autosort-up",
	icon = "Interface\\Icons\\INV_Misc_Bag_08",
	onClick = function() ns.SortBags("inventory") end,
})

window.bankTab = window:AddTab({
	title = "Bank",
	text = function()
		return ns.atBank and "Show or hide your bank."
			or "Browse your bank from anywhere, using the snapshot saved on your last visit."
	end,
	icon = "Interface\\Icons\\INV_Box_02",
	onClick = function() ns.ToggleBank() end,
})

-- Currency tooltip.
window.titleRight:EnableMouse(true)
window.titleRight:SetScript("OnEnter", function(self)
	if not currencyID then return end
	GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
	if GameTooltip.SetCurrencyByID then
		GameTooltip:SetCurrencyByID(currencyID)
	else
		GameTooltip:SetText(CURRENCY_NAME)
	end
	GameTooltip:Show()
end)
window.titleRight:SetScript("OnLeave", GameTooltip_Hide)

ns.On("CURRENCY_DISPLAY_UPDATE", function()
	if window:IsShown() then UpdateCurrency(window) end
end)

-- Only shown while a vendor is open; greyed out when there's no junk.
local junkTab = window:AddTab({
	title = "Sell Junk",
	text = function()
		local count, value = ns.Junk.Summary()
		if count == 0 then return "No junk in your bags." end
		return ("Sell %d grey item%s for %s."):format(count, count == 1 and "" or "s", ns.API.FormatMoney(value))
	end,
	atlas = "SpellIcon-256x256-SellJunk",
	icon = "Interface\\Icons\\INV_Misc_Coin_02",
	onClick = function() ns.Junk.Sell() end,
})
junkTab:Hide()

function ns.UpdateJunkTab()
	local atMerchant = ns.Junk.atMerchant
	junkTab:SetShown(atMerchant)
	if atMerchant then junkTab:SetEnabledLook(ns.Junk.Summary() > 0) end
end

---------------------------------------------------------------------------
-- Search box, in the strip beside the portrait.
---------------------------------------------------------------------------
local search
local hasSearchTemplate = ns.API.TemplateExists("SearchBoxTemplate") ~= false
if hasSearchTemplate then
	local ok, box = pcall(CreateFrame, "EditBox", "FireBagsSearchBox", window, "SearchBoxTemplate")
	if ok then search = box end
end
if not search then
	search = CreateFrame("EditBox", "FireBagsSearchBox", window, "InputBoxTemplate")
end
search:SetSize(150, 20)
search:SetPoint("TOPRIGHT", window, "TOPRIGHT", -window.metrics.right - 4, window.metrics.statusY + 3)
search:SetAutoFocus(false)
search:HookScript("OnTextChanged", function(self)
	ns.ItemButtons.SetSearch(self:GetText())
end)
search:HookScript("OnEscapePressed", function(self)
	self:SetText("")
	self:ClearFocus()
end)
search:HookScript("OnEnterPressed", function(self) self:ClearFocus() end)
window.searchBox = search

-- Closing the bags clears the search.
window:HookScript("OnHide", function() search:SetText("") end)

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local function Relayout() window:RequestRefresh() end
local function UpdateButtons() window:RequestButtonUpdate() end

ns.On("BAG_UPDATE", function(bag)
	if not bag or ns.IsInventoryBag(bag) then Relayout() end
end)
ns.On("BAG_UPDATE_DELAYED", Relayout)
ns.On("BAG_CONTAINER_UPDATE", Relayout)
-- Comes with the slot (nothing for equipped items), so only that button.
ns.On("ITEM_LOCK_CHANGED", function(bag, slot) window:UpdateSlot(bag, slot) end)
ns.On("BAG_UPDATE_COOLDOWN", UpdateButtons)
ns.On("GET_ITEM_INFO_RECEIVED", UpdateButtons)
ns.On("PLAYER_MONEY", function()
	if window:IsShown() then window:SetTitleInfo(ns.API.FormatMoney(GetMoney())) end
end)
