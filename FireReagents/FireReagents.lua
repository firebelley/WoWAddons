-- FireReagents: item tooltips list the recipes you know that use the item,
-- grouped by profession.
--
-- The game only tells addons a profession's recipes while its window is open,
-- so each profession is read when you open it and remembered (per character).
-- Recipes learned later are added as you learn them, and professions you drop
-- are forgotten.
local ADDON = ...

local MAX_PER_PROFESSION = 8 -- more than this shows "...and N more"
local SCAN_DELAY = 0.3

-- Gathering skills have no recipes (Mining does: smelting).
local NO_RECIPES = { [182] = true, [393] = true, [356] = true } -- Herbalism, Skinning, Fishing

-- Recipe colours, as in the profession window: orange/yellow/green still
-- give skill-ups, grey doesn't.
local DIFFICULTY_COLOR = {
	[0] = "ff8040", -- optimal
	[1] = "ffff00", -- medium
	[2] = "40c040", -- easy
	[3] = "808080", -- trivial
}

local db    -- FireReagentsCharDB: { profs = { [professionID] = { name, recipes = { [recipeID] = { name, diff, reagents = { [itemID] = qty } } } } } }
local index -- [itemID] = { { prof, name, diff, qty }, ... }

local function Print(msg)
	print("|cffff7f3fFireReagents|r: " .. msg)
end

---------------------------------------------------------------------------
-- Reagent index
---------------------------------------------------------------------------
local function Rebuild()
	index = {}
	for _, prof in pairs(db.profs) do
		for _, r in pairs(prof.recipes) do
			for itemID, qty in pairs(r.reagents) do
				local list = index[itemID]
				if not list then
					list = {}
					index[itemID] = list
				end
				list[#list + 1] = { prof = prof.name, name = r.name, diff = r.diff, qty = qty }
			end
		end
	end
	-- By profession, then recipes that still give skill-ups first, then name.
	for _, list in pairs(index) do
		table.sort(list, function(a, b)
			if a.prof ~= b.prof then return a.prof < b.prof end
			if (a.diff or 9) ~= (b.diff or 9) then return (a.diff or 9) < (b.diff or 9) end
			return a.name < b.name
		end)
	end
end

---------------------------------------------------------------------------
-- Reading recipes
---------------------------------------------------------------------------
local TS = C_TradeSkillUI

-- The reagents a recipe needs: { [itemID] = quantity }, or nil if none.
local function Reagents(recipeID)
	local ok, s = pcall(TS.GetRecipeSchematic, recipeID, false)
	if not ok or not s or not s.reagentSlotSchematics then return end
	local reagents, any = {}, false
	for _, slot in ipairs(s.reagentSlotSchematics) do
		-- Optional slots (extra bonuses) aren't really "used in" the recipe.
		if slot.required ~= false and slot.reagents then
			for _, r in ipairs(slot.reagents) do
				if r.itemID then
					reagents[r.itemID] = math.max(reagents[r.itemID] or 0, slot.quantityRequired or 1)
					any = true
				end
			end
		end
	end
	return any and reagents or nil
end

local function Record(recipes, recipeID, info)
	local reagents = Reagents(recipeID)
	if reagents then
		recipes[recipeID] = { name = info.name or "?", diff = info.relativeDifficulty, reagents = reagents }
	end
end

-- Viewing someone else's profession (a link, a guild member) isn't yours.
local function IsOwnProfessionOpen()
	if not (TS and TS.IsTradeSkillReady and TS.IsTradeSkillReady()) then return false end
	for _, fn in ipairs({ "IsTradeSkillLinked", "IsTradeSkillGuild", "IsTradeSkillGuildMember", "IsNPCCrafting" }) do
		if TS[fn] and TS[fn]() then return false end
	end
	return true
end

local function Scan()
	if not IsOwnProfessionOpen() then return end
	local base = TS.GetBaseProfessionInfo()
	local profID = base and base.professionID
	if not profID or profID == 0 then return end
	local ids = (TS.GetAllRecipeIDs and TS.GetAllRecipeIDs()) or {}
	if #ids == 0 then return end

	local recipes = {}
	for _, id in ipairs(ids) do
		local info = TS.GetRecipeInfo(id)
		if info and info.learned then Record(recipes, id, info) end
	end
	local isNew = not db.profs[profID]
	db.profs[profID] = { name = base.professionName or "?", recipes = recipes }
	Rebuild()
	if isNew then
		local n = 0
		for _ in pairs(recipes) do n = n + 1 end
		Print(("learned your %d %s recipes - their reagents now show it in tooltips."):format(n, base.professionName or "?"))
	end
end

local scanQueued = false
local function QueueScan()
	if scanQueued then return end
	scanQueued = true
	C_Timer.After(SCAN_DELAY, function()
		scanQueued = false
		Scan()
	end)
end

-- A recipe learned with the window closed (from a trainer or a recipe item).
local function OnRecipeLearned(recipeID)
	if not recipeID or not TS.GetProfessionInfoByRecipeID then return end
	local ok, p = pcall(TS.GetProfessionInfoByRecipeID, recipeID)
	local profID = ok and p and (p.parentProfessionID or p.professionID)
	local prof = profID and db.profs[profID]
	if not prof then return end -- not read yet; it'll be picked up when the window opens
	local info = TS.GetRecipeInfo(recipeID)
	if info then
		Record(prof.recipes, recipeID, info)
		Rebuild()
	end
end

---------------------------------------------------------------------------
-- Your professions: forget dropped ones, ask to open unread ones.
---------------------------------------------------------------------------
local function CurrentProfessions()
	if not GetProfessions then return nil end
	local current = {}
	for _, index in pairs({ GetProfessions() }) do
		local name, _, _, _, _, _, skillLine = GetProfessionInfo(index)
		if skillLine then current[skillLine] = name end
	end
	return current
end

local reminded = false
local function CheckProfessions()
	local current = CurrentProfessions()
	if not current then return end
	local names = {}
	for _, name in pairs(current) do names[name] = true end
	local changed = false
	for profID, prof in pairs(db.profs) do
		if not current[profID] and not names[prof.name] then
			db.profs[profID] = nil
			changed = true
		end
	end
	if changed then Rebuild() end

	if reminded then return end
	local unread = {}
	local readNames = {}
	for _, prof in pairs(db.profs) do readNames[prof.name] = true end
	for skillLine, name in pairs(current) do
		if not NO_RECIPES[skillLine] and not db.profs[skillLine] and not readNames[name] then
			unread[#unread + 1] = name
		end
	end
	if #unread > 0 then
		reminded = true
		table.sort(unread)
		Print(("open your %s window once so I can learn which recipes use what."):format(table.concat(unread, ", ")))
	end
end

---------------------------------------------------------------------------
-- Tooltips
---------------------------------------------------------------------------
local function AddLines(tooltip, itemID)
	local list = index and itemID and index[itemID]
	if not list then return end
	local prof, count, hidden = nil, 0, 0
	local function FlushHidden()
		if hidden > 0 then
			tooltip:AddLine(("   ...and %d more"):format(hidden), 0.6, 0.6, 0.6)
			hidden = 0
		end
	end
	for _, r in ipairs(list) do
		if r.prof ~= prof then
			FlushHidden()
			prof, count = r.prof, 0
			local total = 0
			for _, other in ipairs(list) do
				if other.prof == prof then total = total + 1 end
			end
			tooltip:AddLine(("%s - used in %d recipe%s:"):format(prof, total, total == 1 and "" or "s"), 1, 0.82, 0)
		end
		count = count + 1
		if count <= MAX_PER_PROFESSION then
			local color = DIFFICULTY_COLOR[r.diff] or "ffffff"
			tooltip:AddDoubleLine(("   |cff%s%s|r"):format(color, r.name), "x" .. r.qty, 1, 1, 1, 0.7, 0.7, 0.7)
		else
			hidden = hidden + 1
		end
	end
	FlushHidden()
end

local function HookTooltips()
	if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
		TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
			if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
			if data and data.id then AddLines(tooltip, data.id) end
		end)
	else
		for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
			tooltip:HookScript("OnTooltipSetItem", function(self)
				local _, link = self:GetItem()
				local id = link and GetItemInfoInstant(link)
				if id then AddLines(self, id) end
			end)
		end
	end
end

---------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" and arg1 == ADDON then
		FireReagentsCharDB = FireReagentsCharDB or {}
		db = FireReagentsCharDB
		db.profs = db.profs or {}
		Rebuild()
		HookTooltips()
	elseif event == "PLAYER_LOGIN" then
		for _, e in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED",
			"NEW_RECIPE_LEARNED", "SKILL_LINES_CHANGED" }) do
			pcall(self.RegisterEvent, self, e)
		end
		C_Timer.After(3, CheckProfessions) -- profession data isn't ready right at login
	elseif event == "NEW_RECIPE_LEARNED" then
		OnRecipeLearned(arg1)
	elseif event == "SKILL_LINES_CHANGED" then
		CheckProfessions()
	else
		QueueScan()
	end
end)
