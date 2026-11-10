-- Profession windows count what's in your bank too (from the saved snapshot),
-- since the game only counts your bags:
--   recipe list:  "Lesser Magic Wand [1+3]"  - 1 from your bags, 3 more with your bank
--   reagent list: "1/2 Simple Wood (+8 bank)"
-- You still have to fetch bank items before crafting; this just shows what you
-- could make.
local _, ns = ...

local BANK_COLOR = "ff8cb3ff" -- same blue as the tooltip counts

local function Enabled()
	return ns.db and ns.db.craftCounts
end

local function IsBasicRequired(schematic)
	return schematic and schematic.required ~= false
		and Enum.CraftingReagentType and schematic.reagentType == Enum.CraftingReagentType.Basic
end

---------------------------------------------------------------------------
-- What a recipe needs: { { items = { itemID, ... }, qty = n }, ... }, or false
-- when it can't be counted (no reagents, or reagents that aren't items).
---------------------------------------------------------------------------
local reagentCache = {}

local function RecipeReagents(recipeID)
	local cached = reagentCache[recipeID]
	if cached ~= nil then return cached end
	local ok, s = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
	if not ok or not s or not s.reagentSlotSchematics then return false end -- not ready; try again later

	local list = {}
	for _, slot in ipairs(s.reagentSlotSchematics) do
		if IsBasicRequired(slot) then
			local items = {}
			for _, r in ipairs(slot.reagents or {}) do
				if r.itemID then items[#items + 1] = r.itemID end
			end
			if #items == 0 then
				list = false
				break
			end
			list[#list + 1] = { items = items, qty = math.max(1, slot.quantityRequired or 1) }
		end
	end
	if list and #list == 0 then list = false end
	reagentCache[recipeID] = list
	return list
end

-- How many times you could craft it from your bags, and from bags + bank.
local function Craftable(reagents)
	local fromBags, withBank = math.huge, math.huge
	for _, slot in ipairs(reagents) do
		local bags, bank = 0, 0
		for _, id in ipairs(slot.items) do
			local b, k = ns.GetItemCounts(id)
			bags, bank = bags + b, bank + k
		end
		fromBags = math.min(fromBags, math.floor(bags / slot.qty))
		withBank = math.min(withBank, math.floor((bags + bank) / slot.qty))
	end
	return fromBags, withBank
end

---------------------------------------------------------------------------
-- Recipe list: Blizzard's " [N] " becomes " [N+M] ", M being the extra
-- crafts your bank allows.
---------------------------------------------------------------------------
local function CountFontString(button)
	if button.fbBankCount then return button.fbBankCount end
	local ok, fs = pcall(button.CreateFontString, button, nil, "OVERLAY", "GameFontHighlight_NoShadow")
	if not ok or not fs then fs = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") end
	fs:SetPoint("LEFT", button.Label, "RIGHT")
	button.fbBankCount = fs
	return fs
end

-- Blizzard sizes the name to leave room for its count; redo that for ours.
local function FitLabel(button, countWidth)
	local right = (button.LockedIcon and button.LockedIcon:IsShown()) and button.LockedIcon:GetWidth() or 0
	local skillUps = button.SkillUps and button.SkillUps:GetWidth() or 0
	local width = button:GetWidth() - (right + countWidth + 10 + skillUps)
	button.Label:SetWidth(button:GetWidth())
	button.Label:SetWidth(math.max(1, math.min(width, button.Label:GetStringWidth())))
end

local function DecorateRow(button, node)
	if button.fbBankCount then button.fbBankCount:Hide() end
	if not (Enabled() and button.Label and button.Count) then return end

	local data = node and node.GetData and node:GetData()
	local info = data and data.recipeInfo
	if not info then return end
	if Professions and Professions.GetHighestLearnedRecipe then
		info = Professions.GetHighestLearnedRecipe(info) or info
	end
	if not (info.learned and info.recipeID) then return end

	local reagents = RecipeReagents(info.recipeID)
	if not reagents then return end
	local fromBags, withBank = Craftable(reagents)
	local extra = withBank - fromBags
	local shown = C_TradeSkillUI.GetCraftableCount(info.recipeID) or 0
	-- Nothing to add - or the game already counts the bank here.
	if extra <= 0 or shown >= withBank then return end

	local fs = CountFontString(button)
	if shown > 0 then
		fs:SetFormattedText(" [%d|c%s+%d|r] ", shown, BANK_COLOR, extra)
	else
		fs:SetFormattedText(" [|c%s+%d|r] ", BANK_COLOR, extra)
	end
	local color = PROFESSION_RECIPE_COLOR or HIGHLIGHT_FONT_COLOR
	if color then fs:SetTextColor(color:GetRGB()) end
	button.Count:Hide()
	fs:Show()
	FitLabel(button, fs:GetStringWidth())
end

---------------------------------------------------------------------------
-- Reagents of the selected recipe: "1/2 Simple Wood" gets "(+8 bank)".
---------------------------------------------------------------------------
local function DecorateSlot(slot)
	if not Enabled() then return end
	local schematic = slot.GetReagentSlotSchematic and slot:GetReagentSlotSchematic()
	if not IsBasicRequired(schematic) then return end
	if not (slot.Name and slot.Name:IsShown() and slot.nameText and slot.GetNameColor) then return end

	local bags, bank = 0, 0
	for _, r in ipairs(schematic.reagents or {}) do
		if r.itemID then
			local b, k = ns.GetItemCounts(r.itemID)
			bags, bank = bags + b, bank + k
		end
	end
	if bank <= 0 then return end
	-- Don't add the bank twice if the game already counts it.
	if ProfessionsUtil and ProfessionsUtil.AccumulateReagentsInPossession then
		local ok, have = pcall(ProfessionsUtil.AccumulateReagentsInPossession, schematic.reagents, false)
		if ok and type(have) == "number" and have >= bags + bank then return end
	end

	slot.Name:SetText(slot:GetNameColor():WrapTextInColorCode(slot.nameText)
		.. (" |c%s(+%d bank)|r"):format(BANK_COLOR, bank))
end

-- Reagent slots are pooled frames; hook each one's Update the first time we see it.
local hookedSlots = {}
local function DecorateSlots(form)
	if not form.reagentSlotPool then return end
	for slot in form.reagentSlotPool:EnumerateActive() do
		if not hookedSlots[slot] and slot.Update then
			hookedSlots[slot] = true
			hooksecurefunc(slot, "Update", function(s) ns.SafeCall(DecorateSlot, s) end)
		end
		ns.SafeCall(DecorateSlot, slot)
	end
end

---------------------------------------------------------------------------
-- Setup: Blizzard's profession window loads the first time you open it.
---------------------------------------------------------------------------
local setUp = false
local function SetUp()
	local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
	if setUp or not page then return end
	setUp = true

	local list = page.RecipeList
	if list and list.ScrollBox and ScrollUtil and ScrollUtil.AddInitializedFrameCallback then
		ScrollUtil.AddInitializedFrameCallback(list.ScrollBox, function(_, button, node)
			if list.hideCraftableCount then return end
			ns.SafeCall(DecorateRow, button, node)
		end, ns, false)
	end

	local form = page.SchematicForm
	if form and form.Init then
		hooksecurefunc(form, "Init", function(f) ns.SafeCall(DecorateSlots, f) end)
	end
end

ns.On("ADDON_LOADED", function(name)
	if name == "Blizzard_Professions" then SetUp() end
end)
ns.On("PLAYER_LOGIN", SetUp) -- in case it loaded before FireBags

-- Learning or unlearning recipes can change what they need.
ns.On("SKILL_LINES_CHANGED", function() wipe(reagentCache) end)
