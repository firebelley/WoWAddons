-- Your gold, day by day, for the Profit tab's graph (Profit.lua): each
-- character's as the day ended (today: as it is now), all added up. Kept from
-- when each character first logs in with this version.
--   FireAuctionDB.chars["Name - Realm"].gold = { first = day, open = copper
--     (when first seen), days = { [day] = copper } }
local _, ns = ...

local Gold = {}
ns.Gold = Gold

local function Record()
	local c = ns.Sales and ns.Sales.Char and ns.Sales.Char()
	local money = GetMoney and GetMoney()
	if not (c and money) then return end
	local today = ns.Data.Today()
	local g = c.gold
	if not (g and g.first and g.days) then
		g = { first = today, open = money, days = {} }
		c.gold = g
	end
	g.days[today] = money
end
ns.On("PLAYER_LOGIN", Record)
ns.On("PLAYER_MONEY", Record)
ns.On("PLAYER_LOGOUT", Record)

-- The first day kept for any character, or nil.
function Gold.First()
	local first
	for _, c in pairs(ns.db.chars or {}) do
		local g = c.gold
		if g and g.first then first = math.min(first or g.first, g.first) end
	end
	return first
end

-- All your characters' gold at the end of each day from `from` to `to`:
-- { [day] = copper }. Starts the day before the first kept (what they had when
-- first seen); a character not played on a day has what it had last.
function Gold.Series(from, to)
	local out, first = {}, Gold.First()
	if not first then return out end
	for _, c in pairs(ns.db.chars or {}) do
		local g = c.gold
		if g and g.first and g.days then
			local cur, curDay = g.open, nil
			for day, v in pairs(g.days) do
				if day < from and (not curDay or day > curDay) then cur, curDay = v, day end
			end
			for day = math.max(from, first - 1), to do
				cur = g.days[day] or cur
				out[day] = (out[day] or 0) + cur
			end
		end
	end
	return out
end
