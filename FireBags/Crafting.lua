-- Profession windows count what's in your bank too (from the saved snapshot),
-- and optionally what you could buy from a vendor, since the game only counts
-- your bags:
--   recipe list:  "Linen Belt [1+3+2]" - 1 from your bags (Blizzard's number),
--                 3 more with your bank (blue), 2 more if you buy the vendor
--                 reagents (gold). Hovering the recipe explains the numbers.
--   reagent list: "1/2 Simple Wood (+8 bank)", "0/1 Coarse Thread (vendor)"
-- You still have to fetch bank items and buy vendor ones before crafting; this
-- just shows what you could make.
local _, ns = ...

local BANK_COLOR = "ff8cb3ff"   -- same blue as the tooltip counts
local VENDOR_COLOR = "ffe0b040" -- gold

---------------------------------------------------------------------------
-- Vendor reagents: the usual trade supplies, plus every item FireBags sees a
-- merchant selling for gold in unlimited supply (saved, all characters).
---------------------------------------------------------------------------
local KNOWN_VENDOR_ITEMS = {
	-- Thread
	[2320] = true, [2321] = true, [4291] = true, [8343] = true, [14341] = true,
	-- Dyes, salt, bleach
	[2324] = true, [2325] = true, [2604] = true, [2605] = true, [4340] = true, [4341] = true,
	[4342] = true, [6260] = true, [6261] = true, [10290] = true, [4289] = true,
	-- Vials
	[3371] = true, [3372] = true, [8925] = true, [18256] = true,
	-- Flux, coal, wiring
	[2880] = true, [3466] = true, [18567] = true, [3857] = true, [7191] = true,
	-- Enchanting: copper rod, simple wood
	[6217] = true, [4470] = true,
	-- Cooking: spices, water, milk
	[2678] = true, [2692] = true, [3713] = true, [159] = true, [1179] = true,
}

local function IsVendorItem(itemID)
	return KNOWN_VENDOR_ITEMS[itemID] or (ns.db and ns.db.vendorItems and ns.db.vendorItems[itemID]) or false
end

local function MerchantItemID(i)
	local id = GetMerchantItemID and GetMerchantItemID(i)
	if not id and GetMerchantItemLink then
		local link = GetMerchantItemLink(i)
		id = link and tonumber(link:match("item:(%d+)"))
	end
	return id
end

local function LearnMerchant()
	if not (ns.db and ns.db.vendorItems and GetMerchantNumItems) then return end
	for i = 1, GetMerchantNumItems() or 0 do
		local id = MerchantItemID(i)
		local price, available, extended
		if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
			local info = C_MerchantFrame.GetItemInfo(i)
			if info then price, available, extended = info.price, info.numAvailable, info.hasExtendedCost end
		elseif GetMerchantItemInfo then
			local _, _, p, _, a, _, _, e = GetMerchantItemInfo(i)
			price, available, extended = p, a, e
		end
		-- Limited stock (patterns, rare reagents) or bought with tokens: not "just buy it".
		if id and type(price) == "number" and price > 0 and available == -1 and not extended then
			ns.db.vendorItems[id] = true
		end
	end
end
ns.On("MERCHANT_SHOW", LearnMerchant)
ns.On("MERCHANT_UPDATE", LearnMerchant)

---------------------------------------------------------------------------
-- What a recipe needs: { { items = { itemID, ... }, qty = n, vendor = bool }, ... },
-- or false when it can't be counted (no reagents, or reagents that aren't items).
---------------------------------------------------------------------------
local function IsBasicRequired(schematic)
	return schematic and schematic.required ~= false
		and Enum.CraftingReagentType and schematic.reagentType == Enum.CraftingReagentType.Basic
end

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

local function SlotIsVendor(slot)
	for _, id in ipairs(slot.items) do
		if IsVendorItem(id) then return true end
	end
	return false
end

-- How many times you could craft it:
--   bags, withBank: from your bags / bags + bank
--   vendorBags, vendorBank: the same, ignoring vendor reagents (nil if every
--     reagent is a vendor one - you could make as many as you can buy)
-- plus the names of the vendor reagents you have none of.
local function Craftable(reagents, useBank)
	local c = { bags = math.huge, withBank = math.huge, vendorBags = math.huge, vendorBank = math.huge, toBuy = {} }
	for _, slot in ipairs(reagents) do
		local bags, bank = 0, 0
		for _, id in ipairs(slot.items) do
			local b, k = ns.GetItemCounts(id)
			bags, bank = bags + b, bank + k
		end
		local nBags, nBank = math.floor(bags / slot.qty), math.floor((bags + bank) / slot.qty)
		c.bags, c.withBank = math.min(c.bags, nBags), math.min(c.withBank, nBank)
		if SlotIsVendor(slot) then
			if (useBank and nBank or nBags) == 0 then
				local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(slot.items[1])
				c.toBuy[#c.toBuy + 1] = name or ("item " .. slot.items[1])
			end
		else
			c.vendorBags, c.vendorBank = math.min(c.vendorBags, nBags), math.min(c.vendorBank, nBank)
		end
	end
	if c.vendorBags == math.huge then c.vendorBags, c.vendorBank = nil, nil end
	return c
end

---------------------------------------------------------------------------
-- Recipe list: Blizzard's " [N] " becomes " [N+bank+vendor] ".
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

-- Hovering a recipe with our count explains it.
local function AddRowTooltip(button)
	local c = button.fbCounts
	if not (c and button.fbBankCount and button.fbBankCount:IsShown()) then return end
	-- Keep a tooltip already on this row (Blizzard's, or another addon's lines).
	local owner = GameTooltip:IsShown() and GameTooltip:GetOwner()
	if owner ~= button and owner ~= button.Label then
		GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
	end
	GameTooltip:AddLine("Can craft:", 1, 0.82, 0)
	GameTooltip:AddDoubleLine("From your bags", c.bags, 1, 1, 1, 1, 1, 1)
	if c.bank then
		GameTooltip:AddDoubleLine("|c" .. BANK_COLOR .. "With your bank|r", "|c" .. BANK_COLOR .. c.bank .. "|r")
	end
	if c.vendor then
		GameTooltip:AddDoubleLine("|c" .. VENDOR_COLOR .. "Buying vendor reagents|r", "|c" .. VENDOR_COLOR .. c.vendor .. "|r")
		if #c.toBuy > 0 then
			GameTooltip:AddLine("Buy: " .. table.concat(c.toBuy, ", "), 0.7, 0.7, 0.7, true)
		end
	end
	GameTooltip:Show()
end

local function DecorateRow(button, node)
	if button.fbBankCount then button.fbBankCount:Hide() end
	button.fbCounts = nil
	local db = ns.db
	if not (db and (db.craftCounts or db.craftVendor) and button.Label and button.Count) then return end

	local data = node and node.GetData and node:GetData()
	local info = data and data.recipeInfo
	if not info then return end
	if Professions and Professions.GetHighestLearnedRecipe then
		info = Professions.GetHighestLearnedRecipe(info) or info
	end
	if not (info.learned and info.recipeID) then return end

	local reagents = RecipeReagents(info.recipeID)
	if not reagents then return end
	local c = Craftable(reagents, db.craftCounts)
	local shown = C_TradeSkillUI.GetCraftableCount(info.recipeID) or 0

	-- The extra crafts your bank allows (none if the game already counts it).
	local bankExtra = 0
	if db.craftCounts and shown < c.withBank then bankExtra = c.withBank - c.bags end
	local soFar = shown + bankExtra
	-- ...and the extra ones if you buy the vendor reagents.
	local vendorExtra = 0
	local ignoringVendor = db.craftCounts and c.vendorBank or c.vendorBags
	if db.craftVendor and ignoringVendor and ignoringVendor > soFar then
		vendorExtra = ignoringVendor - soFar
	end
	if bankExtra <= 0 and vendorExtra <= 0 then return end
	local toBuy = c.toBuy

	local parts = {}
	if shown > 0 then parts[#parts + 1] = tostring(shown) end
	if bankExtra > 0 then parts[#parts + 1] = ("|c%s+%d|r"):format(BANK_COLOR, bankExtra) end
	if vendorExtra > 0 then parts[#parts + 1] = ("|c%s+%d|r"):format(VENDOR_COLOR, vendorExtra) end

	local fs = CountFontString(button)
	fs:SetText(" [" .. table.concat(parts) .. "] ")
	local color = PROFESSION_RECIPE_COLOR or HIGHLIGHT_FONT_COLOR
	if color then fs:SetTextColor(color:GetRGB()) end
	button.Count:Hide()
	fs:Show()
	FitLabel(button, fs:GetStringWidth())

	button.fbCounts = {
		bags = shown,
		bank = bankExtra > 0 and soFar or nil,
		vendor = vendorExtra > 0 and (soFar + vendorExtra) or nil,
		toBuy = toBuy,
	}
	if not button.fbTooltipHooked then
		button.fbTooltipHooked = true
		button:HookScript("OnEnter", function(b) ns.SafeCall(AddRowTooltip, b) end)
	end
end

---------------------------------------------------------------------------
-- Reagents of the selected recipe: "1/2 Simple Wood" gets "(+8 bank)",
-- vendor reagents get "(vendor)".
---------------------------------------------------------------------------
local function DecorateSlot(slot)
	local db = ns.db
	if not (db and (db.craftCounts or db.craftVendor)) then return end
	local schematic = slot.GetReagentSlotSchematic and slot:GetReagentSlotSchematic()
	if not IsBasicRequired(schematic) then return end
	if not (slot.Name and slot.Name:IsShown() and slot.nameText and slot.GetNameColor) then return end

	local bags, bank, vendor = 0, 0, false
	for _, r in ipairs(schematic.reagents or {}) do
		if r.itemID then
			local b, k = ns.GetItemCounts(r.itemID)
			bags, bank = bags + b, bank + k
			vendor = vendor or IsVendorItem(r.itemID)
		end
	end

	local extra = ""
	if db.craftCounts and bank > 0 then
		-- Don't add the bank twice if the game already counts it.
		local counted = false
		if ProfessionsUtil and ProfessionsUtil.AccumulateReagentsInPossession then
			local ok, have = pcall(ProfessionsUtil.AccumulateReagentsInPossession, schematic.reagents, false)
			counted = ok and type(have) == "number" and have >= bags + bank
		end
		if not counted then extra = (" |c%s(+%d bank)|r"):format(BANK_COLOR, bank) end
	end
	if db.craftVendor and vendor then
		extra = extra .. (" |c%s(vendor)|r"):format(VENDOR_COLOR)
	end
	if extra == "" then return end

	slot.Name:SetText(slot:GetNameColor():WrapTextInColorCode(slot.nameText) .. extra)
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
