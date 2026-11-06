-- Selling junk: the bag window shows a "Sell Junk" tab while a vendor is open.
-- Clicking it sells every grey item in your bags.
local _, ns = ...
local API = ns.API

local SELL_INTERVAL = 0.15 -- seconds between sales, so the server keeps up

local Junk = {}
ns.Junk = Junk
Junk.atMerchant = false

local queue, sold, earned
local ticker

-- Grey items in your bags that a vendor will buy.
local function JunkSlots()
	local list = {}
	for _, bag in ipairs(ns.GetInventoryBagIDs()) do
		for slot = 1, API.GetNumSlots(bag) do
			local info = API.GetSlotInfo(bag, slot)
			if info and info.quality == 0 and not info.hasNoValue and not info.isLocked then
				local price = select(11, API.GetItemInfo(info.hyperlink or info.itemID)) or 0
				if price > 0 then
					table.insert(list, {
						bag = bag, slot = slot, link = info.hyperlink,
						value = price * (info.stackCount or 1),
					})
				end
			end
		end
	end
	return list
end

-- count, total value (copper)
function Junk.Summary()
	local count, value = 0, 0
	for _, item in ipairs(JunkSlots()) do
		count = count + 1
		value = value + item.value
	end
	return count, value
end

function Junk.IsSelling()
	return ticker ~= nil
end

local function StopSelling()
	if ticker then ticker:Cancel() end
	ticker = nil
	if sold and sold > 0 then
		ns.Print(("Sold %d junk item%s for %s."):format(sold, sold == 1 and "" or "s", API.FormatMoney(earned)))
	end
	queue, sold, earned = nil, nil, nil
end

local function SellNext()
	if not Junk.atMerchant or not queue or #queue == 0 then
		StopSelling()
		return
	end
	local item = table.remove(queue, 1)
	-- Make sure the slot still holds the same junk item.
	local info = API.GetSlotInfo(item.bag, item.slot)
	if info and info.hyperlink == item.link and not info.isLocked then
		API.UseContainerItem(item.bag, item.slot)
		sold = sold + 1
		earned = earned + item.value
	end
end

function Junk.Sell()
	if not Junk.atMerchant then
		ns.Print("Open a vendor to sell junk.")
		return
	end
	if ticker then return end
	queue = JunkSlots()
	if #queue == 0 then
		queue = nil
		ns.Print("No junk to sell.")
		return
	end
	sold, earned = 0, 0
	ticker = C_Timer.NewTicker(SELL_INTERVAL, function() ns.SafeCall(SellNext) end)
end

ns.On("MERCHANT_SHOW", function()
	Junk.atMerchant = true
	if ns.UpdateJunkTab then ns.UpdateJunkTab() end
end)

ns.On("MERCHANT_CLOSED", function()
	Junk.atMerchant = false
	if ticker then StopSelling() end
	if ns.UpdateJunkTab then ns.UpdateJunkTab() end
end)

ns.On("BAG_UPDATE_DELAYED", function()
	if Junk.atMerchant and ns.UpdateJunkTab then ns.UpdateJunkTab() end
end)
