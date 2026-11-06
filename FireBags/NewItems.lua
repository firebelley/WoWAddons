-- Tracks which bag slots hold newly gained items, for the new-item glow.
--
-- An item counts as new when your total of it goes up (looted, bought, mailed,
-- traded, taken from the bank...). Moving items around, including sorting,
-- doesn't make them new. Glows clear when you hover the item or close your bags.
local _, ns = ...
local API = ns.API

local NI = {}
ns.NewItems = NI

local baseline        -- itemID -> total count; nil until the first full scan
local lastSlots = {}  -- "bag:slot" -> itemID from the previous scan
local newSlots = {}   -- "bag:slot" -> itemID currently marked new

local function SlotKey(bag, slot) return bag .. ":" .. slot end

local function Scan()
	local totals, slots = {}, {}
	for _, section in ipairs(ns.GetInventorySections()) do
		for _, entry in ipairs(section.bags) do
			for slot = 1, entry.numSlots do
				local info = API.GetSlotInfo(entry.bag, slot)
				if info and info.itemID then
					totals[info.itemID] = (totals[info.itemID] or 0) + (info.stackCount or 1)
					slots[SlotKey(entry.bag, slot)] = info.itemID
				end
			end
		end
	end
	return totals, slots
end

function NI.Update()
	if not ns.db then return end
	local totals, slots = Scan()
	if not baseline then
		-- Not ready yet (we wait a moment after login so the bags have loaded).
		return
	end

	-- Items that moved (e.g. by sorting) keep their glow at the new slot.
	for key, itemID in pairs(newSlots) do
		if slots[key] ~= itemID then
			newSlots[key] = nil
			for otherKey, otherID in pairs(slots) do
				if otherID == itemID and lastSlots[otherKey] ~= itemID and not newSlots[otherKey] then
					newSlots[otherKey] = itemID
					break
				end
			end
		end
	end

	-- Totals that went up: mark the slots holding that item which changed.
	for itemID, count in pairs(totals) do
		if count > (baseline[itemID] or 0) then
			for key, id in pairs(slots) do
				if id == itemID and lastSlots[key] ~= itemID then
					newSlots[key] = itemID
				end
			end
			-- If it only grew an existing stack, mark that stack.
			local marked = false
			for _, id in pairs(newSlots) do
				if id == itemID then marked = true break end
			end
			if not marked then
				for key, id in pairs(slots) do
					if id == itemID then newSlots[key] = itemID break end
				end
			end
		end
	end

	baseline = totals
	lastSlots = slots
end

function NI.IsNew(bag, slot)
	return newSlots[SlotKey(bag, slot)] ~= nil
end

function NI.Clear(bag, slot)
	newSlots[SlotKey(bag, slot)] = nil
end

function NI.ClearAll()
	wipe(newSlots)
end

local function TakeBaseline()
	baseline, lastSlots = Scan()
end

ns.On("PLAYER_LOGIN", function()
	-- Give the client a few seconds to load bag contents so everything you
	-- logged in with doesn't count as new.
	C_Timer.After(3, TakeBaseline)
end)

ns.On("BAG_UPDATE_DELAYED", function()
	NI.Update()
end)
