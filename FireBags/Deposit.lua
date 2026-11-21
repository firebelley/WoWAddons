-- Deposit: a tab on the bank window (at a banker) that moves from your bags
-- into the bank every item you already keep some of in the bank. Partial stacks in the bank are topped up first, then empty slots
-- are used. Locked items (Marks.lua) stay in your bags, as does anything in a
-- special bag (soul shards, arrows...).
local _, ns = ...
local API = ns.API

local TICK = 0.1     -- seconds between rounds of moves
local PER_TICK = 10  -- moves sent per round (each to its own bank slot)
local TRIES = 3      -- moves of one bag slot before giving up on it

local Deposit = {}
ns.Deposit = Deposit

local runner = CreateFrame("Frame")
runner:Hide()

-- The bank's slots: item IDs it holds, its partial stacks and empty slots.
local function ReadBank()
	local have, partial, empty, busy = {}, {}, {}, false
	for _, bag in ipairs(ns.GetBankBagIDs()) do
		local size = API.GetNumSlots(bag)
		local _, family = API.GetFreeSlots(bag)
		if size > 0 and (family or 0) == 0 then
			for slot = 1, size do
				local info = API.GetSlotInfo(bag, slot)
				if not info then
					empty[#empty + 1] = { bag, slot }
				elseif info.isLocked then
					busy = true
				else
					local id = info.itemID
					have[id] = true
					local maxStack = select(8, API.GetItemInfo(info.hyperlink or id)) or 1
					if (info.stackCount or 1) < maxStack then
						partial[id] = partial[id] or {}
						table.insert(partial[id], { bag, slot })
					end
				end
			end
		end
	end
	return have, partial, empty, busy
end

-- Bag slots whose items go to the bank: { bag, slot, itemID } list.
local function Candidates(have)
	local list, busy = {}, false
	for _, section in ipairs(ns.GetInventorySections()) do
		if section.family == 0 or section.family == "reagent" then
			for _, entry in ipairs(section.bags) do
				for slot = 1, entry.numSlots do
					local info = API.GetSlotInfo(entry.bag, slot)
					if info and info.isLocked then
						busy = true
					elseif info and have[info.itemID] and not ns.Marks.IsLocked(entry.bag, slot) then
						list[#list + 1] = { entry.bag, slot, info.itemID }
					end
				end
			end
		end
	end
	return list, busy
end

-- How many bag slots Deposit would move (for the tab).
function Deposit.Count()
	if not ns.atBank then return 0 end
	local have = ReadBank()
	return #Candidates(have)
end

local function Stop()
	runner:Hide()
	if runner.moved and runner.moved > 0 then
		ns.Print(("Deposited %d stack%s."):format(runner.moved, runner.moved == 1 and "" or "s"))
	end
	if runner.full then ns.Print("Your bank is full.") end
	for _, w in ipairs(ns.windows) do w:RequestRefresh() end
end

runner:SetScript("OnUpdate", function(self, elapsed)
	self.timer = self.timer + elapsed
	if self.timer < TICK then return end
	self.timer = 0
	if not ns.atBank then return Stop() end
	if CursorHasItem() then return end

	local have, partial, empty, bankBusy = ReadBank()
	local list, bagBusy = Candidates(have)
	local sent, waiting = 0, bankBusy or bagBusy
	self.full = false
	for _, c in ipairs(list) do
		if sent >= PER_TICK then break end
		local key = c[1] .. ":" .. c[2]
		if (self.tries[key] or 0) < TRIES then
			local stacks = partial[c[3]]
			local target = stacks and table.remove(stacks, 1) or table.remove(empty, 1)
			if target then
				self.tries[key] = (self.tries[key] or 0) + 1
				API.Pickup(c[1], c[2])
				API.Pickup(target[1], target[2])
				-- Topping up a stack can leave some on the cursor; it goes back.
				if CursorHasItem() then ClearCursor() end
				sent = sent + 1
				self.moved = self.moved + 1
			else
				self.full = true
			end
		end
	end
	if sent == 0 and not waiting then Stop() end
end)

function Deposit.Start()
	if not ns.atBank then return ns.Print("Visit a banker to deposit.") end
	if runner:IsShown() or ns.IsSorting() then return end
	runner.timer, runner.moved, runner.tries, runner.full = TICK, 0, {}, false
	runner:Show()
end

---------------------------------------------------------------------------
-- The tab (shown at a banker; greyed out when there's nothing to move)
---------------------------------------------------------------------------
local tab = ns.bank:AddTab({
	title = "Deposit",
	text = function()
		local n = Deposit.Count()
		if n == 0 then return "Nothing to deposit." end
		return ("Move %d stack%s of items you already bank.\nLocked items stay."):format(n, n == 1 and "" or "s")
	end,
	icon = "Interface\\Icons\\INV_Crate_03",
	onClick = function() Deposit.Start() end,
})
tab:Hide()

local function UpdateTab()
	tab:SetShown(ns.atBank)
	if ns.atBank then tab:SetEnabledLook(Deposit.Count() > 0) end
end

-- (The bank's contents arrive a moment after it opens.)
ns.bank:HookScript("OnShow", function() UpdateTab() C_Timer.After(0.5, UpdateTab) end)
ns.On("BANKFRAME_OPENED", function() C_Timer.After(0.5, UpdateTab) end)
ns.On("BANKFRAME_CLOSED", UpdateTab)
ns.On("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function() C_Timer.After(0, UpdateTab) end)
ns.On("BAG_UPDATE_DELAYED", function() if ns.atBank and not runner:IsShown() then UpdateTab() end end)
