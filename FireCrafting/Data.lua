-- Recipes, the To Craft lists, and what they need.
--
-- The game only lists a profession's recipes while its window is open, so
-- each one you open is read (a few recipes per frame, so opening doesn't
-- hitch) and saved for this character. Materials you can craft yourself, from
-- any profession you've opened, are broken down when you don't have enough:
-- 12 Bolts of Mageweave needed, 10 in bags and bank -> 2 bolts to craft ->
-- 10 Mageweave Cloth needed.
local _, ns = ...

local Data = {}
ns.Data = Data

local TS = C_TradeSkillUI
local MAX_DEPTH = 6     -- how deep crafted materials are broken down
local SCAN_PER_FRAME = 30

---------------------------------------------------------------------------
-- The profession window
---------------------------------------------------------------------------
-- Viewing someone else's profession (a link, a guild member, an NPC) isn't yours.
function Data.ViewingOwnProfession()
	if not (TS and TS.IsTradeSkillReady and TS.IsTradeSkillReady()) then return false end
	for _, fn in ipairs({ "IsTradeSkillLinked", "IsTradeSkillGuild", "IsTradeSkillGuildMember", "IsNPCCrafting", "IsRuneforging" }) do
		if TS[fn] then
			local ok, other = pcall(TS[fn])
			if ok and other then return false end
		end
	end
	return true
end

-- The open profession: id, name.
function Data.CurrentProfession()
	local ok, base = pcall(TS.GetBaseProfessionInfo)
	local id = ok and base and base.professionID
	if not id or id == 0 then return nil end
	return id, base.professionName
end

-- The icon of one of your professions, by its skill line.
function Data.ProfessionIcon(profID)
	if not (GetProfessions and GetProfessionInfo) then return nil end
	for _, index in pairs({ GetProfessions() }) do
		local _, icon, _, _, _, _, skillLine = GetProfessionInfo(index)
		if skillLine == profID then return icon end
	end
end

---------------------------------------------------------------------------
-- Reading recipes
---------------------------------------------------------------------------
local function OutputItem(recipeID, s)
	if Enum.TradeskillRecipeType and s.recipeType == Enum.TradeskillRecipeType.Enchant then return nil end
	if s.outputItemID and s.outputItemID > 0 then return s.outputItemID end
	if TS.GetRecipeOutputItemData then
		local ok, data = pcall(TS.GetRecipeOutputItemData, recipeID, {})
		local link = ok and data and data.hyperlink
		return link and tonumber(link:match("item:(%d+)")) or nil
	end
end

local function ReadRecipe(recipeID, profID)
	local ok, s = pcall(TS.GetRecipeSchematic, recipeID, false)
	if not (ok and s and s.reagentSlotSchematics) then return nil end
	local basic = Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
	local slots = {}
	for _, slot in ipairs(s.reagentSlotSchematics) do
		-- Optional and finishing reagents are extras, not requirements.
		if slot.required ~= false and (not basic or slot.reagentType == basic) then
			local entry = { math.max(1, slot.quantityRequired or 1) }
			for _, r in ipairs(slot.reagents or {}) do
				if r.itemID then entry[#entry + 1] = r.itemID end
			end
			if #entry > 1 then slots[#slots + 1] = entry end
		end
	end
	local infoOK, info = pcall(TS.GetRecipeInfo, recipeID)
	info = infoOK and info or {}
	return {
		name = info.name or s.name or ("recipe " .. recipeID),
		icon = info.icon,
		prof = profID,
		out = OutputItem(recipeID, s),
		made = math.max(1, s.quantityMin or 1), -- the least one craft makes
		r = slots,
	}
end

local makes -- [itemID] = recipeID of yours that makes it; rebuilt when recipes change

function Data.Recipe(recipeID)
	local db = ns.db
	if not db then return nil end
	local r = db.recipes[recipeID]
	if not r then
		r = ReadRecipe(recipeID, Data.CurrentProfession())
		if r then
			db.recipes[recipeID] = r
			makes = nil
		end
	end
	return r
end

local function Makes(itemID)
	if not makes then
		makes = {}
		for id, r in pairs(ns.db.recipes) do
			-- Prefer the recipe that makes the most per craft.
			if r.out and (not makes[r.out] or r.made > ns.db.recipes[makes[r.out]].made) then makes[r.out] = id end
		end
	end
	return makes[itemID]
end

-- Read every learned recipe of the open profession, a few per frame.
local scanned = {} -- [profID] = true once read this session
local scanning

local function FinishScan(job)
	for id, r in pairs(ns.db.recipes) do
		if r.prof == job.prof and not job.seen[id] then ns.db.recipes[id] = nil end -- unlearned
	end
	scanned[job.prof] = true
	makes = nil
	if ns.Panel then ns.Panel.Refresh() end
end

local function ScanStep()
	local job = scanning
	if not job then return end
	if job.prof ~= Data.CurrentProfession() or not Data.ViewingOwnProfession() then
		scanning = nil -- switched away; read again next time
		return
	end
	local last = math.min(job.i + SCAN_PER_FRAME - 1, #job.ids)
	for i = job.i, last do
		local id = job.ids[i]
		local ok, info = pcall(TS.GetRecipeInfo, id)
		if ok and info and info.learned then
			local r = ReadRecipe(id, job.prof)
			if r then
				ns.db.recipes[id] = r
				job.seen[id] = true
			end
		end
	end
	job.i = last + 1
	if job.i > #job.ids then
		scanning = nil
		FinishScan(job)
	else
		C_Timer.After(0, function() ns.SafeCall(ScanStep) end)
	end
end

local function StartScan()
	if scanning or not (ns.db and Data.ViewingOwnProfession()) then return end
	local prof = Data.CurrentProfession()
	if not prof or scanned[prof] then return end
	local ok, ids = pcall(TS.GetAllRecipeIDs)
	if not (ok and type(ids) == "table" and #ids > 0) then return end
	scanning = { prof = prof, ids = ids, i = 1, seen = {} }
	ScanStep()
end

-- The list updates many times while the window opens; start once it settles.
local scanQueued = false
local function QueueScan()
	if scanQueued then return end
	scanQueued = true
	C_Timer.After(0.5, function()
		scanQueued = false
		ns.SafeCall(StartScan)
	end)
end
ns.On("TRADE_SKILL_SHOW", QueueScan)
ns.On("TRADE_SKILL_LIST_UPDATE", QueueScan)
ns.On("TRADE_SKILL_DATA_SOURCE_CHANGED", QueueScan)

-- A recipe learned with the window closed (from a trainer or a recipe item).
ns.On("NEW_RECIPE_LEARNED", function(recipeID)
	if not (ns.db and recipeID and TS.GetProfessionInfoByRecipeID) then return end
	local ok, p = pcall(TS.GetProfessionInfoByRecipeID, recipeID)
	if not (ok and p) then return end
	local prof = (p.parentProfessionID and p.parentProfessionID > 0) and p.parentProfessionID or p.professionID
	local r = prof and ReadRecipe(recipeID, prof)
	if r then
		ns.db.recipes[recipeID] = r
		makes = nil
	end
end)

---------------------------------------------------------------------------
-- The To Craft lists (one per profession)
---------------------------------------------------------------------------
function Data.List(profID)
	local lists = ns.db.lists
	lists[profID] = lists[profID] or {}
	return lists[profID]
end

function Data.Add(profID, recipeID, count)
	if not (profID and recipeID and count and count > 0) or not Data.Recipe(recipeID) then return end
	local list = Data.List(profID)
	for _, e in ipairs(list) do
		if e.id == recipeID then
			e.n = e.n + count
			return
		end
	end
	list[#list + 1] = { id = recipeID, n = count }
end

-- count 0 removes it.
function Data.SetCount(profID, recipeID, count)
	local list = Data.List(profID)
	for i, e in ipairs(list) do
		if e.id == recipeID then
			if count > 0 then e.n = count else table.remove(list, i) end
			return
		end
	end
end

-- Each craft of a listed recipe takes one off its count.
ns.On("UNIT_SPELLCAST_SUCCEEDED", function(unit, _, spellID)
	if unit ~= "player" or not (ns.db and spellID) then return end
	if issecretvalue and issecretvalue(spellID) then return end -- in combat
	for profID, list in pairs(ns.db.lists) do
		for _, e in ipairs(list) do
			if e.id == spellID then
				Data.SetCount(profID, spellID, e.n - 1)
				if ns.Panel then ns.Panel.Refresh() end
				return
			end
		end
	end
end)

---------------------------------------------------------------------------
-- Counts and prices
---------------------------------------------------------------------------
-- In your bags, and in your bank (FireBags' saved snapshot when it's
-- installed - else whatever the game remembers of your bank).
function Data.Counts(itemID)
	if FireBags and FireBags.GetItemCounts then
		local ok, bags, bank = pcall(FireBags.GetItemCounts, itemID)
		if ok and bags then return bags, bank or 0 end
	end
	local count = (C_Item and C_Item.GetItemCount) or GetItemCount
	local bags = count(itemID, false) or 0
	local all = count(itemID, true) or bags
	return bags, math.max(0, all - bags)
end

-- Costs come from FireAuction (vendor and auction prices) when it's installed.
function Data.HasPrices()
	return FireAuction and FireAuction.ItemCost and FireAuction.Money and true or false
end

local function Price(itemID)
	local ok, p = pcall(FireAuction.ItemCost, itemID)
	return ok and type(p) == "number" and p or nil
end

function Data.Money(copper)
	return FireAuction.Money(copper)
end

---------------------------------------------------------------------------
-- What a list needs
---------------------------------------------------------------------------
-- Returns
--   recipes   = { { id, n, recipe, cost, complete }, ... } (cost per n crafts)
--   materials = { { id, depth, need, have, crafts, made, short }, ... } in
--     list order, crafted materials followed by what they're made of
--     need:   how many in all
--     have:   how many come from your bags and bank
--     bank:   how many of those from the bank (bags are used first)
--     crafts: how many times to craft it (made: how many that gives;
--             recipe: the recipe that makes it)
--     short:  how many you have to get (buy or gather)
--   total, totalComplete: cost of every listed craft, from scratch
--   toBuy, toBuyComplete: cost of the materials you're short of
-- Costs are nil without FireAuction; complete is false when something has
-- no price.
-- use = { bags = bool, bank = bool }: which of what you own counts as "have"
-- (default both).
function Data.Compute(profID, use)
	use = use or { bags = true, bank = true }
	local out = { recipes = {}, materials = {} }
	local prices = Data.HasPrices()

	-- Cheapest way to get one: buy it, or craft it from its materials.
	local itemCost, craftCost = {}, {} -- [id] = { copper, complete }
	local busy = {}
	local ItemCost
	local function CraftCost(recipeID, depth)
		if craftCost[recipeID] then return craftCost[recipeID][1], craftCost[recipeID][2] end
		local r = Data.Recipe(recipeID)
		if not r then return nil, false end
		busy[recipeID] = true
		local total, complete = 0, true
		for _, slot in ipairs(r.r) do
			local best, bestComplete
			for i = 2, #slot do
				local c, ok = ItemCost(slot[i], depth + 1)
				if c and (not best or c < best) then best, bestComplete = c, ok end
			end
			if best then
				total = total + best * slot[1]
				complete = complete and bestComplete
			else
				complete = false
			end
		end
		busy[recipeID] = nil
		craftCost[recipeID] = { total, complete }
		return total, complete
	end
	ItemCost = function(itemID, depth)
		local cached = itemCost[itemID]
		if cached then return cached[1], cached[2] end
		local best = Price(itemID)
		local rid = Makes(itemID)
		if rid and depth < MAX_DEPTH and not busy[rid] then
			local c, ok = CraftCost(rid, depth)
			local each = c and c / ns.db.recipes[rid].made
			if ok and (not best or each < best) then best = each end
		end
		itemCost[itemID] = { best, best ~= nil }
		return best, best ~= nil
	end

	-- Materials: take what you have (bags first, then bank), craft what you
	-- can, the rest is short.
	local bagPool, bankPool = {}, {} -- how many are left as needs take them
	local function Load(itemID)
		if bagPool[itemID] then return end
		local bags, bank = Data.Counts(itemID)
		bagPool[itemID] = use.bags and bags or 0
		bankPool[itemID] = use.bank and bank or 0
	end
	local lines = {}
	local stack = {}
	local function Need(slot, qty, depth)
		local key = slot[2]
		local line = lines[key]
		if not line then
			line = { id = key, depth = depth, need = 0, have = 0, bank = 0, crafts = 0, made = 0, short = 0 }
			lines[key] = line
			out.materials[#out.materials + 1] = line
		end
		line.depth = math.min(line.depth, depth)
		line.need = line.need + qty

		local left = qty
		for i = 2, #slot do
			local id = slot[i]
			Load(id)
			local take = math.min(bagPool[id], left)
			bagPool[id], left = bagPool[id] - take, left - take
			take = math.min(bankPool[id], left)
			bankPool[id], left = bankPool[id] - take, left - take
			line.bank = line.bank + take
		end
		line.have = line.have + (qty - left)
		if left <= 0 then return end

		local rid = Makes(key)
		local r = rid and ns.db.recipes[rid]
		if r and depth < MAX_DEPTH and not stack[rid] then
			local crafts = math.ceil(left / r.made)
			line.recipe = rid
			line.crafts = line.crafts + crafts
			line.made = line.made + left
			bagPool[key] = bagPool[key] + crafts * r.made - left -- leftovers (in your bags) serve later needs
			stack[rid] = true
			for _, s in ipairs(r.r) do Need(s, s[1] * crafts, depth + 1) end
			stack[rid] = nil
		else
			line.short = line.short + left
		end
	end

	local total, totalComplete = 0, true
	for _, e in ipairs(Data.List(profID)) do
		local r = Data.Recipe(e.id)
		local entry = { id = e.id, n = e.n, recipe = r }
		out.recipes[#out.recipes + 1] = entry
		if r then
			stack[e.id] = true
			for _, s in ipairs(r.r) do Need(s, s[1] * e.n, 0) end
			stack[e.id] = nil
			if prices then
				local c, ok = CraftCost(e.id, 0)
				entry.cost, entry.complete = c * e.n, ok
				total = total + entry.cost
				totalComplete = totalComplete and ok
			end
		end
	end

	if prices then
		out.total, out.totalComplete = total, totalComplete
		local toBuy, toBuyComplete = 0, true
		for _, line in ipairs(out.materials) do
			if line.short > 0 then
				local p = Price(line.id)
				if p then toBuy = toBuy + p * line.short else toBuyComplete = false end
			end
		end
		out.toBuy, out.toBuyComplete = toBuy, toBuyComplete
	end
	return out
end
