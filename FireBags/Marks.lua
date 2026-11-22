-- Marks you put on items with an Alt-click (again to take it off):
--   Locked (Alt+left-click):  the item stays where it is when sorting, and
--                             can't be sold, deposited, mailed, traded or
--                             disenchanted (ItemButtons.lua guards it).
--   Junk (Alt+right-click):   the item is sold along with your junk.
--
-- Both are per character. A lock belongs to that one item (by its GUID, which
-- never changes), so it goes wherever you move the item yourself - another
-- slot, the bank - and ends when the item is gone (sold, mailed, used up).
-- Junk marks on gear (weapons, armor) work the same way: that one piece, not
-- the next copy you pick up. On anything else they're by item ID, so every
-- copy of it is sold.
local _, ns = ...
local API = ns.API

local Marks = {}
ns.Marks = Marks

local locks = {} -- [item GUID] = { bag, slot }: where it was last seen
local sell = {}  -- [itemID] = true
local sellGear = {} -- [item GUID] = { bag, slot }, like locks
local at = {}    -- [bag] = { [slot] = true }: locks by slot (rebuilt from locks)
local gearAt = {} -- the same for sellGear

local function ByPlace(into, from)
	wipe(into)
	for _, pos in pairs(from) do
		into[pos[1]] = into[pos[1]] or {}
		into[pos[1]][pos[2]] = true
	end
end

local function Rebuild()
	ByPlace(at, locks)
	ByPlace(gearAt, sellGear)
end

-- Weapons and armor.
local function IsGear(itemID)
	local classID = itemID and select(6, API.GetItemInfoInstant(itemID))
	return classID == 2 or classID == 4
end

ns.On("PLAYER_LOGIN", function()
	local key = ns.CharacterKey()
	local char = ns.db.chars[key] or {}
	ns.db.chars[key] = char
	char.locks = nil -- the first version locked slots, not items
	char.lockedItems = char.lockedItems or {}
	char.sell = char.sell or {}
	char.sellGear = char.sellGear or {}
	locks, sell, sellGear = char.lockedItems, char.sell, char.sellGear
	Rebuild()
end)

function Marks.IsLocked(bag, slot)
	local t = at[bag]
	return t ~= nil and t[slot] == true
end

-- Marked as junk. Give the slot for gear (marked one by one); cached = a
-- bank snapshot's slot (by where it was last seen).
local GUIDAt
function Marks.IsForSale(itemID, bag, slot, cached)
	if itemID == nil then return false end
	if sell[itemID] then return true end
	if not bag or next(sellGear) == nil or not IsGear(itemID) then return false end
	local guid
	if not cached then guid = GUIDAt(bag, slot) end
	if guid then return sellGear[guid] ~= nil end
	if guid == false then return false end -- (empty)
	local t = gearAt[bag] -- (can't be told: where it was last seen)
	return t ~= nil and t[slot] == true
end

---------------------------------------------------------------------------
-- Item GUIDs
---------------------------------------------------------------------------
local loc = ItemLocation and ItemLocation.CreateEmpty and ItemLocation:CreateEmpty()

-- The GUID of the item in a slot; false if the slot is empty, nil if it
-- can't be told (hidden in combat, say).
function GUIDAt(bag, slot)
	if not (loc and C_Item and C_Item.GetItemGUID) then return nil end
	loc:SetBagAndSlot(bag, slot)
	if C_Item.DoesItemExist and not C_Item.DoesItemExist(loc) then return false end
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

-- bag, slot: where it is (none for a bank snapshot's item).
function Marks.ToggleSell(itemID, link, bag, slot)
	if not itemID then return end
	link = link or "It"
	local guid = bag and IsGear(itemID) and GUIDAt(bag, slot)
	if sell[itemID] then
		sell[itemID] = nil
		ns.Print(("%s is no longer junk."):format(link))
	elseif guid and sellGear[guid] then
		sellGear[guid] = nil
		ns.Print(("%s is no longer junk."):format(link))
	elseif select(11, API.GetItemInfo(itemID)) == 0 then
		ns.Print(("%s can't be sold."):format(link))
	elseif IsGear(itemID) then
		if not guid then
			ns.Print("Mark gear in your bags, or at the bank.")
			return
		end
		sellGear[guid] = { bag, slot }
		ns.Print(("%s marked as junk: sold with your junk."):format(link))
	else
		sell[itemID] = true
		ns.Print(("%s marked as junk: sold with your junk, now and whenever you get more."):format(link))
	end
	Changed()
end

---------------------------------------------------------------------------
-- Following locked items (and gear marked as junk) as they move
---------------------------------------------------------------------------
local function Readable(bag)
	if ns.IsInventoryBag(bag) then return true end
	return ns.atBank and ns.IsBankLoaded() and ns.IsBankBag(bag)
end

-- (Not until the bags have surely loaded after logging in: a lock is only
-- dropped when its item is gone, and bags still loading look empty.)
local ready = false

local function FollowAll(marks)
	local any = false
	for guid, pos in pairs(marks) do
		local bag, slot = Find(guid)
		if bag then
			if bag ~= pos[1] or slot ~= pos[2] then
				pos[1], pos[2] = bag, slot
				any = true
			end
		elseif Readable(pos[1]) and API.GetNumSlots(pos[1]) >= pos[2] then
			-- Not in any bag, and something else (or nothing) where it was: it's gone.
			local there = GUIDAt(pos[1], pos[2])
			if there ~= nil and there ~= guid then
				marks[guid] = nil
				any = true
			end
		end
	end
	return any
end

local function Follow()
	if not ready then return end
	local a = FollowAll(locks)
	local b = FollowAll(sellGear)
	if a or b then Changed() end
end

-- Gear marked as junk by item ID (before it was by piece): the pieces you
-- have now keep the mark, later copies don't get it.
local function MoveGearMarks()
	local ids = {}
	for itemID in pairs(sell) do
		if IsGear(itemID) then ids[itemID] = true end
	end
	if next(ids) == nil then return end
	for _, bag in ipairs(ns.GetInventoryBagIDs()) do
		for slot = 1, API.GetNumSlots(bag) do
			local info = API.GetSlotInfo(bag, slot)
			local guid = info and ids[info.itemID] and GUIDAt(bag, slot)
			if guid then sellGear[guid] = { bag, slot } end
		end
	end
	for itemID in pairs(ids) do sell[itemID] = nil end
	Changed()
end

ns.On("PLAYER_LOGIN", function()
	C_Timer.After(5, function()
		ready = true
		ns.SafeCall(MoveGearMarks)
		Follow()
	end)
end)
ns.On("BAG_UPDATE_DELAYED", Follow)
ns.On("BANKFRAME_OPENED", function() C_Timer.After(0.5, Follow) end)
