-- Thin wrappers over the container/item/bank API.
-- The Forever client is built on the modern engine (C_Container), but we fall
-- back to the old global functions in case some calls are missing.
local _, ns = ...

local API = {}
ns.API = API

local C = C_Container
local CItem = C_Item

function API.GetNumSlots(bag)
	if C and C.GetContainerNumSlots then
		return C.GetContainerNumSlots(bag) or 0
	end
	return GetContainerNumSlots and GetContainerNumSlots(bag) or 0
end

-- Returns freeSlots, bagFamily (0 = normal bag)
function API.GetFreeSlots(bag)
	if C and C.GetContainerNumFreeSlots then
		return C.GetContainerNumFreeSlots(bag)
	end
	return GetContainerNumFreeSlots(bag)
end

-- Returns a table shaped like C_Container.GetContainerItemInfo, or nil for an empty slot.
function API.GetSlotInfo(bag, slot)
	if C and C.GetContainerItemInfo then
		return C.GetContainerItemInfo(bag, slot)
	end
	local texture, count, locked, quality, readable, lootable, link, isFiltered, noValue, itemID =
		GetContainerItemInfo(bag, slot)
	if not texture then return nil end
	return {
		iconFileID = texture,
		stackCount = count,
		isLocked = locked,
		quality = quality,
		isReadable = readable,
		hasLoot = lootable,
		hyperlink = link,
		isFiltered = isFiltered,
		hasNoValue = noValue,
		itemID = itemID,
	}
end

function API.GetCooldown(bag, slot)
	if C and C.GetContainerItemCooldown then
		return C.GetContainerItemCooldown(bag, slot)
	end
	return GetContainerItemCooldown(bag, slot)
end

function API.Pickup(bag, slot)
	if C and C.PickupContainerItem then
		return C.PickupContainerItem(bag, slot)
	end
	return PickupContainerItem(bag, slot)
end

-- name, link, quality, itemLevel, reqLevel, type, subType, maxStack, equipLoc,
-- texture, sellPrice, classID, subClassID
function API.GetItemInfo(item)
	if CItem and CItem.GetItemInfo then
		return CItem.GetItemInfo(item)
	end
	return GetItemInfo(item)
end

-- itemID, type, subType, equipLoc, icon, classID, subClassID — works without
-- the item being cached.
function API.GetItemInfoInstant(item)
	local fn = (CItem and CItem.GetItemInfoInstant) or GetItemInfoInstant
	if fn then return fn(item) end
end

-- Uses (or, at a vendor, sells) the item in a bag slot.
function API.UseContainerItem(bag, slot)
	if C and C.UseContainerItem then
		return C.UseContainerItem(bag, slot)
	end
	return UseContainerItem(bag, slot)
end

-- isQuestItem, questID, isActive (nil when the client has no quest info)
function API.GetQuestInfo(bag, slot)
	if C and C.GetContainerItemQuestInfo then
		local info = C.GetContainerItemQuestInfo(bag, slot)
		if info then return info.isQuestItem, info.questID, info.isActive end
		return nil
	end
	if GetContainerItemQuestInfo then
		return GetContainerItemQuestInfo(bag, slot)
	end
end

-- Bit flags of the special bag types an item fits in (0 = none).
function API.GetItemFamily(item)
	local fn = (CItem and CItem.GetItemFamily) or GetItemFamily
	if not fn then return 0 end
	local ok, family = pcall(fn, item)
	return ok and family or 0
end

---------------------------------------------------------------------------
-- Sorting
---------------------------------------------------------------------------
function API.HasBlizzardSort()
	return (C and C.SortBags ~= nil) or SortBags ~= nil
end

function API.BlizzardSort()
	if C and C.SortBags then C.SortBags() elseif SortBags then SortBags() end
end

-- Tab-based banks sort with C_Container.SortBank(bankType); older ones with SortBankBags.
function API.HasBlizzardBankSort()
	return (C and (C.SortBank or C.SortBankBags) ~= nil) or SortBankBags ~= nil
end

function API.BlizzardBankSort()
	if C and C.SortBank and Enum.BankType then
		C.SortBank(Enum.BankType.Character)
	elseif C and C.SortBankBags then
		C.SortBankBags()
	elseif SortBankBags then
		SortBankBags()
	end
end

---------------------------------------------------------------------------
-- Bank
---------------------------------------------------------------------------
function API.CloseBank()
	if C_Bank and C_Bank.CloseBankFrame then
		C_Bank.CloseBankFrame()
	elseif CloseBankFrame then
		CloseBankFrame()
	elseif C_PlayerInteractionManager and Enum.PlayerInteractionType then
		C_PlayerInteractionManager.ClearInteraction(Enum.PlayerInteractionType.Banker)
	end
end

---------------------------------------------------------------------------
-- Money
---------------------------------------------------------------------------
local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"

-- "12g 34s 56c" with coin icons. Modern clients moved GetCoinTextureString
-- into C_CurrencyInfo, so try both and fall back to building it ourselves.
function API.FormatMoney(copper)
	copper = copper or 0
	if C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString then
		return C_CurrencyInfo.GetCoinTextureString(copper)
	end
	if GetCoinTextureString then
		return GetCoinTextureString(copper)
	end
	local gold = math.floor(copper / 10000)
	local silver = math.floor(copper / 100) % 100
	local cop = copper % 100
	local parts = {}
	if gold > 0 then table.insert(parts, (BreakUpLargeNumbers and BreakUpLargeNumbers(gold) or gold) .. GOLD_ICON) end
	if silver > 0 or gold > 0 then table.insert(parts, silver .. SILVER_ICON) end
	table.insert(parts, cop .. COPPER_ICON)
	return table.concat(parts, " ")
end

---------------------------------------------------------------------------
-- Misc
---------------------------------------------------------------------------
-- true / false when the client can tell us, nil when it can't.
function API.TemplateExists(name)
	if C_XMLUtil and C_XMLUtil.GetTemplateInfo then
		local ok, info = pcall(C_XMLUtil.GetTemplateInfo, name)
		return ok and info ~= nil
	end
	return nil
end

function API.AtlasExists(atlas)
	return atlas and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) ~= nil
end
