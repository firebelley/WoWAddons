-- Crafting profit in Blizzard's profession window:
--   the selected recipe gets a "Profit: +12s" line (bottom right, left of
--   the "Track recipe" checkbox); hover it
--   for the breakdown. Hovering a recipe in the list adds the same numbers to
--   its tooltip.
--
--   Sells for:    lowest buyout of the crafted item (latest scan) x how many
--                 one craft makes, minus the auction house's 5% cut - or what
--                 a vendor pays, if that's more.
--   Reagent cost: each reagent at the cheapest of its auction price and its
--                 vendor price. Vendor prices are learned from every merchant
--                 you visit (unlimited stock, bought with gold).
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
		local rec = ns.Data.Get(id)
		if rec and rec.p then
			r.sell, r.sellSource, r.current, r.scanned = rec.p * r.made * (1 - AH_CUT), "auction", rec.q ~= 0, rec.s
		end
		local vendor = C_Item and C_Item.GetItemInfo and select(11, C_Item.GetItemInfo(id))
		if type(vendor) == "number" and vendor > 0 and vendor * r.made > (r.sell or 0) then
			r.sell, r.sellSource, r.current = vendor * r.made, "vendor", true
		end
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
