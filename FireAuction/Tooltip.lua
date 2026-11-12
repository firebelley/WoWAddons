-- Item tooltips: "Auction house   1g 20s  +12% (7d)" - the market price
-- (Data.MarketPrice), with a "lowest listed" line under it when some were
-- noticeably cheaper.
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
	if time() - (rec.s or 0) > 86400 then
		left = left .. " |cff999999(" .. ns.TimeAgo(rec.s) .. ")|r"
	end
	tooltip:AddDoubleLine(left, right, 1, 0.82, 0, 1, 1, 1)
	if listed and rec.p and rec.p < market * CHEAPER then
		tooltip:AddDoubleLine("   lowest listed", ns.Money(rec.p), 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
	end
end

local function IsMainTooltip(tooltip)
	return tooltip == GameTooltip or tooltip == ItemRefTooltip
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
		if not IsMainTooltip(tooltip) then return end
		ns.SafeCall(AddPrice, tooltip, data and data.id)
		ns.SafeCall(ns.Crafting.AddCraftWorth, tooltip, data and data.id)
	end)
else
	for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
		tooltip:HookScript("OnTooltipSetItem", function(self)
			local _, link = self:GetItem()
			local id = link and tonumber(link:match("item:(%d+)"))
			ns.SafeCall(AddPrice, self, id)
			ns.SafeCall(ns.Crafting.AddCraftWorth, self, id)
		end)
	end
end
