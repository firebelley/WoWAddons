-- Item tooltips: "Auction house   1g 20s  +12% (7d)" - the market price
-- (Data.MarketPrice), with a "lowest listed" line under it when some were
-- noticeably cheaper. Crates that take a bundle: what each option costs.
local _, ns = ...

local CHEAPER = 0.95 -- the lowest gets its own line below this share of the market price

local function AddPrice(tooltip, itemID)
	if not (ns.db and ns.db.tooltip and itemID) then return end
	local rec = ns.Data.Get(itemID)
	local market = ns.Data.Market(rec)
	if not market then return end

	local listed = (rec.q or 0) > 0
	local right
	if listed then
		right = ns.Money(market)
	else
		right = "|cff999999none listed, was|r " .. ns.Money(market)
	end
	local pct, _, _, _, days = ns.Data.Trend(rec)
	if pct then
		right = right .. "  " .. ns.Percent(pct) .. ("|cff999999 (%dd)|r"):format(days)
	end

	local left = "Auction house"
	if ns.Now() - (rec.s or 0) > 86400 then
		left = left .. " |cff999999(" .. ns.TimeAgo(rec.s) .. ")|r"
	end
	tooltip:AddDoubleLine(left, right, 1, 0.82, 0, 1, 1, 1)
	if listed and rec.p and rec.p < market * CHEAPER then
		tooltip:AddDoubleLine("   lowest listed", ns.Money(rec.p), 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
	end
end

---------------------------------------------------------------------------
-- Crates that take a bundle ("Fill the crate with any bundle from the
-- following list: - 8 Iron Strut - 5 Mithril Tube ..."): a "Bundle cost"
-- table under the item's text, one line per option with what it costs on
-- the right - its market price, or crafting it from a recipe of yours if
-- that's cheaper - the cheapest in gold. The game's text is left as it is.
---------------------------------------------------------------------------
local OPTION = "^%s*%-%s*(%d+)%s+(.-)%s*$" -- one option per line: "- 8 Iron Strut"

local idByName, indexedFor -- item name -> ID, from the scanned items and your recipes
local function ItemIDByName(name)
	local realm = ns.Realm()
	local items = realm and realm.items
	if items ~= indexedFor then
		idByName, indexedFor = {}, items
		for id, rec in pairs(items or {}) do
			if rec.nm then idByName[rec.nm] = id end
		end
		for _, recipe in pairs(ns.db.recipes or {}) do
			local n = recipe.o and C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(recipe.o)
			if n then idByName[n] = recipe.o end
		end
	end
	local id = idByName[name]
	if not id and C_Item and C_Item.GetItemInfoInstant then
		id = C_Item.GetItemInfoInstant(name)
		if id then idByName[name] = id end
	end
	return id
end

-- What one costs: the market price, or crafting it if that's cheaper.
local function UnitCost(id)
	local market = ns.Data.Market(ns.Data.Get(id))
	local craft = ns.Crafting.CraftCost and ns.Crafting.CraftCost(id)
	if craft and (not market or craft < market) then return craft, true end
	return market, false
end

local function IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) and true or false end

local function AddCrateCosts(tooltip)
	if not (ns.db and ns.db.tooltip and tooltip.GetName and tooltip:GetName()) then return end
	local options = {}
	for i = 1, tooltip:NumLines() do
		local fs = _G[tooltip:GetName() .. "TextLeft" .. i]
		local text = fs and fs:GetText()
		if type(text) == "string" and not IsSecret(text) and text:find("%- %d+ ") then
			for _, row in ipairs({ strsplit("\n", text) }) do
				local plain = row:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
				local qty, name = plain:match(OPTION)
				local id = name and name ~= "" and ItemIDByName(name)
				if id then
					local each, craft = UnitCost(id)
					options[#options + 1] = { label = qty .. " " .. name, cost = each and each * tonumber(qty), craft = craft }
				end
			end
		end
	end
	if #options == 0 then return end
	local cheapest
	for _, o in ipairs(options) do
		if o.cost and (not cheapest or o.cost < cheapest) then cheapest = o.cost end
	end
	tooltip:AddLine("Bundle cost", 1, 0.82, 0)
	for _, o in ipairs(options) do
		local left = "   " .. o.label .. (o.craft and " |cff999999(craft)|r" or "")
		if not o.cost then
			tooltip:AddDoubleLine(left, "no price", 0.8, 0.8, 0.8, 0.6, 0.6, 0.6)
		elseif #options > 1 and o.cost == cheapest then
			tooltip:AddDoubleLine(left, ns.Money(math.floor(o.cost + 0.5)), 1, 0.82, 0, 1, 0.82, 0)
		else
			tooltip:AddDoubleLine(left, ns.Money(math.floor(o.cost + 0.5)), 0.8, 0.8, 0.8, 1, 1, 1)
		end
	end
end

local function IsMainTooltip(tooltip)
	return tooltip == GameTooltip or tooltip == ItemRefTooltip
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
		if not IsMainTooltip(tooltip) then return end
		ns.SafeCall(AddCrateCosts, tooltip)
		ns.SafeCall(AddPrice, tooltip, data and data.id)
		ns.SafeCall(ns.Crafting.AddCraftWorth, tooltip, data and data.id)
	end)
else
	for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
		tooltip:HookScript("OnTooltipSetItem", function(self)
			local _, link = self:GetItem()
			local id = link and tonumber(link:match("item:(%d+)"))
			ns.SafeCall(AddCrateCosts, self)
			ns.SafeCall(AddPrice, self, id)
			ns.SafeCall(ns.Crafting.AddCraftWorth, self, id)
		end)
	end
end
