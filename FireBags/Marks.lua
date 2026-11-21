-- Marks you put on items with an Alt-click (again to take it off):
--   Locked (Alt+left-click):  the item stays where it is when sorting.
--   Junk (Alt+right-click):   the item is sold along with your junk.
--
-- Both are per character. A lock belongs to that one item (by its GUID, which
-- never changes), so it goes wherever you move the item yourself - another
-- slot, the bank - and ends when the item is gone (sold, mailed, used up).
-- For-sale marks are by item ID, so every copy of it is sold.
local _, ns = ...
local API = ns.API

local Marks = {}
ns.Marks = Marks

local locks = {} -- [item GUID] = { bag, slot }: where it was last seen
local sell = {}  -- [itemID] = true
local at = {}    -- [bag] = { [slot] = true }: the same, by slot (rebuilt from locks)

local function Rebuild()
	wipe(at)
	for _, pos in pairs(locks) do
		at[pos[1]] = at[pos[1]] or {}
		at[pos[1]][pos[2]] = true
	end
end

ns.On("PLAYER_LOGIN", function()
	local key = ns.CharacterKey()
	local char = ns.db.chars[key] or {}
	ns.db.chars[key] = char
	char.locks = nil -- the first version locked slots, not items
	char.lockedItems = char.lockedItems or {}
	char.sell = char.sell or {}
	locks, sell = char.lockedItems, char.sell
	Rebuild()
end)

function Marks.IsLocked(bag, slot)
	local t = at[bag]
	return t ~= nil and t[slot] == true
end

function Marks.IsForSale(itemID)
	return itemID ~= nil and sell[itemID] == true
end

---------------------------------------------------------------------------
-- Item GUIDs
---------------------------------------------------------------------------
local loc = ItemLocation and ItemLocation.CreateEmpty and ItemLocation:CreateEmpty()

-- The GUID of the item in a slot, or nil.
local function GUIDAt(bag, slot)
	if not (loc and C_Item and C_Item.GetItemGUID) then return nil end
	loc:SetBagAndSlot(bag, slot)
	if C_Item.DoesItemExist and not C_Item.DoesItemExist(loc) then return nil end
	local ok, guid = pcall(C_Item.GetItemGUID, loc)
	if ok and type(guid) == "string" and not (issecretvalue and issecretvalue(guid)) then return guid end
end

-- Where an item is now (bag, slot), or nil if not in a bag you can see.
local function Find(guid)
	if not (C_Item and C_Item.GetItemLocation) then return nil end
	local ok, where = pcall(C_Item.GetItemLocation, guid)
	if ok and where and where.IsBagAndSlot and where:IsBagAndSlot() then return where:GetBagAndSlot() end
end

---------------------------------------------------------------------------
-- Alt-clicking an item (ItemButtons.lua): left locks it, right marks it as
-- junk. A click with a modifier never picks up or uses a bag item, so these
-- can't move, sell or drop anything by accident.
---------------------------------------------------------------------------
local function Changed()
	Rebuild()
	FireBags.UpdateButtons()
	if ns.UpdateJunkTab then ns.UpdateJunkTab() end
end

function Marks.ToggleLock(bag, slot)
	local guid = GUIDAt(bag, slot)
	if not guid then return end
	local link = API.GetSlotInfo(bag, slot)
	link = link and link.hyperlink or "it"
	if locks[guid] then
		locks[guid] = nil
		ns.Print(("Unlocked %s."):format(link))
	else
		locks[guid] = { bag, slot }
		ns.Print(("Locked %s: sorting leaves it where it is."):format(link))
	end
	Changed()
end

function Marks.ToggleSell(itemID, link)
	if not itemID then return end
	link = link or "It"
	if sell[itemID] then
		sell[itemID] = nil
		ns.Print(("%s is no longer junk."):format(link))
	elseif select(11, API.GetItemInfo(itemID)) == 0 then
		ns.Print(("%s can't be sold."):format(link))
	else
		sell[itemID] = true
		ns.Print(("%s marked as junk: sold with your junk, now and whenever you get more."):format(link))
	end
	Changed()
end

---------------------------------------------------------------------------
-- Following locked items as they move
---------------------------------------------------------------------------
local function Readable(bag)
	if ns.IsInventoryBag(bag) then return true end
	return ns.atBank and ns.IsBankLoaded() and ns.IsBankBag(bag)
end

local function Follow()
	local any = false
	for guid, pos in pairs(locks) do
		local bag, slot = Find(guid)
		if bag then
			if bag ~= pos[1] or slot ~= pos[2] then
				pos[1], pos[2] = bag, slot
				any = true
			end
		elseif Readable(pos[1]) and API.GetNumSlots(pos[1]) >= pos[2] and GUIDAt(pos[1], pos[2]) ~= guid then
			-- Not in any bag, and not where it was: it's gone.
			locks[guid] = nil
			any = true
		end
	end
	if any then Changed() end
end

ns.On("BAG_UPDATE_DELAYED", Follow)
ns.On("BANKFRAME_OPENED", function() C_Timer.After(0.5, Follow) end)
