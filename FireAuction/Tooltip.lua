-- Item tooltips: "Auction house   1g 20s  +12% (7d)".
local _, ns = ...

local function AddPrice(tooltip, itemID)
	if not (ns.db and ns.db.tooltip and itemID) then return end
	local rec = ns.Data.Get(itemID)
	if not (rec and rec.p) then return end

	local right
	if (rec.q or 0) > 0 then
		right = ns.Money(rec.p)
	else
		right = "|cff999999none listed, was|r " .. ns.Money(rec.p)
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
end

local function IsMainTooltip(tooltip)
	return tooltip == GameTooltip or tooltip == ItemRefTooltip
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
		if not IsMainTooltip(tooltip) then return end
		ns.SafeCall(AddPrice, tooltip, data and data.id)
	end)
else
	for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
		tooltip:HookScript("OnTooltipSetItem", function(self)
			local _, link = self:GetItem()
			local id = link and tonumber(link:match("item:(%d+)"))
			ns.SafeCall(AddPrice, self, id)
		end)
	end
end
