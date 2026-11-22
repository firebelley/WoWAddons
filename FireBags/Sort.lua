-- Sorting.
--
-- FireBags' own sorter sends every move that doesn't clash at once, then
-- waits for the server before the next round (the order it sorts in is
-- below, by SPECIAL). Each section (main bags, quiver,
-- soul bag, herb bag, reagent bag, each bank tab...) is sorted within itself,
-- with these rules for special bags:
--   * Items already in a special bag never leave it.
--   * Items in your main bags that the special bag accepts top up matching
--     partial stacks in it, then fill its empty slots, rarest first.
--   * When a special bag is full, it's only sorted within itself.
-- Locked items (Marks.lua) stay put.
--
-- Blizzard's own sort is never used: it can't leave locked items alone, and
-- one sorter means the same order every time.
local _, ns = ...
local API = ns.API

local STEP_INTERVAL = 0.02 -- at least this long between looks at the bags
local IDLE_STEP = 0.25     -- ...and a look this often even with no bag events
local MAX_MOVES = 1500     -- safety cap (passes)
local MAX_WAIT = 5         -- give up if items stay locked this long
local STALLS = 3           -- give up after this many rounds of moves that changed nothing

-- The order (FireBags' own sorter), after the one TrinityCore worked out for
-- Blizzard's sort (github.com/TrinityCore/TrinityCore/pull/29947): items go
-- in groups, in this order -
local SPECIAL = { [6948] = true, [110560] = true, [140192] = true, [141605] = true } -- hearthstones, whistle
local GROUP_SPECIAL, GROUP_CONSUMABLE, GROUP_WEAPON = 0, 1, 2
local GROUP_ACCESSORY, GROUP_BODY, GROUP_OTHER = 13, 14, 15
-- Armor by where it's worn (3-14); armor not listed goes with "other".
local ARMOR_GROUP = {
	INVTYPE_SHIELD = 3, INVTYPE_HOLDABLE = 3, -- off-hands with shields (your bank: Blizzard's does)
	INVTYPE_HEAD = 4, INVTYPE_SHOULDER = 5, INVTYPE_CHEST = 6, INVTYPE_ROBE = 6,
	INVTYPE_WRIST = 7, INVTYPE_HAND = 8, INVTYPE_WAIST = 9, INVTYPE_LEGS = 10,
	INVTYPE_FEET = 11, INVTYPE_CLOAK = 12,
	INVTYPE_NECK = GROUP_ACCESSORY, INVTYPE_FINGER = GROUP_ACCESSORY, INVTYPE_TRINKET = GROUP_ACCESSORY,
	INVTYPE_BODY = GROUP_BODY, INVTYPE_TABARD = GROUP_BODY,
}
-- - and within a group:
--   special:            item ID, lowest first
--   consumables:        subtype, highest first; then item ID, lowest first
--   weapons and armor:  item level, highest first
--   jewelry, shirts and tabards: item ID, highest first
--   other:              item class, lowest first (containers, gems, trade goods, recipes, quest items...);
--                       then subtype, highest first; then item level, highest first
--                       (TrinityCore's has item ID here; Blizzard's sort of your bank went by item level)
-- Ties: item ID, then the bigger stack first. Junk (grey, or marked as junk) goes at the end
-- instead, filling from the last slot back.

local function MakeRecord(info)
	local link = info.hyperlink
	local name, _, quality, ilvl, _, _, _, maxStack, equipLoc, _, _, classID, subClassID,
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
		classID = classID or 99,
		subClassID = subClassID or 0,
		equipLoc = equipLoc,
		isReagent = isReagent and not isContainer,
		family = family or 0,
		loaded = name ~= nil,
	}
end

-- Records are never changed once made, so one per item and stack size does
-- for the whole sort (the bags are read again after every round of moves):
-- [link] = { [count] = record }. Items the game hasn't loaded yet aren't kept.
local records = {}

local function Record(info)
	local link, count = info.hyperlink, info.stackCount or 1
	local byCount = records[link]
	local r = byCount and byCount[count]
	if r then return r end
	r = MakeRecord(info)
	if r.loaded then
		if not byCount then byCount = {} records[link] = byCount end
		byCount[count] = r
	end
	return r
end

local bit_band = bit and bit.band

-- Items a special bag refused although the game said they fit (by bag
-- family; saved, so each is only tried once): [family] = { [itemID] = true }.
local function Refused(family)
	local all = ns.db.refused or {}
	ns.db.refused = all
	all[family] = all[family] or {}
	return all[family]
end

-- Does this special bag group accept this item?
local function Accepts(group, record)
	if Refused(group.family)[record.id] then return false end
	if group.family == "reagent" then return record.isReagent end
	if type(group.family) == "number" and group.family ~= 0 and bit_band then
		return bit_band(record.family, group.family) ~= 0
	end
	return false
end

local function FindGroup(r)
	if SPECIAL[r.id] then return GROUP_SPECIAL end
	if r.classID == 0 then return GROUP_CONSUMABLE end
	if r.classID == 2 then return GROUP_WEAPON end
	if r.classID == 4 then return ARMOR_GROUP[r.equipLoc] or GROUP_OTHER end
	return GROUP_OTHER
end

local function Group(r)
	local g = r.group
	if not g then
		g = FindGroup(r)
		r.group = g
	end
	return g
end

-- Strict total order on records; ties only for interchangeable items.
local function Compare(a, b)
	local ga, gb = Group(a), Group(b)
	if ga ~= gb then return ga < gb end
	if ga == GROUP_CONSUMABLE then
		if a.subClassID ~= b.subClassID then return a.subClassID > b.subClassID end
	elseif ga == GROUP_ACCESSORY or ga == GROUP_BODY then
		if a.id ~= b.id then return a.id > b.id end
	elseif ga == GROUP_OTHER then
		if a.classID ~= b.classID then return a.classID < b.classID end
		if a.subClassID ~= b.subClassID then return a.subClassID > b.subClassID end
		if a.ilvl ~= b.ilvl then return a.ilvl > b.ilvl end
	elseif ga ~= GROUP_SPECIAL then -- weapons, armor
		if a.ilvl ~= b.ilvl then return a.ilvl > b.ilvl end
	end
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
-- Locked slots (Marks.lua) are left out, so nothing moves into or out of them.
local function BuildGroups(sections)
	local groups = {}
	for _, section in ipairs(sections) do
		if section.key ~= "keyring" then
			local slots = {}
			for _, entry in ipairs(section.bags) do
				for slot = 1, entry.numSlots do
					if not ns.Marks.IsLocked(entry.bag, slot) then
						table.insert(slots, { entry.bag, slot })
					end
				end
			end
			table.insert(groups, { key = section.key, family = section.family, slots = slots })
		end
	end
	return groups
end

-- Moves are queued, and go out a few each frame (the runner, below): picking
-- an item up and putting it down is slow in itself (the game does a lot each
-- time the cursor changes, sound or not: about 2 ms to pick up and 1 to put
-- down), so moves go out until a couple of ms of a frame are used - mostly
-- one a frame - and the rest next frame. (Each round's moves share no slot,
-- so the order they go in doesn't matter.)
local SEND_BUDGET = 2 -- ms of moves per frame (at least one move goes)
local queueFrom, queueTo, queued, sent = {}, {}, 0, 0

local function Move(from, to)
	queued = queued + 1
	queueFrom[queued], queueTo[queued] = from, to
end

local function SendQueued() -- returns how many went
	local started = debugprofilestop()
	local count = 0
	while sent < queued do
		sent = sent + 1
		count = count + 1
		local from, to = queueFrom[sent], queueTo[sent]
		local t = ns.timings and debugprofilestop()
		API.Pickup(from[1], from[2])
		if t then ns.Timed("  picking up", t) t = debugprofilestop() end
		API.Pickup(to[1], to[2])
		if t then ns.Timed("  putting down", t) end
		-- Merging into a stack can leave a remainder on the cursor; send it home.
		if CursorHasItem() then ClearCursor() end
		if debugprofilestop() - started >= SEND_BUDGET then break end
	end
	if sent >= queued then queued, sent = 0, 0 end
	return count
end

local function HasQueued() return queued > 0 end

local function ClearQueue()
	queued, sent = 0, 0
end

-- Reads every slot of every group. Returns nil if anything is still locked or
-- not loaded yet (so the caller waits); else whether anything changed since
-- the last full read.
local function ReadGroups(groups)
	for _, group in ipairs(groups) do
		local items = group.items or {}
		group.items = items
		for i, s in ipairs(group.slots) do
			local info = API.GetSlotInfo(s[1], s[2])
			if info then
				if info.isLocked or not info.hyperlink then return nil end
				items[i] = Record(info)
			else
				items[i] = false
			end
		end
	end
	local changed = false
	for _, group in ipairs(groups) do
		local seen = group.seen or {}
		group.seen = seen
		for i, r in ipairs(group.items) do
			if seen[i] ~= r then
				seen[i] = r
				changed = true
			end
		end
	end
	return true, changed
end

-- Combine partial stacks of the same item within a group: every pair at
-- once (each slot in one move only).
local function StackWithin(group)
	local partial, moved = {}, false
	for i, r in ipairs(group.items) do
		if r and r.maxStack and r.maxStack > 1 and r.count < r.maxStack then
			local first = partial[r.link]
			if first then
				Move(group.slots[i], group.slots[first])
				partial[r.link] = nil
				moved = true
			else
				partial[r.link] = i
			end
		end
	end
	return moved
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

	state:Track(main.slots[bestIndex], best, special, special.slots[empty])
	Move(main.slots[bestIndex], special.slots[empty])
	return true
end

-- Where each item of a group should end up: [slot index] = record, or false
-- for empty. Sorted items from the first slot on, junk from the last slot back.
local function Layout(items, n)
	local keep, junk = {}, {}
	for _, r in ipairs(items) do
		if r then
			local isJunk = r.quality == 0 or ns.Marks.IsForSale(r.id) -- (grey, or marked as junk)
			table.insert(isJunk and junk or keep, r)
		end
	end
	table.sort(keep, Compare)
	table.sort(junk, Compare)
	local desired = {}
	for i = 1, n do desired[i] = keep[i] or false end
	for k, r in ipairs(junk) do desired[n + 1 - k] = r end
	return desired
end

-- The fallback when the two-round plan (OrderWithin, below) can't be used:
-- put out-of-place slots of a group right with every swap that doesn't touch
-- a slot already used this pass, all sent at once. The planned swaps are
-- played out on `items` as they're made, so each next one is planned on how
-- the bags will be.
local function OrderGreedy(group, desired)
	local items, slots = group.items, group.slots

	-- A slot whose item can go to slot i: holding `want` (if exact, the same
	-- stack size too) and not already holding what belongs in its own slot.
	local used = {}
	local function From(i, want, exact)
		local busy
		for j = 1, #slots do
			local r = items[j]
			if j ~= i and r and r.link == want.link and (not exact or r.count == want.count)
				and not Same(r, desired[j]) then
				if not used[j] then return j end
				busy = true -- it's there, but already moving this pass
			end
		end
		return nil, busy
	end

	local moved, stuck = false, false
	for i = 1, #slots do
		local want, have = desired[i], items[i]
		if want and not used[i] and not Same(want, have) then
			if have and have.link == want.link then
				-- The same item, a smaller stack than belongs here: drop a bigger
				-- one on it - the game tops this one up and leaves the rest
				-- behind, which swaps the sizes. Alone in its pass (stacks merge
				-- rather than swap, so the next is planned on what happened).
				-- A bigger stack than belongs here is fixed from the other end.
				if have.count < want.count then
					local j = From(i, want, true)
					if j then
						if moved then return "moved" end
						Move(slots[j], slots[i])
						return "moved"
					end
				end
			else
				local j, busy = From(i, want, true)
				if not j and not busy then j, busy = From(i, want, false) end
				if j then
					Move(slots[j], slots[i])
					items[i], items[j] = items[j], items[i]
					used[i], used[j] = true, true
					moved = true
				elseif not busy then
					stuck = true
				end
			end
			-- (A slot that should be empty is cleared when its item's own slot
			-- is put right.)
		end
	end
	if moved then return "moved" end
	for i = 1, #slots do
		if not Same(desired[i], items[i]) then return "error" end
	end
	return stuck and "error" or nil
end

-- Which slot's item goes to each slot: src[i] = j, slot j's item goes to i.
-- Items go by exact match (the same item and stack size), and ones already
-- right stay put.
local function Assign(items, desired, n)
	local src, taken = {}, {}
	for i = 1, n do
		if Same(items[i], desired[i]) then src[i], taken[i] = i, true end
	end
	local pool = {} -- [item:count, or "" for empty] = { slot, ... } still to place
	for j = 1, n do
		if not taken[j] then
			local r = items[j]
			local key = r and (r.link .. ":" .. r.count) or ""
			pool[key] = pool[key] or {}
			table.insert(pool[key], j)
		end
	end
	for i = 1, n do
		if not src[i] then
			local want = desired[i]
			local list = pool[want and (want.link .. ":" .. want.count) or ""]
			src[i] = list and table.remove(list)
			if not src[i] then return nil end -- (can't be: desired is items, reordered)
		end
	end
	return src
end

-- Every rearrangement is two rounds of swaps that share no slot: each loop
-- of "this item goes there" (a, b, c... back to a) is undone by two mirror
-- images of it - swap the slots pairing up as x and -x round the loop, then
-- as x and 1-x. Returns the two rounds, lists of { slot index, slot index }.
local function TwoRounds(src, n)
	local dest = {}
	for i = 1, n do dest[src[i]] = i end
	local seen, round1, round2 = {}, {}, {}
	for start = 1, n do
		if not seen[start] and dest[start] ~= start then
			local loop, j = {}, start
			repeat
				loop[#loop + 1] = j
				seen[j] = true
				j = dest[j]
			until j == start
			-- loop[x + 1]'s item goes to loop[x + 2] (x counted from 0).
			local k = #loop
			for x = 0, k - 1 do
				local y = (-x) % k
				if x < y then table.insert(round1, { loop[x + 1], loop[y + 1] }) end
				y = (1 - x) % k
				if x < y then table.insert(round2, { loop[x + 1], loop[y + 1] }) end
			end
		end
	end
	return round1, round2
end

-- Swap two slots (played out on items; sent too if send). False if the
-- game wouldn't swap them: stacks of the same item merge instead.
local function Swap(items, slots, p, q, send)
	local a, b = items[p], items[q]
	if not a and not b then return true end
	if a and b and a.link == b.link then
		if a.count == b.count then return true end -- (no difference)
		-- Dropping the bigger stack on the smaller tops that one up and leaves
		-- the rest behind: the sizes swap, if the bigger one was full.
		if a.count < b.count then p, q, a = q, p, b end
		if not (a.maxStack and a.count >= a.maxStack) then return false end
	elseif not a then
		p, q = q, p -- (the item into the empty slot)
	end
	if send then Move(slots[p], slots[q]) end
	items[p], items[q] = items[q], items[p]
	return true
end

-- Put every item of a group in place in (at most) two rounds of swaps, each
-- sent all at once. The second round waits for the first to land (the slots
-- lock till then), and is only sent if the bags then look as planned;
-- otherwise it's all planned again from how they are.
local function OrderWithin(group)
	local items, slots = group.items, group.slots
	local n = #slots

	local nextRound, expect = group.nextRound, group.expect
	group.nextRound, group.expect = nil, nil
	if nextRound then
		local asPlanned = true
		for i = 1, n do
			if not Same(items[i], expect[i]) then asPlanned = false break end
		end
		if asPlanned then
			for _, s in ipairs(nextRound) do Swap(items, slots, s[1], s[2], true) end
			return "moved"
		end
	end

	local desired = Layout(items, n)
	local src = Assign(items, desired, n)
	if not src then return OrderGreedy(group, desired) end
	local round1, round2 = TwoRounds(src, n)
	if #round1 == 0 then round1, round2 = round2, round1 end
	if #round1 == 0 then return nil end

	-- Played out first: every swap must be one the game makes, and the end
	-- result what's wanted. (Not, say, with stacks whose size isn't known.)
	local sim = {}
	for i = 1, n do sim[i] = items[i] end
	for _, s in ipairs(round1) do
		if not Swap(sim, slots, s[1], s[2]) then return OrderGreedy(group, desired) end
	end
	local after1 = {}
	for i = 1, n do after1[i] = sim[i] end
	for _, s in ipairs(round2) do
		if not Swap(sim, slots, s[1], s[2]) then return OrderGreedy(group, desired) end
	end
	for i = 1, n do
		if not Same(sim[i], desired[i]) then return OrderGreedy(group, desired) end
	end

	for _, s in ipairs(round1) do Swap(items, slots, s[1], s[2], true) end
	if #round2 > 0 then group.nextRound, group.expect = round2, after1 end
	return "moved"
end

-- Returns "wait", "moved", "done" or "error".
local function Step(state)
	if CursorHasItem() then return "wait" end
	local groups = state.groups
	local ready, changed = ReadGroups(groups)
	if not ready then return "wait" end

	-- If the last move into a special bag didn't happen (the bag refused the
	-- item), don't try that item again this sort.
	state:CheckLastMove()

	-- Moves that change nothing (a bag refusing items it was thought to take)
	-- would be planned again and again: a few rounds of that and it stops.
	if not changed then
		-- (Not too soon either: the bags may just not have caught up yet.)
		state.stalls = state.stalls + 1
		state.stallSince = state.stallSince or GetTime()
		if state.stalls >= STALLS and GetTime() - state.stallSince >= 1 then return "stuck" end
	else
		state.stalls, state.stallSince = 0, nil
	end

	-- Groups never share slots, so each one's moves go in the same pass.
	local stacked = false
	for _, group in ipairs(groups) do
		if StackWithin(group) then stacked = true end
	end
	if stacked then return "moved" end

	local main
	for _, group in ipairs(groups) do
		if group.key == "main" then main = group end
	end
	if main then
		for _, group in ipairs(groups) do
			if group ~= main and group.family ~= 0 and not state.refusedBy[group.key]
				and FillSpecialBag(state, main, group) then
				return "moved"
			end
		end
	end

	local moved = false
	for _, group in ipairs(groups) do
		local result = OrderWithin(group)
		if result == "error" then return "error" end
		if result == "moved" then moved = true end
	end
	return moved and "moved" or "done"
end

---------------------------------------------------------------------------
-- Runner
---------------------------------------------------------------------------
local sorter = CreateFrame("Frame")
sorter:Hide()

-- Remember a cross-bag move so we can tell if it was refused. into, to: the
-- special bag group and its empty slot, when one is being filled.
function sorter:Track(from, record, into, to)
	self.lastMove = { bag = from[1], slot = from[2], link = record.link, count = record.count, id = record.id,
		into = into, to = to }
end

function sorter:CheckLastMove()
	local last = self.lastMove
	if not last then return end
	self.lastMove = nil
	local refused
	if last.to then
		-- Filling an empty slot: refused unless the item is there now.
		local there = API.GetSlotInfo(last.to[1], last.to[2])
		refused = not (there and there.hyperlink == last.link)
	else
		local info = API.GetSlotInfo(last.bag, last.slot)
		refused = info and info.hyperlink == last.link and info.stackCount == last.count
	end
	if refused then
		self.failed[last.link] = true
		-- The game's word on what fits that bag was wrong: never try this item
		-- there again, and stop filling the bag this sort (one error, not one
		-- per item).
		if last.into then
			Refused(last.into.family)[last.id] = true
			self.refusedBy[last.into.key] = true
		end
	end
end

local SORT_EVENTS = { "BAG_UPDATE_DELAYED", "ITEM_LOCK_CHANGED" }

---------------------------------------------------------------------------
-- Profiling (/fbags profile): how long each frame took while sorting, and
-- how much of that was addons (the game's own addon profiler), to tell a
-- slow addon from the game itself.
---------------------------------------------------------------------------
local P = C_AddOnProfiler
local METRIC = Enum and Enum.AddOnProfilerMetric

local function ProfileStart()
	return { start = GetTime(), frames = 0, worst = 0, slow = 0, game = 0, addons = 0, byAddon = {} }
end

local function Metric(fn, ...)
	local ok, v = pcall(fn, ...)
	return ok and type(v) == "number" and v or 0
end

local function ProfileFrame(pr, elapsed)
	pr.frames = pr.frames + 1
	local ms = elapsed * 1000
	if ms > pr.worst then pr.worst = ms end
	if ms > 50 then pr.slow = pr.slow + 1 end
	if not (P and METRIC) then return end
	-- (Times for the last whole frame, in ms.)
	pr.game = math.max(pr.game, Metric(P.GetApplicationMetric, METRIC.LastTime))
	pr.addons = math.max(pr.addons, Metric(P.GetOverallMetric, METRIC.LastTime))
	for i = 1, C_AddOns.GetNumAddOns() do
		if C_AddOns.IsAddOnLoaded(i) then
			local name = C_AddOns.GetAddOnInfo(i)
			local t = Metric(P.GetAddOnMetric, name, METRIC.LastTime)
			if t > 0 then
				local a = pr.byAddon[name] or { total = 0, worst = 0 }
				pr.byAddon[name] = a
				a.total, a.worst = a.total + t, math.max(a.worst, t)
			end
		end
	end
end

local function ProfileReport(pr, rounds, moves)
	ns.Print(("Sort took %.1fs: %d rounds, %d moves, %d frames."):format(
		GetTime() - pr.start, rounds, moves, pr.frames))
	print(("  Slowest frame %d ms; %d frames over 50 ms."):format(pr.worst, pr.slow))
	if not (P and METRIC) then return end
	print(("  Worst frame's own time: whole game %d ms, all addons %d ms."):format(pr.game, pr.addons))
	local list = {}
	for name, a in pairs(pr.byAddon) do list[#list + 1] = { name = name, total = a.total, worst = a.worst } end
	table.sort(list, function(a, b) return a.total > b.total end)
	for i = 1, math.min(3, #list) do
		local a = list[i]
		print(("  %s: %d ms in all, worst frame %.1f ms"):format(a.name, a.total, a.worst))
	end
	-- FireBags' own parts, slowest single time first.
	local parts = {}
	for label, t in pairs(ns.timings or {}) do parts[#parts + 1] = { label = label, t = t } end
	table.sort(parts, function(a, b) return a.t.worst > b.t.worst end)
	print("  FireBags, by part:")
	for i = 1, math.min(8, #parts) do
		local p = parts[i]
		print(("    %s: worst %.1f ms, %d ms in all (%dx)"):format(p.label, p.t.worst, p.t.total, p.t.count))
	end
end

local function StopSorting(message)
	sorter:Hide()
	for _, event in ipairs(SORT_EVENTS) do sorter:UnregisterEvent(event) end
	sorter.groups = nil
	ClearQueue()
	wipe(records)
	wipe(sorter.locked)
	if message then ns.Print(message) end
	if sorter.profile then
		local pr, rounds, moves = sorter.profile, sorter.moves, sorter.sent
		sorter.profile = nil
		-- (A moment later, to count the redraw after the sort too.)
		C_Timer.After(0.5, function()
			ProfileReport(pr, rounds, moves)
			ns.timings = nil
		end)
	end
	for _, w in ipairs(ns.windows) do w:RequestRefresh() end
end

-- Is a slot locked (an item on its way)? Without making a table per call.
local lockLoc = ItemLocation and ItemLocation.CreateEmpty and ItemLocation:CreateEmpty()
local function SlotLocked(bag, slot)
	if lockLoc and C_Item and C_Item.IsLocked and C_Item.DoesItemExist then
		lockLoc:SetBagAndSlot(bag, slot)
		if not C_Item.DoesItemExist(lockLoc) then return false end
		local ok, locked = pcall(C_Item.IsLocked, lockLoc)
		if ok and type(locked) == "boolean" then return locked end
	end
	local info = API.GetSlotInfo(bag, slot)
	return info and info.isLocked or false
end

-- The bags only need looking at again once the last moves have all landed:
-- slots lock as moves go out and unlock as they land, so the locked ones are
-- counted, and the bags read once none are left.
sorter.locked = {} -- [bag * 1000 + slot] = true
sorter:SetScript("OnEvent", function(self, event, bag, slot)
	if event == "ITEM_LOCK_CHANGED" and bag and slot then
		self.locked[bag * 1000 + slot] = SlotLocked(bag, slot) or nil
	end
	if next(self.locked) == nil then self.dirty = true end
end)

sorter:SetScript("OnUpdate", function(self, elapsed)
	if self.profile then
		local started = debugprofilestop()
		ProfileFrame(self.profile, elapsed)
		ns.Timed("(timing itself)", started)
	end
	if InCombatLockdown() then
		StopSorting("Sorting stopped: entered combat.")
		return
	end
	if self.kind == "bank" and not ns.atBank then
		StopSorting("Sorting stopped: left the bank.")
		return
	end

	-- Moves still to go out: the next few (not while you hold an item).
	if HasQueued() then
		if not CursorHasItem() then
			local started = ns.timings and debugprofilestop()
			self.sent = self.sent + SendQueued()
			if started then ns.Timed("sending moves", started) end
		end
		self.timer = 0
		return
	end

	self.timer = self.timer + elapsed
	if self.timer < STEP_INTERVAL then return end
	if not self.dirty then
		if self.timer < IDLE_STEP then return end
		-- Now and then a look anyway, in case an unlock was missed (the read
		-- below finds anything still locked).
		wipe(self.locked)
	end
	self.timer = 0
	self.dirty = false

	local started = ns.timings and debugprofilestop()
	local ok, result = ns.SafeCall(Step, self)
	if started then ns.Timed("planning", started) end
	if not ok then
		StopSorting("Sorting stopped: something went wrong.")
		return
	end

	if result == "wait" then
		self.waitSince = self.waitSince or GetTime()
		if GetTime() - self.waitSince > MAX_WAIT then StopSorting("Sorting stopped: items stayed locked.") end
	elseif result == "moved" then
		self.waitSince = nil
		self.moves = self.moves + 1
		if self.moves >= MAX_MOVES then StopSorting("Sorting stopped: too many moves.") end
	elseif result == "done" then
		StopSorting()
	elseif result == "stuck" then
		StopSorting("Sorting stopped: some items wouldn't move.")
	else
		StopSorting("Sorting stopped: bags changed unexpectedly. Try again.")
	end
end)

function ns.IsSorting()
	return sorter:IsShown()
end

-- kind: "inventory" (default) or "bank"; profile: report timings after
function ns.SortBags(kind, profile)
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

	sorter.kind = kind
	sorter.groups = BuildGroups(sections)
	sorter.failed = {}
	sorter.refusedBy = {}
	sorter.stalls, sorter.stallSince = 0, nil
	sorter.lastMove = nil
	sorter.sent = 0
	sorter.profile = profile and ProfileStart() or nil
	ns.timings = profile and {} or nil
	ClearQueue()
	sorter.timer = STEP_INTERVAL
	sorter.dirty = true
	sorter.waitSince = nil
	sorter.moves = 0
	wipe(records)
	wipe(sorter.locked)
	for _, event in ipairs(SORT_EVENTS) do sorter:RegisterEvent(event) end
	sorter:Show()
end
