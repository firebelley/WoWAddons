-- The bank window.
--
-- At a banker it shows your real bank (fully usable) and saves a snapshot of
-- it. Anywhere else it shows that snapshot, read-only, so you can check what's
-- in your bank without going there.
local _, ns = ...
local API = ns.API
local IB = ns.ItemButtons

ns.atBank = false

---------------------------------------------------------------------------
-- Snapshot storage (per character, in FireBagsDB.chars)
---------------------------------------------------------------------------
local function CharacterKey()
	return (UnitName("player") or "?") .. " - " .. (GetRealmName() or "?")
end

local function GetSnapshot()
	local char = ns.db.chars[CharacterKey()]
	return char and char.bank
end
ns.GetBankSnapshot = GetSnapshot

local function CountItems(bags)
	local n = 0
	for _, bag in ipairs(bags) do
		for _ in pairs(bag.items) do n = n + 1 end
	end
	return n
end

local function SaveSnapshot(sections)
	-- Bank data can arrive a moment after the banker opens; never overwrite a
	-- good snapshot with an empty one.
	if not ns.IsBankLoaded() then return end

	local bags = {}
	for _, section in ipairs(sections) do
		for _, entry in ipairs(section.bags) do
			local items = {}
			for slot = 1, entry.numSlots do
				local info = API.GetSlotInfo(entry.bag, slot)
				if info then
					items[slot] = {
						l = info.hyperlink or ("item:" .. (info.itemID or 0)),
						c = info.stackCount,
						i = info.iconFileID,
						q = info.quality,
						k = IB.QuestKind(entry.bag, slot, info),
						o = info.hasLoot or nil,
					}
				end
			end
			table.insert(bags, {
				bag = entry.bag,
				numSlots = entry.numSlots,
				numFree = entry.numFree,
				family = entry.family,
				title = entry.title,
				items = items,
			})
		end
	end

	-- When you walk away, the client may clear the bank's contents just before
	-- it tells us the visit ended. A sudden all-empty read is almost certainly
	-- that, not you emptying your whole bank, so keep the previous snapshot.
	local previous = GetSnapshot()
	if CountItems(bags) == 0 and previous and CountItems(previous.bags) > 0 then
		return
	end

	local key = CharacterKey()
	ns.db.chars[key] = ns.db.chars[key] or {}
	ns.db.chars[key].bank = { time = time(), bags = bags }
end

local function TimeAgo(t)
	local s = math.max(0, time() - t)
	if s < 60 then return "just now" end
	if s < 3600 then
		local m = math.floor(s / 60)
		return m .. (m == 1 and " minute ago" or " minutes ago")
	end
	if s < 86400 then
		local h = math.floor(s / 3600)
		return h .. (h == 1 and " hour ago" or " hours ago")
	end
	local d = math.floor(s / 86400)
	return d .. (d == 1 and " day ago" or " days ago")
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
local sortTab

local function Refresh(window)
	if ns.atBank then
		local sections = ns.GetLiveBankSections()
		SaveSnapshot(sections)
		window:SetMessage(nil)
		window:LayoutSections(sections, function(bag, slot)
			return IB.AcquireLive(window, bag, slot)
		end)
		local free, total = 0, 0
		for _, section in ipairs(sections) do
			free = free + section.numFree
			total = total + section.numSlots
		end
		window:SetStatus(("%d/%d free"):format(free, total))
	else
		local snapshot = GetSnapshot()
		if not snapshot then
			window:SetStatus("")
			window:SetMessage("Visit a banker once to save a snapshot of your bank.\nAfter that you can browse it from anywhere.")
			window:LayoutSections({}, nil)
		else
			local itemsByBag = {}
			for _, bag in ipairs(snapshot.bags) do itemsByBag[bag.bag] = bag.items end
			window:SetMessage(nil)
			window:LayoutSections(ns.GetSnapshotSections(snapshot), function(bag, slot)
				local b = IB.AcquireCached(window, bag, slot)
				b.fbItem = itemsByBag[bag] and itemsByBag[bag][slot]
				return b
			end)
			window:SetStatus("Saved " .. TimeAgo(snapshot.time) .. "\n|cff999999Visit a banker to use items|r")
		end
	end
	sortTab:SetEnabledLook(ns.atBank)
	if ns.UpdateBuyTab then ns.UpdateBuyTab() end
end

local window = ns.CreateWindow({
	name = "FireBagsBankFrame",
	title = "Bank",
	icon = "Interface\\Icons\\INV_Box_02",
	key = "bank",
	anchor = "TOPLEFT",
	defaultPosition = { x = 20, y = -104 },
	columnsKey = "bankColumns",
	openSound = SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPEN or 850,
	closeSound = SOUNDKIT and SOUNDKIT.IG_MAINMENU_CLOSE or 851,
	refresh = Refresh,
})
ns.bank = window

sortTab = window:AddTab({
	title = "Sort Bank",
	text = function()
		return ns.atBank and "Special bags are sorted within themselves."
			or "|cffff4040Visit a banker to sort your bank.|r"
	end,
	atlas = "bags-button-autosort-up",
	icon = "Interface\\Icons\\INV_Misc_Bag_08",
	onClick = function() ns.SortBags("bank") end,
})

---------------------------------------------------------------------------
-- Buying bank tabs (tab-based banks)
---------------------------------------------------------------------------
local BANK_TYPE = Enum and Enum.BankType and Enum.BankType.Character

local function CanBuyTab()
	if not (ns.atBank and BANK_TYPE and C_Bank and C_Bank.CanPurchaseBankTab) then return false end
	local ok, can = pcall(C_Bank.CanPurchaseBankTab, BANK_TYPE)
	return ok and can or false
end

-- cost (copper), canAfford — either may be nil if the client doesn't say.
local function NextTabCost()
	if C_Bank and C_Bank.FetchNextPurchasableBankTabData then
		local ok, data = pcall(C_Bank.FetchNextPurchasableBankTabData, BANK_TYPE)
		if ok and type(data) == "table" then return data.tabCost, data.canAfford end
	end
end

-- The client only lets Blizzard's own bank window buy tabs, so this button
-- explains how to do it instead of buying.
StaticPopupDialogs.FIREBAGS_BUY_BANK_TAB = {
	text = "Addons aren't allowed to buy bank tabs.\n\nTo buy the next tab%s, disable FireBags in the AddOns menu, "
		.. "visit a banker and buy it from Blizzard's bank window, then turn FireBags back on.",
	button1 = OKAY,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

local buyTab = window:AddTab({
	title = "Buy Bank Tab",
	text = function()
		local cost, canAfford = NextTabCost()
		local lines = {}
		if cost then
			local price = API.FormatMoney(cost)
			if canAfford == false then
				table.insert(lines, "|cffff4040Costs " .. price .. " — you can't afford it yet.|r")
			else
				table.insert(lines, "Costs " .. price .. ".")
			end
		end
		table.insert(lines, "|cff999999Addons can't buy bank tabs; click for how to buy one.|r")
		return table.concat(lines, "\n")
	end,
	atlas = "communities-icon-addchannelplus",
	icon = "Interface\\Buttons\\UI-PlusButton-Up",
	onClick = function()
		local cost = NextTabCost()
		StaticPopup_Show("FIREBAGS_BUY_BANK_TAB", cost and (" (" .. API.FormatMoney(cost) .. ")") or "")
	end,
})
buyTab:Hide()

function ns.UpdateBuyTab()
	buyTab:SetShown(CanBuyTab())
end

window:HookScript("OnShow", function()
	if ns.inventory.bankTab then ns.inventory.bankTab:SetSelected(true) end
end)
window:HookScript("OnHide", function()
	if ns.inventory.bankTab then ns.inventory.bankTab:SetSelected(false) end
	-- Closing the window while at the banker ends the bank visit, like Blizzard's.
	if ns.atBank then API.CloseBank() end
end)

-- /fbags debugbank: what the client reports for every bag ID that could be a
-- bank bag, plus what's in the saved snapshot.
function ns.DebugBank()
	ns.Print(("at bank: %s   BANK_CONTAINER=%s  NUM_BANKGENERIC_SLOTS=%s  NUM_BANKBAGSLOTS=%s  NUM_BAG_SLOTS=%s  NUM_REAGENTBAG_SLOTS=%s"):format(
		tostring(ns.atBank), tostring(BANK_CONTAINER), tostring(NUM_BANKGENERIC_SLOTS),
		tostring(NUM_BANKBAGSLOTS), tostring(NUM_BAG_SLOTS), tostring(NUM_REAGENTBAG_SLOTS)))

	if Enum and Enum.BagIndex then
		local names = {}
		for k, v in pairs(Enum.BagIndex) do table.insert(names, { k, v }) end
		table.sort(names, function(a, b) return a[2] < b[2] end)
		local parts = {}
		for _, kv in ipairs(names) do table.insert(parts, kv[1] .. "=" .. kv[2]) end
		print("  Enum.BagIndex: " .. table.concat(parts, ", "))
	end

	local used = {}
	for _, id in ipairs(ns.GetBankBagIDs()) do used[id] = true end
	for bag = -4, 16 do
		local slots = API.GetNumSlots(bag)
		if slots > 0 then
			local free, family = API.GetFreeSlots(bag)
			local items, first = 0, nil
			for slot = 1, slots do
				if API.GetSlotInfo(bag, slot) then
					items = items + 1
					first = first or slot
				end
			end
			print(("  bag %d: %d slots, %s free, family %s, %d items (first in slot %s)%s"):format(
				bag, slots, tostring(free), tostring(family), items, tostring(first),
				used[bag] and "  <- FireBags bank" or (ns.IsInventoryBag(bag) and "  <- FireBags bags" or "")))
		end
	end

	local snapshot = GetSnapshot()
	if snapshot then
		print(("  snapshot from %s:"):format(TimeAgo(snapshot.time)))
		for _, bag in ipairs(snapshot.bags) do
			local n = 0
			for _ in pairs(bag.items) do n = n + 1 end
			print(("    bag %d: %d slots, %d items"):format(bag.bag, bag.numSlots, n))
		end
	else
		print("  no snapshot saved")
	end
end

function ns.ToggleBank()
	if window:IsShown() then
		window:Hide()
	else
		window.openedByBanker = false
		window:Show()
	end
end

---------------------------------------------------------------------------
-- Banker visits
---------------------------------------------------------------------------
local function OnBankOpened()
	if ns.atBank then return end
	ns.atBank = true
	if window:IsShown() then
		window.openedByBanker = false
		window:RequestRefresh()
	else
		window.openedByBanker = true
		window:Show()
	end
	-- Open the bags too, like the default bank does.
	OpenAllBags(window)
end

local function OnBankClosed()
	if not ns.atBank then return end
	ns.atBank = false
	CloseAllBags(window)
	if window.openedByBanker then
		window:Hide()
	else
		window:RequestRefresh() -- switch to the snapshot view
	end
end

local BANKER = Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.Banker

ns.On("BANKFRAME_OPENED", OnBankOpened)
ns.On("BANKFRAME_CLOSED", OnBankClosed)
ns.On("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(kind)
	if BANKER and kind == BANKER then OnBankOpened() end
end)
ns.On("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(kind)
	if BANKER and kind == BANKER then OnBankClosed() end
end)

local function Relayout()
	if ns.atBank then window:RequestRefresh() end
end
ns.On("PLAYERBANKSLOTS_CHANGED", Relayout)
ns.On("BANK_TABS_CHANGED", Relayout)          -- a tab was bought
ns.On("BANK_TAB_SETTINGS_UPDATED", Relayout)  -- a tab was renamed
ns.On("PLAYERBANKBAGSLOTS_CHANGED", Relayout)
ns.On("BAG_UPDATE", function(bag)
	if not bag or ns.IsBankBag(bag) then Relayout() end
end)
ns.On("BAG_UPDATE_DELAYED", Relayout)
ns.On("BAG_CONTAINER_UPDATE", Relayout)
ns.On("ITEM_LOCK_CHANGED", function(bag, slot) window:UpdateSlot(bag, slot) end)
ns.On("GET_ITEM_INFO_RECEIVED", function() window:RequestButtonUpdate() end)
