-- What you list of an item you're buying (its purchase session, QuickBuy.lua)
-- and how much of it sells, for the purchase tracker's break-even (BuyInfo.lua).
-- Seeds (Seed.lua) are counted there instead.
--
--   A listing: posted while the item has a session, its ID from the game's
--   "auction created" (or your auctions list, when that doesn't come).
--   Selling: your auctions list gives how many of it are still up; gone from
--   the list before its time is up (or after a "sold" notice) means sold out.
--   Cancelled or expired: the rest comes back, and its share of the deposit is lost.
--
-- Saved with the session: s.listed = { { auctionID, qty, price, deposit, at,
-- length, left, soldSeen } } still up, and s.sold = { n, income, lost } settled.
local _, ns = ...
local AH = C_AuctionHouse

local Listings = {}
ns.Listings = Listings

local PENDING_TIME = 60 -- seconds to wait for a post to be listed
local EXPIRE_GRACE = 120
local STATUS_SOLD = Enum and Enum.AuctionStatus and Enum.AuctionStatus.Sold or 1
local SOLD = Enum and Enum.AuctionHouseNotification and Enum.AuctionHouseNotification.AuctionSold or 4
local EXPIRED = Enum and Enum.AuctionHouseNotification and Enum.AuctionHouseNotification.AuctionExpired or 5

local pending -- { itemID, qty, price, deposit, length, at, after = the newest auction ID known then }

local function Session(id)
	local s = ns.db and ns.db.quickBuy[id]
	if s and (s.bought or 0) > 0 then return s end
	return nil
end

local function Cut() return 1 - ns.QuickBuy.AH_CUT end

-- The listing's outcome into the session's totals: what sold brought in, and
-- the deposit on what didn't was lost.
local function Settle(s, i, how)
	local l = table.remove(s.listed, i)
	local sold = l.qty - l.left
	local st = s.sold or { n = 0, income = 0, lost = 0 }
	s.sold = st
	st.n = st.n + sold
	st.income = st.income + math.floor(sold * l.price * Cut())
	if how ~= "sold" and l.deposit and l.qty > 0 then st.lost = st.lost + math.floor(l.deposit * l.left / l.qty + 0.5) end
	ns.Debug(("listing %s: %d of %d at %s"):format(how, sold, l.qty, ns.Money(l.price)))
end

-- Every tracked listing, with its session: f(s, i, listing); backwards, so f may settle it.
local function Each(f)
	for _, s in pairs(ns.db.quickBuy) do
		if s.listed then
			for i = #s.listed, 1, -1 do f(s, i, s.listed[i]) end
		end
	end
end

local function Find(auctionID)
	local found, at
	Each(function(s, i, l)
		if l.auctionID == auctionID then found, at = s, i end
	end)
	return found, at
end

-- Past their time and not seen since: expired.
local function Sweep()
	local now = time()
	Each(function(s, i, l)
		if now > l.at + l.length + EXPIRE_GRACE and not l.soldSeen then Settle(s, i, "expired") end
	end)
end

local function Owned()
	local list = {}
	if not (AH.GetNumOwnedAuctions and AH.GetOwnedAuctionInfo) then return list end
	for i = 1, AH.GetNumOwnedAuctions() or 0 do
		local ok, a = pcall(AH.GetOwnedAuctionInfo, i)
		if ok and a and a.auctionID then list[#list + 1] = a end
	end
	return list
end

local function NewestID()
	local newest = 0
	for _, a in ipairs(Owned()) do newest = math.max(newest, a.auctionID) end
	return newest
end

local function Add(p, auctionID)
	local s = Session(p.itemID)
	if not s then return end
	s.listed = s.listed or {}
	s.listed[#s.listed + 1] = { auctionID = auctionID, qty = p.qty, price = p.price, deposit = p.deposit,
		at = time(), length = p.length, left = p.qty }
end

if AH and hooksecurefunc and AH.PostCommodity then
	hooksecurefunc(AH, "PostCommodity", function(item, duration, quantity, unitPrice)
		pending = nil
		if ns.Seed and ns.Seed.Posting and ns.Seed.Posting() then return end
		local ok, id = pcall(C_Item.GetItemID, item)
		if not (ok and id and Session(id) and quantity and unitPrice) then return end
		local okD, deposit = pcall(AH.CalculateCommodityDeposit, id, duration, quantity)
		pending = { itemID = id, qty = quantity, price = unitPrice, deposit = okD and deposit or nil,
			length = ns.DurationSeconds(duration), at = time(), after = NewestID() }
	end)
	if AH.ConfirmPostCommodity then
		hooksecurefunc(AH, "ConfirmPostCommodity", function()
			if pending then pending.at = time() end
		end)
	end
end

ns.On("AUCTION_HOUSE_AUCTION_CREATED", function(auctionID)
	local p = pending
	if not (p and auctionID) then return end
	pending = nil
	if time() - p.at < PENDING_TIME then Add(p, auctionID) end
end)

ns.On("AUCTION_HOUSE_POST_ERROR", function() pending = nil end)

ns.On("OWNED_AUCTIONS_UPDATED", function()
	if not ns.db then return end
	local up = {}
	for _, a in ipairs(Owned()) do
		if a.status ~= STATUS_SOLD then up[a.auctionID] = a end
	end
	-- A post the game didn't say was listed: your newest listing of it since,
	-- at that price.
	local p = pending
	if p and time() - p.at < PENDING_TIME then
		local best
		for auctionID, a in pairs(up) do
			if auctionID > p.after and a.itemKey and a.itemKey.itemID == p.itemID and a.buyoutAmount == p.price
				and (a.quantity or 0) <= p.qty and not Find(auctionID) and (not best or auctionID > best) then
				best = auctionID
			end
		end
		if best then
			pending = nil
			Add(p, best)
		end
	end
	local full = not AH.HasFullOwnedAuctionResults or AH.HasFullOwnedAuctionResults()
	local now = time()
	Each(function(s, i, l)
		if not l.auctionID then return end
		local a = up[l.auctionID]
		if a then
			l.left = math.min(l.left, a.quantity or l.left)
		elseif full and now - l.at > 5 then
			-- Gone: sold out, unless its time was up first.
			if now <= l.at + l.length or l.soldSeen then l.left = 0 end
			Settle(s, i, l.left == 0 and "sold" or "expired")
		end
	end)
end)

ns.On("AUCTION_CANCELED", function(auctionID)
	local s, i = Find(auctionID)
	if s then Settle(s, i, "cancelled") end
end)

ns.On("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", function(kind, _, auctionID)
	if not (auctionID and ns.db) then return end
	local s, i = Find(auctionID)
	if not s then return end
	if kind == EXPIRED then
		Settle(s, i, "expired")
	elseif kind == SOLD then
		s.listed[i].soldSeen = true
		-- How many: your auctions list says.
		if ns.atAH and ns.Sales and ns.Sales.QueryOwned then ns.Sales.QueryOwned(1) end
	end
end)

-- The item's listings this session: how many sold and what they brought in
-- (after the cut), the deposits lost, and how many are up and what they'd
-- bring in if they sell.
function Listings.Stats(id)
	local s = ns.db.quickBuy[id]
	if not s then return 0, 0, 0, 0, 0 end
	Sweep()
	local st = s.sold
	local n, income, lost = st and st.n or 0, st and st.income or 0, st and st.lost or 0
	local up, upIncome = 0, 0
	for _, l in ipairs(s.listed or {}) do
		local sold = l.qty - l.left
		n, income = n + sold, income + math.floor(sold * l.price * Cut())
		up, upIncome = up + l.left, upIncome + math.floor(l.left * l.price * Cut())
	end
	return n, income, lost, up, upIncome
end
