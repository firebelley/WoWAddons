-- What you list of an item you're buying (its purchase session, QuickBuy.lua)
-- and how much of it sells, for the purchase tracker's break-even (BuyInfo.lua).
-- Seeds (Seed.lua) are counted there instead.
--
--   A listing: any of your auctions of the item listed since the session's
--   first purchase that isn't a seed, from your auctions list - however it was
--   listed, and even when the game doesn't say "auction created". What you
--   post is noted too, for its deposit and how long it lasts.
--   Selling: your auctions list gives how many of it are still up; gone from
--   the list before its time is up (or after a "sold" notice) means sold out.
--   Cancelled or expired: the rest comes back, and its share of the deposit is lost.
--
-- Saved with the session: s.listed = { { auctionID, qty, price, deposit, at,
-- length, left, soldSeen, house } } still up, s.sold = { n, income, lost } settled,
-- s.after = auctions up to this ID were listed before the session, and
-- s.done = { [auctionID] = time } settled (so they aren't taken up again).
local _, ns = ...
local AH = C_AuctionHouse

local Listings = {}
ns.Listings = Listings

local POST_TIME = 600   -- seconds a post waits to be found in your auctions list
local DONE_TIME = 3 * 86400 -- seconds a settled listing is remembered (longer than any listing lasts)
local EXPIRE_GRACE = 120
local STATUS_SOLD = Enum and Enum.AuctionStatus and Enum.AuctionStatus.Sold or 1
local SOLD = Enum and Enum.AuctionHouseNotification and Enum.AuctionHouseNotification.AuctionSold or 4
local EXPIRED = Enum and Enum.AuctionHouseNotification and Enum.AuctionHouseNotification.AuctionExpired or 5
-- Time left bands (no exact time given): the longest each can be.
local BAND_MAX = { [0] = 1800, [1] = 7200, [2] = 43200, [3] = 172800 }

-- Everything you post, until the game says it's listed or it's found in your
-- auctions list: { itemID, qty, price, deposit, length, at, seed, after = the
-- newest auction known then }, oldest first.
-- (All of them, seeds and other items too, so "auction created" - which only
-- gives the ID - is matched to the right one.)
local posts = {}

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
	if l.auctionID then
		local now = time()
		s.done = s.done or {}
		s.done[l.auctionID] = now
		for id, at in pairs(s.done) do
			if now - at > DONE_TIME then s.done[id] = nil end
		end
	end
	ns.Debug(("listing %s: %d of %d at %s"):format(how, sold, l.qty, ns.Money(l.price)))
end

-- Every tracked listing, with its session: f(s, i, listing, itemID); backwards, so f may settle it.
local function Each(f)
	for id, s in pairs(ns.db.quickBuy) do
		if s.listed then
			for i = #s.listed, 1, -1 do f(s, i, s.listed[i], id) end
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

-- A new session starts after every auction you have now (QuickBuy.lua, on its
-- first purchase): only ones listed since are its listings.
function Listings.StartSession(s)
	s.after = ns.db.newestAuction or 0
	s.done = nil
end

---------------------------------------------------------------------------
-- What you post (from the Sell page; seeds are Seed.lua's)
---------------------------------------------------------------------------
local function Prune()
	local now = time()
	for i = #posts, 1, -1 do
		if now - posts[i].at > POST_TIME then table.remove(posts, i) end
	end
end

-- The oldest post that's this auction: listed after it, the same item, no more
-- of it (some may have sold), at its price (each, or all of them).
local function TakePost(id, a)
	for i, p in ipairs(posts) do
		local price = a.buyoutAmount
		if not p.seed and a.auctionID > p.after and p.itemID == id and (a.quantity or 0) <= p.qty
			and (not price or price == p.price or price == p.price * (a.quantity or 0)) then
			return table.remove(posts, i)
		end
	end
	return nil
end

local function Posted(item, duration, quantity, unitPrice, commodity)
	local ok, id = pcall(C_Item.GetItemID, item)
	local p = { itemID = ok and id or nil, qty = quantity or 1, price = unitPrice, at = time(), after = ns.db and ns.db.newestAuction or 0,
		length = ns.DurationSeconds(duration), seed = ns.Seed and ns.Seed.Posting and ns.Seed.Posting() or nil }
	if commodity and p.itemID and Session(p.itemID) then
		local okD, deposit = pcall(AH.CalculateCommodityDeposit, p.itemID, duration, p.qty)
		p.deposit = okD and deposit or nil
	end
	Prune()
	posts[#posts + 1] = p
end

if AH and hooksecurefunc then
	if AH.PostCommodity then
		hooksecurefunc(AH, "PostCommodity", function(item, duration, quantity, unitPrice)
			Posted(item, duration, quantity, unitPrice, true)
		end)
	end
	if AH.PostItem then
		hooksecurefunc(AH, "PostItem", function(item, duration, quantity, bid, buyout)
			Posted(item, duration, quantity, (buyout and buyout > 0 and buyout) or bid, false)
		end)
	end
end

-- Not listed after all.
ns.On("AUCTION_HOUSE_POST_ERROR", function() table.remove(posts) end)

-- Tracked at once, so one that sells before your auctions list is read again
-- still counts: the oldest post the game hasn't said is listed (it lists them
-- in order). A seed's is Seed.lua's (it hears first).
ns.On("AUCTION_HOUSE_AUCTION_CREATED", function(auctionID)
	if not (auctionID and ns.db) or Find(auctionID) then return end
	ns.db.newestAuction = math.max(ns.db.newestAuction or 0, auctionID)
	Prune()
	if ns.Seed and ns.Seed.Owns and ns.Seed.Owns({ auctionID = auctionID }) then
		for i, p in ipairs(posts) do
			if p.seed then
				table.remove(posts, i)
				break
			end
		end
		return
	end
	local p = table.remove(posts, 1)
	local s = p and not p.seed and p.itemID and Session(p.itemID)
	if not s then return end
	s.listed = s.listed or {}
	s.listed[#s.listed + 1] = { auctionID = auctionID, qty = p.qty, price = p.price, deposit = p.deposit,
		at = p.at, length = p.length, left = p.qty, house = ns.house or "faction" }
end)

---------------------------------------------------------------------------
-- Your auctions list
---------------------------------------------------------------------------
-- One of your auctions of a session's item that isn't tracked yet: a listing,
-- with its post's deposit and length when it was noted.
local function Adopt(s, id, a)
	local p = TakePost(id, a)
	local price = p and p.price or a.buyoutAmount
	if not (price and price > 0) then return end
	local now = time()
	local at, length = now, nil
	if p then
		at, length = p.at, p.length
	else
		-- Not posted from here (or before a reload): it ends within its time left.
		length = a.timeLeftSeconds or BAND_MAX[a.timeLeft] or ns.DurationSeconds(3)
	end
	s.listed = s.listed or {}
	s.listed[#s.listed + 1] = { auctionID = a.auctionID, qty = p and p.qty or a.quantity, price = price,
		deposit = p and p.deposit or nil, at = at, length = length, left = a.quantity, house = ns.house or "faction" }
	ns.Debug(("listing found: %d at %s"):format(a.quantity or 0, ns.Money(price)))
end

ns.On("OWNED_AUCTIONS_UPDATED", function()
	if not ns.db then return end
	local up, ids = {}, {}
	local newest = ns.db.newestAuction or 0
	for _, a in ipairs(Owned()) do
		newest = math.max(newest, a.auctionID)
		if a.status ~= STATUS_SOLD then
			up[a.auctionID] = a
			ids[#ids + 1] = a.auctionID
		end
	end
	ns.db.newestAuction = newest

	-- Your listings of each session's item since it started, oldest first.
	Prune()
	table.sort(ids)
	for _, auctionID in ipairs(ids) do
		local a = up[auctionID]
		local id = a.itemKey and a.itemKey.itemID
		local s = id and Session(id)
		if s and auctionID > (s.after or 0) and not (s.done and s.done[auctionID]) and not Find(auctionID)
			and not (ns.Seed and ns.Seed.Owns and ns.Seed.Owns(a)) then
			Adopt(s, id, a)
		end
	end

	local full = not AH.HasFullOwnedAuctionResults or AH.HasFullOwnedAuctionResults()
	local now = time()
	Each(function(s, i, l, id)
		if not l.auctionID then return end
		local a = up[l.auctionID]
		if a and a.itemKey and a.itemKey.itemID ~= id then
			-- Matched to the wrong post: not this item's. Found again next time.
			table.remove(s.listed, i)
		elseif a then
			l.left = math.min(l.left, a.quantity or l.left)
		elseif full and now - l.at > 5 and (l.house or "faction") == (ns.house or "faction") then
			-- Gone: sold out, unless its time was up first. (Only this auction house's:
			-- the list doesn't have the other one's.)
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
