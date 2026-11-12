-- Crafting profit in Blizzard's profession window:
--   the selected recipe gets a "Profit: +12s" line (bottom right, left of
--   the "Track recipe" checkbox); hover it
--   for the breakdown. Hovering a recipe in the list adds the same numbers to
--   its tooltip.
--
--   Sells for:    market price of the crafted item (latest scan) x how many
--                 one craft makes, minus the auction house's 5% cut - or what
--                 a vendor pays, if that's more.
--   Reagent cost: each reagent at the cheapest of its lowest buyout and its
--                 vendor price. Vendor prices are learned from every merchant
--                 you visit (unlimited stock, bought with gold).
--
-- Also saves your recipes when a profession window opens, for "Worth as ..."
-- on reagent tooltips (see "Saved recipes" below).
local _, ns = ...

local Crafting = {}
ns.Crafting = Crafting

local AH_CUT = 0.05

---------------------------------------------------------------------------
-- Vendor prices (copper per item, all characters)
---------------------------------------------------------------------------
local function MerchantItemID(i)
	local id = GetMerchantItemID and GetMerchantItemID(i)
	if not id and GetMerchantItemLink then
		local link = GetMerchantItemLink(i)
		id = link and tonumber(link:match("item:(%d+)"))
	end
	return id
end

local function LearnMerchant()
	local db = ns.db
	if not (db and GetMerchantNumItems) then return end
	local learned = false
	for i = 1, GetMerchantNumItems() or 0 do
		local id = MerchantItemID(i)
		local price, stack, available, extended
		if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
			local info = C_MerchantFrame.GetItemInfo(i)
			if info then price, stack, available, extended = info.price, info.stackCount, info.numAvailable, info.hasExtendedCost end
		elseif GetMerchantItemInfo then
			local _, _, p, q, a, _, _, e = GetMerchantItemInfo(i)
			price, stack, available, extended = p, q, a, e
		end
		-- Limited stock (patterns, rare reagents) or bought with tokens: not "just buy it".
		if id and type(price) == "number" and price > 0 and available == -1 and not extended then
			local unit = price / math.max(1, stack or 1)
			if db.vendorPrices[id] ~= unit then
				db.vendorPrices[id] = unit
				learned = true
			end
		end
	end
	if learned then Crafting.Refresh() end
end
ns.On("MERCHANT_SHOW", LearnMerchant)
ns.On("MERCHANT_UPDATE", LearnMerchant)

---------------------------------------------------------------------------
-- Working it out
---------------------------------------------------------------------------
local function ItemName(id)
	return (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) or ns.Data.Name(id, ns.Data.Get(id))
		or ("item " .. id)
end

-- The cheapest way to get one: copper, "vendor"/"auction", and for auction
-- prices whether it was listed in the latest scan. nil if there's no price.
local function ReagentCost(id)
	local vendor = ns.db.vendorPrices[id]
	local rec = ns.Data.Get(id)
	local ah = rec and rec.p
	if vendor and (not ah or vendor <= ah) then return vendor, "vendor", true end
	if ah then return ah, "auction", rec.q ~= 0 end
	return nil
end

local function OutputItem(recipeID, s)
	if Enum.TradeskillRecipeType and s.recipeType == Enum.TradeskillRecipeType.Enchant then return nil end
	if s.outputItemID and s.outputItemID > 0 then return s.outputItemID end
	if C_TradeSkillUI.GetRecipeOutputItemData then
		local ok, data = pcall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID, {})
		local link = ok and data and data.hyperlink
		return link and tonumber(link:match("item:(%d+)")) or nil
	end
end

-- What `made` of the item bring in: at auction after the cut, or from a vendor
-- if that pays more. Returns copper, "auction"/"vendor", whether it was listed
-- in the latest scan, and when that was; nil without a price.
function Crafting.SellValue(id, made)
	local sell, source, current, scanned
	local rec = ns.Data.Get(id)
	local market = ns.Data.Market(rec)
	if market then
		sell, source, current, scanned = market * made * (1 - AH_CUT), "auction", rec.q ~= 0, rec.s
	end
	local vendor = C_Item and C_Item.GetItemInfo and select(11, C_Item.GetItemInfo(id))
	if type(vendor) == "number" and vendor > 0 and vendor * made > (sell or 0) then
		sell, source, current = vendor * made, "vendor", true
	end
	return sell, source, current, scanned
end

-- Returns nil when the recipe can't be read, else:
--   reagents = { { id, qty, unit, source, current }, ... }
--   cost, missing (reagents without a price)
--   output, made (how many one craft makes), sell, sellSource, current, scanned
--   profit (nil without a sell price)
function Crafting.Evaluate(recipeID)
	local ok, s = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
	if not (ok and s and s.reagentSlotSchematics) then return nil end

	local r = { reagents = {}, cost = 0, missing = 0 }
	local basic = Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
	for _, slot in ipairs(s.reagentSlotSchematics) do
		if slot.required ~= false and (not basic or slot.reagentType == basic) then
			local best
			for _, reagent in ipairs(slot.reagents or {}) do
				if reagent.itemID then
					local unit, source, current = ReagentCost(reagent.itemID)
					if not best or (unit and (not best.unit or unit < best.unit)) then
						best = { id = reagent.itemID, unit = unit, source = source, current = current }
					end
				end
			end
			if best then
				best.qty = math.max(1, slot.quantityRequired or 1)
				r.reagents[#r.reagents + 1] = best
				if best.unit then
					r.cost = r.cost + best.unit * best.qty
				else
					r.missing = r.missing + 1
				end
			end
		end
	end

	local id = OutputItem(recipeID, s)
	if id then
		r.output = id
		r.made = ((s.quantityMin or 1) + (s.quantityMax or s.quantityMin or 1)) / 2
		r.sell, r.sellSource, r.current, r.scanned = Crafting.SellValue(id, r.made)
		if r.sell then r.profit = r.sell - r.cost end
	end
	return r
end

---------------------------------------------------------------------------
-- Text
---------------------------------------------------------------------------
local function Signed(copper)
	if copper >= 0.5 then return "|cff40ff40+|r" .. ns.Money(copper) end
	if copper <= -0.5 then return "|cffff5050-|r" .. ns.Money(-copper) end
	return ns.Money(0)
end

-- The one line under the recipe.
local function Summary(r)
	local unsure = r.missing > 0 and " |cff999999(missing prices)|r" or ""
	if r.profit then return "Profit: " .. Signed(r.profit) .. unsure end
	if r.cost > 0 then return "Reagents cost " .. ns.Money(r.cost) .. unsure end
	return nil
end

local function AddBreakdown(tooltip, r)
	local grey = "|cff999999"
	if r.output then
		local each = r.made ~= 1 and (" (%s made)"):format(r.made % 1 == 0 and r.made or ("~" .. r.made)) or ""
		if r.sell then
			local note = r.sellSource == "vendor" and "to a vendor" or "at auction, after the 5% cut"
			tooltip:AddDoubleLine("Sells for" .. each, ns.Money(r.sell), 1, 1, 1, 1, 1, 1)
			tooltip:AddLine("  " .. note, 0.6, 0.6, 0.6)
		else
			tooltip:AddDoubleLine("Sells for" .. each, "no price", 1, 1, 1, 1, 0.4, 0.4)
		end
	end
	for _, g in ipairs(r.reagents) do
		local left = ("  %d x %s"):format(g.qty, ItemName(g.id))
		if g.unit then
			local where = g.source == "vendor" and "vendor" or (g.current and "auction" or "auction, not listed now")
			tooltip:AddDoubleLine(left, ns.Money(g.unit * g.qty) .. " " .. grey .. where .. "|r", 0.8, 0.8, 0.8, 1, 1, 1)
		else
			tooltip:AddDoubleLine(left, "no price", 0.8, 0.8, 0.8, 1, 0.4, 0.4)
		end
	end
	tooltip:AddDoubleLine("Reagent cost", ns.Money(r.cost), 1, 1, 1, 1, 1, 1)
	if r.profit then tooltip:AddDoubleLine("Profit", Signed(r.profit), 1, 0.82, 0) end
	if r.missing > 0 then
		tooltip:AddLine("Reagents without a price aren't counted: scan the auction house, or visit a vendor that sells them.",
			0.6, 0.6, 0.6, true)
	end
	if r.sellSource == "auction" and not r.current then
		tooltip:AddLine("The crafted item wasn't listed in the latest scan; its price is from an earlier one.", 0.6, 0.6, 0.6, true)
	end
end

---------------------------------------------------------------------------
-- The selected recipe: a line at the bottom right of the recipe details.
---------------------------------------------------------------------------
local form, line, current

local function UpdateLine()
	if not line then return end
	local r = ns.db.craftProfit and current and Crafting.Evaluate(current)
	local text = r and Summary(r)
	line.result = r
	if not text then
		line:Hide()
		return
	end
	line.text:SetText(text)
	line:SetSize(line.text:GetStringWidth() + 4, 18)
	-- Left of the "Track recipe" checkbox (its label is to its right).
	line:ClearAllPoints()
	local track = form.TrackRecipeCheckbox
	if track and track:IsShown() then
		line:SetPoint("RIGHT", track, "LEFT", -8, 0)
	else
		line:SetPoint("BOTTOMRIGHT", form, "BOTTOMRIGHT", -16, 12)
	end
	line:Show()
	if line:IsMouseOver() and GameTooltip:IsOwned(line) then line:GetScript("OnEnter")(line) end
end

local function CreateLine()
	line = CreateFrame("Frame", nil, form)
	line:SetFrameLevel(form:GetFrameLevel() + 10)
	line.text = line:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	line.text:SetPoint("RIGHT")
	line:SetScript("OnEnter", function(self)
		if not self.result then return end
		GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
		GameTooltip:SetText("Crafting profit", 1, 0.82, 0)
		ns.SafeCall(AddBreakdown, GameTooltip, self.result)
		GameTooltip:Show()
	end)
	line:SetScript("OnLeave", function() GameTooltip:Hide() end)
	line:Hide()
end

-- Batched: item info can arrive many times a second.
local pending = false
function Crafting.Refresh()
	if pending or not (form and form:IsVisible()) then return end
	pending = true
	C_Timer.After(0.2, function()
		pending = false
		ns.SafeCall(UpdateLine)
	end)
end

---------------------------------------------------------------------------
-- The recipe list: hovering a recipe adds its profit to the tooltip.
---------------------------------------------------------------------------
local rowRecipe = setmetatable({}, { __mode = "k" }) -- [row] = recipeID (kept off Blizzard's frames)
local hookedRows = setmetatable({}, { __mode = "k" })

local function AddRowTooltip(button)
	local recipeID = rowRecipe[button]
	if not (ns.db.craftProfit and recipeID) then return end
	local r = Crafting.Evaluate(recipeID)
	local text = r and Summary(r)
	if not text then return end
	local owner = GameTooltip:IsShown() and GameTooltip:GetOwner()
	if owner ~= button and owner ~= button.Label then
		GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
	end
	GameTooltip:AddLine(text)
	GameTooltip:Show()
end

local function TrackRow(button, node)
	local data = node and node.GetData and node:GetData()
	local info = data and data.recipeInfo
	rowRecipe[button] = info and info.recipeID or nil
	if info and not hookedRows[button] then
		hookedRows[button] = true
		button:HookScript("OnEnter", function(b) ns.SafeCall(AddRowTooltip, b) end)
	end
end

---------------------------------------------------------------------------
-- Saved recipes and "Worth as ..."
--
-- Opening a profession window saves its learned recipes (account-wide), so
-- reagent tooltips can say, anywhere, what that reagent is worth when you
-- craft it into something - the most you can pay for it and break even:
--   (what the crafted items sell for - the other reagents)
--     / how many of this reagent one craft takes
-- The best of your recipes that use it is shown.
---------------------------------------------------------------------------
local reagentIndex -- [reagent itemID] = { recipeID, ... }, rebuilt after saving

local function ViewingOwnProfession()
	local T = C_TradeSkillUI
	for _, fn in ipairs({ "IsTradeSkillLinked", "IsTradeSkillGuild", "IsTradeSkillGuildMember", "IsNPCCrafting", "IsRuneforging" }) do
		if T[fn] then
			local ok, other = pcall(T[fn])
			if ok and other then return false end
		end
	end
	return true
end

local function SaveRecipe(recipeID)
	local ok, s = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
	if not (ok and s and s.reagentSlotSchematics) then return end
	local output = OutputItem(recipeID, s)
	if not output then return end
	local basic = Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
	local slots = {}
	for _, slot in ipairs(s.reagentSlotSchematics) do
		if slot.required ~= false and (not basic or slot.reagentType == basic) then
			local entry = { math.max(1, slot.quantityRequired or 1) }
			for _, reagent in ipairs(slot.reagents or {}) do
				if reagent.itemID then entry[#entry + 1] = reagent.itemID end
			end
			if #entry > 1 then slots[#slots + 1] = entry end
		end
	end
	if #slots == 0 then return end
	ns.db.recipes[recipeID] = {
		o = output,
		m = ((s.quantityMin or 1) + (s.quantityMax or s.quantityMin or 1)) / 2,
		r = slots,
	}
end

local function SaveRecipes()
	local T = C_TradeSkillUI
	if not (ns.db and T and T.GetRecipeSchematic and T.GetRecipeInfo) or not ViewingOwnProfession() then return end
	local list
	for _, fn in ipairs({ "GetAllRecipeIDs", "GetFilteredRecipeIDs" }) do
		if not list and T[fn] then
			local ok, ids = pcall(T[fn])
			if ok and type(ids) == "table" and #ids > 0 then list = ids end
		end
	end
	if not list then return end
	for _, id in ipairs(list) do
		local ok, info = pcall(T.GetRecipeInfo, id)
		if ok and info and info.learned then SaveRecipe(id) end
	end
	reagentIndex = nil
end

-- The list updates many times while the window opens; save once it settles.
local savePending = false
local function SaveSoon()
	if savePending then return end
	savePending = true
	C_Timer.After(1, function()
		savePending = false
		ns.SafeCall(SaveRecipes)
	end)
end
ns.On("TRADE_SKILL_SHOW", SaveSoon)
ns.On("TRADE_SKILL_LIST_UPDATE", SaveSoon)
ns.On("NEW_RECIPE_LEARNED", SaveSoon)

local function ReagentIndex()
	if reagentIndex then return reagentIndex end
	reagentIndex = {}
	for recipeID, recipe in pairs(ns.db.recipes) do
		for _, slot in ipairs(recipe.r) do
			for i = 2, #slot do
				local list = reagentIndex[slot[i]]
				if not list then
					list = {}
					reagentIndex[slot[i]] = list
				end
				list[#list + 1] = recipeID
			end
		end
	end
	return reagentIndex
end

-- Every saved recipe that uses itemID, best first:
-- { { output = itemID, made = how many one craft makes, qty = how many of
--     itemID one craft takes,
--     sell, source, current = what one craft brings in after the cut
--       (Crafting.SellValue; sell is nil without a price),
--     unit = the crafted item's price each, before the cut,
--     other = the other reagents' cost per craft (nil if one has no price),
--     worth = what one of itemID is worth this way, break-even (nil without
--       the prices) }, ... }
function Crafting.Uses(itemID)
	local uses = {}
	local list = ns.db and itemID and ReagentIndex()[itemID]
	if not list then return uses end
	for _, recipeID in ipairs(list) do
		local recipe = ns.db.recipes[recipeID]
		if recipe and recipe.o ~= itemID then
			local u = { output = recipe.o, made = recipe.m, qty = 0, other = 0 }
			u.sell, u.source, u.current = Crafting.SellValue(recipe.o, recipe.m)
			if u.sell then
				local rec = ns.Data.Get(recipe.o)
				u.unit = u.source == "vendor" and u.sell / recipe.m or ns.Data.Market(rec)
			end
			for _, slot in ipairs(recipe.r) do
				local mine = false
				for i = 2, #slot do
					if slot[i] == itemID then mine = true end
				end
				if mine then
					u.qty = u.qty + slot[1]
				elseif u.other then
					local cheapest
					for i = 2, #slot do
						local unit = ReagentCost(slot[i])
						if unit and (not cheapest or unit < cheapest) then cheapest = unit end
					end
					u.other = cheapest and u.other + cheapest * slot[1] or nil
				end
			end
			if u.sell and u.other and u.qty > 0 then u.worth = math.floor((u.sell - u.other) / u.qty) end
			if u.qty > 0 then uses[#uses + 1] = u end
		end
	end
	table.sort(uses, function(a, b) return (a.worth or -math.huge) > (b.worth or -math.huge) end)
	return uses
end

-- What one of itemID is worth crafted into something (break-even price):
-- { price = copper, output = itemID } for the best recipe, or nil (no saved
-- recipe uses it, prices are missing, or crafting it never pays).
function Crafting.CraftWorth(itemID)
	local best = Crafting.Uses(itemID)[1]
	if best and best.worth and best.worth > 0 then return { price = best.worth, output = best.output } end
	return nil
end

-- Item tooltips, right under the auction price:
--   "Crafting profit (Bolt of Silk Cloth)   +32c each  +29%"
-- what you make on each one bought at today's lowest buyout and crafted
-- (the % in green, or red for a loss). While none is listed there's nothing
-- to compare against, so it says what one would have to cost to break even.
function Crafting.AddCraftWorth(tooltip, itemID)
	if not (ns.db and ns.db.craftWorth and itemID) then return end
	local best = Crafting.CraftWorth(itemID)
	if not best then return end
	local left = "Crafting profit |cff999999(" .. ItemName(best.output) .. ")|r"
	local right
	local rec = ns.Data.Get(itemID)
	if rec and (rec.p or 0) > 0 and (rec.q or 0) > 0 then
		local profit = best.price - rec.p
		local sign = profit > 0 and "+" or profit < 0 and "-" or ""
		right = sign .. ns.Money(math.abs(profit)) .. " each  " .. ns.Percent(profit / rec.p * 100)
	else
		right = "|cff999999none listed, break even at|r " .. ns.Money(best.price)
	end
	tooltip:AddDoubleLine(left, right, 1, 0.82, 0, 1, 1, 1)
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
			ns.SafeCall(TrackRow, button, node)
		end, Crafting, false)
	end

	form = page.SchematicForm
	if form and form.Init then
		CreateLine()
		hooksecurefunc(form, "Init", function(_, recipeInfo)
			current = recipeInfo and recipeInfo.recipeID or nil
			ns.SafeCall(UpdateLine)
		end)
	end
end

ns.On("ADDON_LOADED", function(name)
	if name == "Blizzard_Professions" then SetUp() end
end)
ns.On("PLAYER_LOGIN", SetUp) -- in case it loaded before FireAuction
-- Item names and vendor prices arrive a moment after they're first asked for.
ns.On("GET_ITEM_INFO_RECEIVED", function() Crafting.Refresh() end)
