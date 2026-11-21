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
	return (UnitName("player") or "?") .. " - " .. ns.RealmName()
end
ns.CharacterKey = CharacterKey

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
	if ns.UpdateBankBags then ns.UpdateBankBags() end -- before the layout: it makes room for them
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
			window:SetMessage("Visit a banker once to browse your bank from anywhere.")
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
		if not ns.atBank then return "|cffff4040Visit a banker to sort your bank.|r" end
		local line = "\nAlt-click an item to lock it in place."
		if ns.bankModel == "tabs" then
			return (ns.db.bankTabsSeparate and "Each tab is sorted on its own." or "Sorted across all your tabs.") .. line
		end
		return "Special bags are sorted within themselves." .. line
	end,
	atlas = "bags-button-autosort-up",
	icon = "Interface\\Icons\\INV_Misc_Bag_08",
	onClick = function() ns.SortBags("bank") end,
})

-- One grid for the whole bank, or each tab in its own section.
if ns.bankModel == "tabs" then
	local separateTab
	separateTab = window:AddTab({
		title = "Separate Tabs",
		text = function()
			return ns.db.bankTabsSeparate and "Each bank tab has its own section. Click to show them as one."
				or "Your bank tabs are shown as one. Click to give each tab its own section."
		end,
		icon = "Interface\\Icons\\INV_Misc_Note_02",
		onClick = function(self)
			ns.db.bankTabsSeparate = not ns.db.bankTabsSeparate
			separateTab:SetSelected(ns.db.bankTabsSeparate)
			window:RequestRefresh()
			if GameTooltip:GetOwner() == self then self:GetScript("OnEnter")(self) end
		end,
	})
	window:HookScript("OnShow", function() separateTab:SetSelected(ns.db.bankTabsSeparate) end)
end

---------------------------------------------------------------------------
-- Bank bag slots, along the bottom while at a banker, like the game's bank.
-- On Forever each bank tab after the first is a slot for one of your bags
-- (its tab holds what fits in that bag). A bought slot shows its bag: click
-- or drag to take it out or put one in. The next one to buy shows "+": click
-- to buy it (asked first, with the price). The rest are locked until then.
---------------------------------------------------------------------------
local BagIndex = Enum and Enum.BagIndex or {}
local BANK_TYPE = Enum and Enum.BankType and Enum.BankType.Character
local TAB_BAGS = BagIndex.Characterbanktab -- the slots the bags sit in
local BAG_GAP = 4
local SLOT = ns.SLOT_SIZE

local function UsesBags()
	return ns.bankModel == "tabs" and BANK_TYPE and TAB_BAGS and C_Bank and C_Bank.FetchMaxNumBankTabs
		and C_Bank.FetchPurchasedBankTabData
		and (not C_Bank.ShouldUsePlayerBagsInBank or C_Bank.ShouldUsePlayerBagsInBank())
end

local function Call(fn, ...)
	local ok, a = pcall(fn, ...)
	if ok then return a end
end

-- cost (copper), canAfford: the next slot's; nil when there's none to buy.
local function NextCost()
	local data = C_Bank.FetchNextPurchasableBankTabData and Call(C_Bank.FetchNextPurchasableBankTabData, BANK_TYPE)
	if type(data) == "table" and data.tabCost then return data.tabCost, data.canAfford end
end

-- Only Blizzard's bank window can buy slots: this offers Blizzard's bags and
-- bank for the next session, until its bank visit ends (Core.lua). Our own
-- box, not the game's popups.
local confirm
local function ConfirmBuy()
	local cost = NextCost()
	if not cost then return end
	if not confirm then
		confirm = CreateFrame("Frame", "FireBagsBuyBankSlot", UIParent, "BackdropTemplate")
		confirm:SetSize(340, 112)
		confirm:SetPoint("TOP", 0, -135)
		confirm:SetFrameStrata("DIALOG")
		confirm:EnableMouse(true)
		confirm:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			tile = true, tileSize = 32, edgeSize = 32,
			insets = { left = 11, right = 12, top = 12, bottom = 11 },
		})
		confirm.text = confirm:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		confirm.text:SetPoint("TOP", 0, -24)
		confirm.text:SetWidth(280)
		local yes = CreateFrame("Button", nil, confirm, "UIPanelButtonTemplate")
		yes:SetSize(110, 22)
		yes:SetPoint("BOTTOMRIGHT", confirm, "BOTTOM", -6, 18)
		yes:SetText(YES or "Yes")
		yes:SetScript("OnClick", function()
			confirm:Hide()
			ns.db.blizzardOnce = true
			window:Hide() -- ends the visit
			ns.Print("type /reload, then talk to the banker.")
		end)
		confirm.yes = yes
		local no = CreateFrame("Button", nil, confirm, "UIPanelButtonTemplate")
		no:SetSize(110, 22)
		no:SetPoint("BOTTOMLEFT", confirm, "BOTTOM", 6, 18)
		no:SetText(CANCEL or "Cancel")
		no:SetScript("OnClick", function() confirm:Hide() end)
		table.insert(UISpecialFrames, "FireBagsBuyBankSlot")
	end
	local _, canAfford = NextCost()
	confirm.text:SetText("Only Blizzard's bank window can buy slots (" .. API.FormatMoney(cost) .. ").\n"
		.. "Use Blizzard's bags and bank after your next /reload?"
		.. (canAfford == false and "\n|cffff4040You can't afford it.|r" or ""))
	confirm.yes:SetEnabled(canAfford ~= false)
	confirm:Show()
end

local bagBar = CreateFrame("Frame", nil, window)
bagBar:SetHeight(SLOT)
bagBar:Hide()
window:SetBottomBar(bagBar)
local bagButtons = {}

local function Pickup(b)
	if b.state == "bought" then C_Container.PickupContainerItem(TAB_BAGS, b.slot) end
end

local function BagTooltip(b)
	GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
	if b.state == "bought" then
		if not GameTooltip:SetBagItem(TAB_BAGS, b.slot) then
			GameTooltip:SetText(BANK_BAG or "Bank bag slot")
			GameTooltip:AddLine("Put a bag here to add its slots to your bank.", 1, 1, 1, true)
		end
	elseif b.state == "next" then
		local cost, canAfford = NextCost()
		GameTooltip:SetText(BANK_BAG_PURCHASE or "Buy bank bag slot")
		if cost then
			GameTooltip:AddLine(API.FormatMoney(cost), canAfford == false and 1 or 1, canAfford == false and 0.25 or 1,
				canAfford == false and 0.25 or 1)
		end
		GameTooltip:AddLine("Bought in Blizzard's bank window.", 0.6, 0.6, 0.6)
	else
		GameTooltip:SetText(BANK_BAG_PURCHASE or "Buy bank bag slot")
		GameTooltip:AddLine("Buy the slots before it first.", 0.6, 0.6, 0.6)
	end
	GameTooltip:Show()
end

local function BagButton(i)
	local b = CreateFrame("Button", nil, bagBar)
	b:SetSize(SLOT, SLOT)
	b:SetPoint("LEFT", (i - 1) * (SLOT + BAG_GAP), 0)
	local bg = b:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	if API.AtlasExists("bags-item-slot-blank") then
		bg:SetAtlas("bags-item-slot-blank")
	else
		bg:SetTexture("Interface\\Buttons\\UI-EmptySlot-Disabled")
		bg:SetTexCoord(0.140625, 0.859375, 0.140625, 0.859375)
	end
	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetAllPoints()
	b.mark = b:CreateTexture(nil, "OVERLAY")
	b.mark:SetSize(SLOT * 0.5, SLOT * 0.5)
	b.mark:SetPoint("CENTER")
	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
	hl:SetBlendMode("ADD")
	hl:SetAllPoints()
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")
	b:SetScript("OnClick", function(self)
		if self.state == "next" then ConfirmBuy() else Pickup(self) end
	end)
	b:SetScript("OnDragStart", Pickup)
	b:SetScript("OnReceiveDrag", Pickup)
	b:SetScript("OnEnter", BagTooltip)
	b:SetScript("OnLeave", GameTooltip_Hide)
	bagButtons[i] = b
	return b
end

-- Shown (and up to date) while at a banker whose tabs hold bags.
function ns.UpdateBankBags()
	local show = ns.atBank and UsesBags() and true or false
	if show then
		local max = Call(C_Bank.FetchMaxNumBankTabs, BANK_TYPE) or 0
		local bought = Call(C_Bank.FetchPurchasedBankTabData, BANK_TYPE) or {}
		local nextOne = NextCost() and #bought + 1
		local n = 0
		-- The first tab is the bank itself: the slots start with the second
		-- (unless the first isn't bought yet - it's free - then with it).
		for slot = nextOne == 1 and 1 or 2, max do
			n = n + 1
			local b = bagButtons[n] or BagButton(n)
			b.slot = slot
			b.state = bought[slot] and "bought" or (slot == nextOne and "next") or "locked"
			local info = b.state == "bought" and API.GetSlotInfo(TAB_BAGS, slot)
			b.icon:SetTexture(info and info.iconFileID or nil)
			b.icon:SetDesaturated(info and info.isLocked or false)
			b.mark:Show()
			if info then
				b.mark:Hide()
			elseif b.state == "bought" then
				b.mark:SetTexture("Interface\\Icons\\INV_Misc_Bag_08")
				b.mark:SetVertexColor(0.5, 0.5, 0.5, 0.45)
			elseif b.state == "next" then
				b.mark:SetTexture("Interface\\PaperDollInfoFrame\\Character-Plus")
				b.mark:SetVertexColor(1, 1, 1, 1)
			else
				b.mark:SetTexture("Interface\\PetBattles\\PetBattle-LockIcon")
				b.mark:SetVertexColor(1, 1, 1, 0.6)
			end
			b:Show()
			if GameTooltip:IsOwned(b) then BagTooltip(b) end
		end
		for i = n + 1, #bagButtons do bagButtons[i]:Hide() end
		show = n > 0
		bagBar:SetWidth(math.max(1, n * (SLOT + BAG_GAP) - BAG_GAP))
	end
	bagBar:SetShown(show)
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
	if ns.blizzardBank then -- Blizzard's window this visit (to buy a slot)
		ns.blizzardBankUsed = true
		return
	end
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
	-- That visit with Blizzard's window is over: ours again, once it's shut.
	if ns.blizzardBank then
		if ns.blizzardBankUsed then
			ns.blizzardBankUsed = nil
			local tries = 0
			local function Back()
				tries = tries + 1
				if not ns.blizzardBank then return end
				if BankFrame and BankFrame:IsShown() and tries < 20 then
					C_Timer.After(0.1, Back)
				else
					ns.TakeOver()
				end
			end
			C_Timer.After(0, Back)
		end
		return
	end
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
ns.On("ITEM_LOCK_CHANGED", function(bag, slot)
	if TAB_BAGS and bag == TAB_BAGS then Relayout() else window:UpdateSlot(bag, slot) end -- a bank bag picked up
end)
ns.On("PLAYER_MONEY", function() if bagBar:IsShown() then ns.UpdateBankBags() end end)
ns.On("GET_ITEM_INFO_RECEIVED", function() window:RequestButtonUpdate() end)
