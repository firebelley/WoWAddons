-- Adds "Bags: 12   Bank: 40" to item tooltips, using your bags and the saved
-- bank snapshot.
local _, ns = ...
local API = ns.API

local COLOR = { 0.55, 0.7, 1 }

local function ItemIDFromLink(link)
	if not link then return nil end
	return API.GetItemInfoInstant(link) or tonumber(link:match("item:(%d+)"))
end

---------------------------------------------------------------------------
-- Counts (cached; rebuilt when bags change or a new snapshot is saved)
---------------------------------------------------------------------------
local bagCounts
local bankCounts, bankCountsFor

local function GetBagCounts()
	if bagCounts then return bagCounts end
	bagCounts = {}
	for _, section in ipairs(ns.GetInventorySections()) do
		for _, entry in ipairs(section.bags) do
			for slot = 1, entry.numSlots do
				local info = API.GetSlotInfo(entry.bag, slot)
				if info and info.itemID then
					bagCounts[info.itemID] = (bagCounts[info.itemID] or 0) + (info.stackCount or 1)
				end
			end
		end
	end
	return bagCounts
end

local function GetBankCounts()
	local snapshot = ns.GetBankSnapshot()
	if not snapshot then return {} end
	if bankCountsFor == snapshot then return bankCounts end
	bankCounts = {}
	for _, bag in ipairs(snapshot.bags) do
		if ns.IsBankBag(bag.bag) then
			for _, item in pairs(bag.items) do
				local id = ItemIDFromLink(item.l)
				if id then bankCounts[id] = (bankCounts[id] or 0) + (item.c or 1) end
			end
		end
	end
	bankCountsFor = snapshot
	return bankCounts
end

-- How many of an item are in your bags, and in your bank (saved snapshot).
function ns.GetItemCounts(itemID)
	return GetBagCounts()[itemID] or 0, GetBankCounts()[itemID] or 0
end

local function Invalidate() bagCounts = nil end
ns.On("BAG_UPDATE", Invalidate)
ns.On("BAG_UPDATE_DELAYED", Invalidate)

---------------------------------------------------------------------------
-- Tooltip
---------------------------------------------------------------------------
local function AddCounts(tooltip, itemID)
	if not itemID or not ns.db or not ns.db.tooltipCounts then return end
	local bags = GetBagCounts()[itemID] or 0
	local bank = GetBankCounts()[itemID] or 0
	if bags + bank == 0 then return end

	local parts = {}
	if bags > 0 then table.insert(parts, "Bags: " .. bags) end
	if bank > 0 then table.insert(parts, "Bank: " .. bank) end
	tooltip:AddLine(table.concat(parts, "   "), COLOR[1], COLOR[2], COLOR[3])
end

local function IsMainTooltip(tooltip)
	return tooltip == GameTooltip or tooltip == ItemRefTooltip
end

if TooltipDataProcessor and Enum.TooltipDataType then
	-- Modern clients.
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
		if not IsMainTooltip(tooltip) then return end
		ns.SafeCall(AddCounts, tooltip, data and data.id)
	end)
else
	-- Older clients.
	for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
		tooltip:HookScript("OnTooltipSetItem", function(self)
			local _, link = self:GetItem()
			ns.SafeCall(AddCounts, self, ItemIDFromLink(link))
		end)
	end
end
