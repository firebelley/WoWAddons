-- Sorting.
--
-- FireBags' own sorter works one move at a time, waiting for the server to
-- confirm each move before making the next. Each section (main bags, quiver,
-- soul bag, herb bag, reagent bag, each bank tab...) is sorted within itself,
-- with these rules for special bags:
--   * Items already in a special bag never leave it.
--   * Items in your main bags that the special bag accepts top up matching
--     partial stacks in it, then fill its empty slots, rarest first.
--   * When a special bag is full, it's only sorted within itself.
--
-- By default (sortmode auto) Blizzard's built-in sort is used whenever the
-- client has one, because it's instant; it doesn't follow the special bag
-- rules above. FireBags' sorter runs when picked in the options ("Sort with"), or when the
-- client has no built-in sort.
local _, ns = ...
local API = ns.API

local STEP_INTERVAL = 0.05 -- seconds between move attempts
local MAX_MOVES = 1500     -- safety cap
local MAX_WAIT = 5         -- give up if items stay locked this long

local HEARTHSTONE = 6948

-- Lower = earlier. Keyed by item classID.
local CLASS_ORDER = {
	[0] = 1,   -- Consumable
	[12] = 2,  -- Quest
	[2] = 3,   -- Weapon
	[4] = 4,   -- Armor
	[1] = 5,   -- Container
	[11] = 6,  -- Quiver
	[6] = 7,   -- Projectile
	[7] = 8,   -- Trade Goods
	[5] = 9,   -- Reagent
	[3] = 10,  -- Gem
	[9] = 11,  -- Recipe
	[13] = 12, -- Key
	[15] = 13, -- Miscellaneous
}

local function MakeRecord(info)
	local link = info.hyperlink
	local name, _, quality, ilvl, _, _, _, maxStack, _, _, _, classID, subClassID,
		_, _, _, isCraftingReagent = API.GetItemInfo(link)

	-- What the reagent bag accepts: crafting reagents. Clients that don't report
	-- that flag get a best guess from the item class (Trade Goods / Reagent).
	local isReagent
	if isCraftingReagent ~= nil then
		isReagent = isCraftingReagent and true or false
	else
		isReagent = classID == 7 or classID == 5
	end

	-- Which special bag types the item fits (bit flags, same as bag families).
	-- Bags themselves report the type they hold, so they never count.
	local isContainer = classID == 1 or classID == 11
	local family = not isContainer and API.GetItemFamily(link) or 0

	return {
		link = link,
		id = info.itemID or 0,
		count = info.stackCount or 1,
		quality = info.quality or quality or 1,
		name = name or link or "",
		ilvl = ilvl or 0,
		maxStack = maxStack,
		classID = classID,
		subClassID = subClassID or 0,
		isReagent = isReagent and not isContainer,
		family = family or 0,
	}
end

local bit_band = bit and bit.band

-- Does this special bag group accept this item?
local function Accepts(group, record)
	if group.family == "reagent" then return record.isReagent end
	if type(group.family) == "number" and group.family ~= 0 and bit_band then
		return bit_band(record.family, group.family) ~= 0
	end
	return false
end

local function Rank(r)
	if r.id == HEARTHSTONE then return 0 end
	if r.quality == 0 then return 100 end -- junk goes last
	return CLASS_ORDER[r.classID] or 50
end

-- Strict total order on records; ties only for interchangeable items.
local function Compare(a, b)
	local ra, rb = Rank(a), Rank(b)
	if ra ~= rb then return ra < rb end
	if a.subClassID ~= b.subClassID then return a.subClassID < b.subClassID end
	if a.quality ~= b.quality then return a.quality > b.quality end
	if a.ilvl ~= b.ilvl then return a.ilvl > b.ilvl end
	if a.name ~= b.name then return a.name < b.name end
	if a.id ~= b.id then return a.id < b.id end
	if a.count ~= b.count then return a.count > b.count end
	return a.link < b.link
end

-- Rarest first: quality, then item level, then the normal sort order.
local function CompareRarity(a, b)
	if a.quality ~= b.quality then return a.quality > b.quality end
	if a.ilvl ~= b.ilvl then return a.ilvl > b.ilvl end
	return Compare(a, b)
end

local function Same(a, b)
	if not a or not b then return not a and not b end
	return a.link == b.link and a.count == b.count
end

local function SlotKey(s) return s[1] .. ":" .. s[2] end

-- Each group is { key = section key, slots = { {bag, slot}, ... } }.
local function BuildGroups(sections)
	local groups = {}
	for _, section in ipairs(sections) do
		if section.key ~= "keyring" then
			local slots = {}
			for _, entry in ipairs(section.bags) do
				for slot = 1, entry.numSlots do
					table.insert(slots, { entry.bag, slot })
				end
			end
			table.insert(groups, { key = section.key, family = section.family, slots = slots })
		end
	end
	return groups
end

local function Move(from, to)
	API.Pickup(from[1], from[2])
	API.Pickup(to[1], to[2])
	-- Merging into a stack can leave a remainder on the cursor; send it home.
	if CursorHasItem() then ClearCursor() end
end

-- Reads every slot of every group. Returns nil if anything is still locked or
-- not loaded yet (so the caller waits).
local function ReadGroups(groups)
	for _, group in ipairs(groups) do
		local items = {}
		for i, s in ipairs(group.slots) do
			local info = API.GetSlotInfo(s[1], s[2])
			if info then
				if info.isLocked or not info.hyperlink then return nil end
				items[i] = MakeRecord(info)
			else
				items[i] = false
			end
		end
		group.items = items
	end
	return true
end

-- Combine partial stacks of the same item within a group.
local function StackWithin(group)
	local partial = {}
	for i, r in ipairs(group.items) do
		if r and r.maxStack and r.maxStack > 1 and r.count < r.maxStack then
			local first = partial[r.link]
			if first then
				Move(group.slots[i], group.slots[first])
				return true
			end
			partial[r.link] = i
		end
	end
	return false
end

-- Move items from the main bags into a special bag that accepts them. Only
-- ever moves items in, and only into space that's already there.
local function FillSpecialBag(state, main, special)
	-- Top up partial stacks already in the special bag.
	for si, s in ipairs(special.items) do
		if s and s.maxStack and s.count < s.maxStack then
			for mi, m in ipairs(main.items) do
				if m and m.link == s.link and not state.failed[m.link] then
					state:Track(main.slots[mi], m)
					Move(main.slots[mi], special.slots[si])
					return true
				end
			end
		end
	end

	-- Fill empty slots, rarest accepted item first.
	local empty
	for si, s in ipairs(special.items) do
		if not s then empty = si break end
	end
	if not empty then return false end

	local best, bestIndex
	for mi, m in ipairs(main.items) do
		if m and Accepts(special, m) and not state.failed[m.link] and (not best or CompareRarity(m, best)) then
			best, bestIndex = m, mi
		end
	end
	if not best then return false end

	state:Track(main.slots[bestIndex], best)
	Move(main.slots[bestIndex], special.slots[empty])
	return true
end

-- Put the first out-of-place slot of a group right.
local function OrderWithin(group)
	local desired = {}
	for _, r in ipairs(group.items) do
		if r then table.insert(desired, r) end
	end
	table.sort(desired, Compare)

	local items, slots = group.items, group.slots
	for i = 1, #slots do
		local want = desired[i] or false
		if not Same(want, items[i]) then
			if not want then return "error" end
			for j = i + 1, #slots do
				if Same(items[j], want) then
					Move(slots[j], slots[i])
					return "moved"
				end
			end
			return "error"
		end
	end
	return nil
end

-- Returns "wait", "moved", "done" or "error".
local function Step(state)
	if CursorHasItem() then return "wait" end
	local groups = state.groups
	if not ReadGroups(groups) then return "wait" end

	-- If the last move into a special bag didn't happen (the bag refused the
	-- item), don't try that item again this sort.
	state:CheckLastMove()

	for _, group in ipairs(groups) do
		if StackWithin(group) then return "moved" end
	end

	local main
	for _, group in ipairs(groups) do
		if group.key == "main" then main = group end
	end
	if main then
		for _, group in ipairs(groups) do
			if group ~= main and group.family ~= 0 and FillSpecialBag(state, main, group) then
				return "moved"
			end
		end
	end

	for _, group in ipairs(groups) do
		local result = OrderWithin(group)
		if result then return result end
	end
	return "done"
end

---------------------------------------------------------------------------
-- Runner
---------------------------------------------------------------------------
local sorter = CreateFrame("Frame")
sorter:Hide()

-- Remember a cross-bag move so we can tell if it was refused.
function sorter:Track(from, record)
	self.lastMove = { bag = from[1], slot = from[2], link = record.link, count = record.count }
end

function sorter:CheckLastMove()
	local last = self.lastMove
	if not last then return end
	self.lastMove = nil
	local info = API.GetSlotInfo(last.bag, last.slot)
	if info and info.hyperlink == last.link and info.stackCount == last.count then
		self.failed[last.link] = true
	end
end

local function StopSorting(message)
	sorter:Hide()
	sorter.groups = nil
	if message then ns.Print(message) end
	for _, w in ipairs(ns.windows) do w:RequestRefresh() end
end

sorter:SetScript("OnUpdate", function(self, elapsed)
	self.timer = self.timer + elapsed
	if self.timer < STEP_INTERVAL then return end
	self.timer = 0

	if InCombatLockdown() then
		StopSorting("Sorting stopped: entered combat.")
		return
	end
	if self.kind == "bank" and not ns.atBank then
		StopSorting("Sorting stopped: left the bank.")
		return
	end

	local ok, result = ns.SafeCall(Step, self)
	if not ok then
		StopSorting("Sorting stopped: something went wrong.")
		return
	end

	if result == "wait" then
		self.waited = self.waited + STEP_INTERVAL
		if self.waited > MAX_WAIT then StopSorting("Sorting stopped: items stayed locked.") end
	elseif result == "moved" then
		self.waited = 0
		self.moves = self.moves + 1
		if self.moves >= MAX_MOVES then StopSorting("Sorting stopped: too many moves.") end
	elseif result == "done" then
		StopSorting()
	else
		StopSorting("Sorting stopped: bags changed unexpectedly. Try again.")
	end
end)

function ns.IsSorting()
	return sorter:IsShown()
end

-- kind: "inventory" (default) or "bank"
function ns.SortBags(kind)
	kind = kind or "inventory"
	if InCombatLockdown() then
		ns.Print("Can't sort in combat.")
		return
	end
	if kind == "bank" and not ns.atBank then
		ns.Print("Visit a banker to sort your bank.")
		return
	end
	if sorter:IsShown() then return end

	local isBank = kind == "bank"
	local sections = isBank and ns.GetLiveBankSections() or ns.GetInventorySections()

	local hasBlizzard = isBank and API.HasBlizzardBankSort() or (not isBank and API.HasBlizzardSort())
	local mode = ns.db.sortMode
	local useBlizzard = hasBlizzard and mode ~= "custom"
	if useBlizzard then
		if isBank then API.BlizzardBankSort() else API.BlizzardSort() end
		return
	end
	if mode == "blizzard" then
		ns.Print("This client has no built-in sort for that; using FireBags' sorter.")
	end

	sorter.kind = kind
	sorter.groups = BuildGroups(sections)
	sorter.failed = {}
	sorter.lastMove = nil
	sorter.timer = STEP_INTERVAL
	sorter.waited = 0
	sorter.moves = 0
	sorter:Show()
end
