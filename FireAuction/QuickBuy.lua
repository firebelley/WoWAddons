-- Quick buy, under the Buy button when you're looking at a commodity (Silk
-- Cloth...): "Want [100]  Up to [1]s [75]c" and one button that buys what's
-- listed at or under that price, up to what you still want - one click, no
-- confirmation popup. The numbers - what reselling or crafting it makes, what
-- you've spent - are in the panel to the right (BuyInfo.lua).
--
-- Every purchase is your own click: the game only lets a purchase start from
-- one. Nothing is bought, searched or retried by itself - it works off the
-- listings on screen, refreshed by you (the same button refreshes when there's
-- nothing to buy) and once after each purchase, like Blizzard's own Buy popup.
-- Each click does one thing: one purchase or one refresh. The game quotes the
-- final price before buying; if it's more than the button said (someone got
-- the cheap ones first), the purchase is cancelled instead.
--
-- With "Check for" ticked and nothing within "Up to" on screen, a click
-- checks the price of N instead of refreshing (typed, or the number that
-- would have bought the most of your recent finds, see BestSize): the price
-- check is a fresh look in itself, so new listings are bought straight from
-- it, a step (~0.6s) ahead of a refresh.
-- If they average more, nothing's bought and the listings refresh (unless the
-- check found the cheapest just as they are on screen) - or, when the price
-- came back cheaper than the screen said (new cheap ones, too few for N), the
-- next click checks the number that fits them instead (see FollowUpSize).
--
-- Quick buy shows once you press Start session for the item. The session -
-- how many you've bought, what they cost, and a log - is kept until you press
-- End session (through /reload and logouts), and counts in the Profit tab of
-- the price window (Ledger.lua). Purchases through Blizzard's own Buy popup
-- count too while it's on.
local _, ns = ...

local QuickBuy = {}
ns.QuickBuy = QuickBuy

local QUOTE_WAIT = 5     -- seconds to wait for the game's price quote
local QUOTE_TIMEOUT = 10 -- seconds to wait for the purchase itself, once confirmed
local RECONFIRMS = 3     -- times a purchase is confirmed again when its price changes (still within "Up to")
local RESENDS = 3        -- times a confirmation the game dropped is sent again

local panel, body, start, button, clear, status, wantBox, coinBoxes
local checkToggle, checkBox, checkHint -- "Check for [N]"
local itemID          -- the commodity on screen
local plan            -- { quantity, total } the button would buy right now
local pending         -- { itemID, quantity, total, stage = "quote"/"buying", at }
local summarized = {} -- [itemID] = how many were bought at the last summary
local boughtNow = {}  -- [itemID] = { count, total } bought since the auction house opened
local outside         -- { itemID, quantity, total } a purchase through Blizzard's Buy popup
local gaveUp          -- { itemID, quantity, total, at } a confirmed purchase given up on (it may still go through)
local LATE = 15       -- seconds such a purchase can still come through and be counted
local LOG_SIZE = 20   -- purchases kept in the session log
local message         -- last result, shown under the button until the next change
local consumed        -- { id, qty, at } just bought: still in the listings until they're refreshed
local resultsAt       -- when the listings on screen came in
-- Lost to someone else: the cheap ones went before the quote, or between the
-- quote and the purchase.
local TAKEN = "|cffff5050Not available|r (someone else bought them)"

-- The lowest price each that sells `count` of them for more than `total`,
-- after the cut of the auction house you're at.
local function RelistPrice(total, count)
	local keep = 1 - ns.Cut()
	local price = math.floor(total / (keep * count)) + 1
	while math.floor(price * count * keep) <= total do price = price + 1 end
	return price
end

local function Settings(id)
	ns.db.quickBuy[id] = ns.db.quickBuy[id] or {}
	return ns.db.quickBuy[id]
end

-- The session lives with the item's settings (saved):
--   active = started (Start session) and not ended
--   bought, spent = how many, and what they cost in all
--   log = { { quantity, total, time() }, ... } newest first
-- Only purchases in a session count (here and in the Profit tab, Ledger.lua):
-- one-off ones through Blizzard's Buy popup don't.
local function Record(id, quantity, total)
	local s = Settings(id)
	if not s.active then return end
	ns.Ledger.Buy(id, quantity, total)
	-- A new session: only what you list from now on is its listings (Listings.lua).
	if (s.bought or 0) == 0 and ns.Listings then ns.Listings.StartSession(s) end
	s.bought = (s.bought or 0) + quantity
	s.spent = (s.spent or 0) + total
	s.boughtEver = (s.boughtEver or 0) + quantity -- never cleared: the market log takes it off (Ladder.lua)
	s.log = s.log or {}
	table.insert(s.log, 1, { quantity, total, time() })
	while #s.log > LOG_SIZE do table.remove(s.log) end
	local visit = boughtNow[id] or { count = 0, total = 0 }
	visit.count, visit.total = visit.count + quantity, visit.total + total
	boughtNow[id] = visit
end

local function ClearSession(id)
	local s = Settings(id)
	s.bought, s.spent, s.log = nil, nil, nil
	-- Seeding results too (Seed.lua); seeds listed before now no longer count.
	s.seed, s.cleared = nil, time()
	-- And what you've listed of it (Listings.lua): still up, they keep counting
	-- in the Profit tab until they end.
	if s.listed and ns.Listings then ns.Listings.Keep(id, s.listed) end
	s.listed, s.sold, s.after, s.done = nil, nil, nil, nil
	summarized[id] = nil
	boughtNow[id] = nil
end

local function StartSession(id)
	ClearSession(id)
	Settings(id).active = true
end

local function EndSession(id)
	ClearSession(id)
	Settings(id).active = nil
end

local function ItemName(id)
	return (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) or ("item " .. id)
end

-- What it usually sells for here: the average of the trend period's daily
-- prices (market prices, from your scans), or the latest scan's.
local function UsualPrice(id)
	local rec = ns.Data.Get(id)
	if not rec then return nil end
	local from, sum, n = ns.Data.Today() - ns.Data.TrendDays(), 0, 0
	for day, price in pairs(rec.d or {}) do
		if day > from then sum, n = sum + price, n + 1 end
	end
	if n > 0 then return math.floor(sum / n + 0.5) end
	return ns.Data.Market(rec)
end

-- What the button would take from each listing on screen, cheapest first:
-- { { price, quantity, take }, ... } - at or under maxPrice, up to quantity,
-- not your own; with "Cheapest listing only" on, only at the lowest of those
-- prices. nil when the listings aren't loaded yet.
local function Walk(id, maxPrice, quantity)
	local AH = C_AuctionHouse
	local rows, count, level = {}, 0, nil
	-- What you just bought is gone from the cheapest, refreshed or not.
	local skip = consumed and consumed.id == id and consumed.qty or 0
	for i = 1, AH.GetNumCommoditySearchResults(id) or 0 do
		local r = AH.GetCommoditySearchResultInfo(id, i)
		if not r then return nil end
		local open = r.quantity - (r.numOwnerItems or 0)
		local gone = math.max(0, math.min(skip, open))
		skip, open = skip - gone, open - gone
		local take = 0
		if maxPrice and r.unitPrice <= maxPrice and count < quantity and not (level and r.unitPrice > level) then
			take = math.max(0, math.min(open, quantity - count))
			if take > 0 and ns.db.quickBuyCheapest and maxPrice ~= math.huge then level = level or r.unitPrice end
		end
		count = count + take
		if r.quantity - gone > 0 then rows[#rows + 1] = { price = r.unitPrice, quantity = r.quantity - gone, take = take } end
	end
	return rows
end

-- What you'd relist at: the cheapest listing left on screen after what the
-- button would buy - yours count, you'd list next to them. nil when the
-- listings aren't loaded.
local function ListedSellPrice(id, maxPrice, quantity)
	for _, row in ipairs(Walk(id, maxPrice, quantity) or {}) do
		if row.take < row.quantity then return row.price end
	end
	return nil
end

local function Remaining(id)
	local want = Settings(id).want
	if not want then return math.huge end
	return math.max(0, want - (Settings(id).bought or 0))
end

-- What the button would buy right now: how many, and what they cost in all.
local function Available(id, maxPrice, quantity)
	local count, total = 0, 0
	for _, row in ipairs(Walk(id, maxPrice, quantity) or {}) do
		count = count + row.take
		total = total + row.take * row.price
	end
	return count, total
end

-- What the cheapest `n` on screen cost in all (not yours, not just bought),
-- or nil if fewer are listed.
local function CheapestTotal(id, n)
	local count, total = 0, 0
	for _, row in ipairs(Walk(id, math.huge, n) or {}) do
		count, total = count + row.take, total + row.take * row.price
	end
	if count < n then return nil end
	return total
end

-- How many to check for, left to the addon: your last cheap finds (purchase
-- attempts for the item, not checks: how many, at what price) replayed
-- against the listings on screen now. A find smaller than N is made up with
-- the cheapest listed, and the check goes through if it all averages within
-- "Up to". The N that would have bought the most in all (the smaller on a
-- tie), up to cap. nil until there are a few finds.
--
-- (Tried against it, a minute each in turn on the same market: the N that
-- buys the most per click counting the follow-up after a miss - much
-- larger. 33 minutes, 1,350 checks: no better, 0.84 items a click to this
-- one's 0.93.)
local CHECK_HISTORY, CHECK_MIN_HISTORY = 50, 3
local FOLLOW_UP_MIN = 2 -- a follow-up for fewer: a copper or two cheaper, not worth a click
local bestKey, bestN
local function BestSize(id, max, cap)
	local list = ns.db.attempts and ns.db.attempts.list
	if not (id and list and max and max > 0 and cap >= 1) then return nil end
	local key = table.concat({ id, max, cap, tostring(resultsAt), consumed and consumed.qty or 0, #list,
		tostring(list[#list]) }, " ")
	if key == bestKey then return bestN end
	local finds, maxQ = {}, 0
	for i = #list, 1, -1 do
		local a = list[i]
		if a.id == id and not a.chk and a.q and a.q > 0 and a.total then
			finds[#finds + 1] = a
			maxQ = math.max(maxQ, a.q)
		end
		if #finds >= CHECK_HISTORY then break end
	end
	local best, most = nil, 0
	if #finds >= CHECK_MIN_HISTORY then
		-- What the cheapest k on screen cost in all, worked out as needed.
		local rows, r, used, fill = Walk(id, math.huge, math.huge) or {}, 1, 0, { [0] = 0 }
		local function Fill(k)
			while #fill < k do
				local row = rows[r]
				if not row then return nil end
				if used < row.take then
					used = used + 1
					fill[#fill + 1] = fill[#fill] + row.price
				else
					r, used = r + 1, 0
				end
			end
			return fill[k]
		end
		local n = 0
		while n < cap do
			n = n + 1
			local wins = 0
			for _, f in ipairs(finds) do
				local k = math.min(f.q, n)
				local padding = Fill(n - k)
				if padding and f.total / f.q * k + padding <= max * n then wins = wins + 1 end
			end
			if wins * n > most then best, most = n, wins * n end
			-- Past the biggest find, every one more is made up from listings
			-- dearer than "Up to": once none would go through, none will.
			if wins == 0 and n >= maxQ then break end
		end
	end
	bestKey, bestN = key, best
	return best
end

-- How many a price check is for: the "Check for" number (s.checkSize), else
-- BestSize; within what you still want and can pay for. nil with "Check for"
-- off (the default; s.check = true when on).
local function CheckSize(id, max)
	local s = Settings(id)
	if not s.check then return nil end
	local cap = math.min(Remaining(id), math.floor(GetMoney() / max))
	if s.checkSize then
		local n = math.min(s.checkSize, cap)
		if n < 1 then return nil end
		return n
	end
	local n = BestSize(id, max, cap)
	if not n or n < 1 then return nil end
	return n
end

-- "Silk Cloth: bought 100 for 1g 75s (1s 75c each). Break-even: 1s 84c each."
-- Once per batch of purchases. When the session holds more than this visit's
-- purchases: "bought 4 for 32s (8s each) - 26 this session, break-even 8s 19c
-- each." (break-even is for the whole session).
local function Summary(id)
	local s = Settings(id)
	local count = s.bought or 0
	if count <= 0 or summarized[id] == count then return end
	summarized[id] = count
	local total = s.spent or 0
	local visit = boughtNow[id]
	local name, breakEven = ItemName(id), ns.Money(RelistPrice(total, count))
	if visit and visit.count > 0 and visit.count < count then
		ns.Print(("|cffffd100%s:|r bought %d for %s (%s each) - %d this session, break-even %s each."):format(name,
			visit.count, ns.Money(visit.total), ns.Money(math.floor(visit.total / visit.count + 0.5)), count, breakEven))
	else
		ns.Print(("|cffffd100%s:|r bought %d for %s (%s each). Break-even: %s each."):format(name, count,
			ns.Money(total), ns.Money(math.floor(total / count + 0.5)), breakEven))
	end
end

local function BlizzardDialogOpen()
	local dialog = AuctionHouseFrame and AuctionHouseFrame.BuyDialog
	return dialog and dialog:IsShown()
end

local function SetCoinBoxes(boxes, copper)
	local g, s, c = "", "", ""
	if copper then
		g = copper >= 10000 and tostring(math.floor(copper / 10000)) or ""
		s, c = tostring(math.floor(copper / 100) % 100), tostring(copper % 100)
	end
	-- Only on a change, so a box you're typing in isn't rewritten.
	if boxes[1]:GetText() ~= g then boxes[1]:SetText(g) end
	if boxes[2]:GetText() ~= s then boxes[2]:SetText(s) end
	if boxes[3]:GetText() ~= c then boxes[3]:SetText(c) end
end

local function SetCoins(max) SetCoinBoxes(coinBoxes, max or 0) end

-- After a purchase the listings still show what was just bought until the
-- refreshed ones come in, so the button stays greyed out until they do, or
-- HOLD_MAX passes.
local HOLD_MAX = 3
local holdSince               -- holding since (GetTime)
local holdText                -- the button's text meanwhile
local refreshSentAt           -- when the last refresh went out
local staleSince              -- a purchase finished: the listings on screen are out of date until refreshed
local searchSentAt            -- when any search for listings last went out (ours or the auction house's own)
local mode                    -- what a click on the button does now: "buy", "check" or "refresh"
local checkPlan               -- { quantity, expected } a "check" click's price check
local followUp                -- { id, quantity, at } the next check, after one that found new cheap ones
local FOLLOW_UP_WINDOW = 2    -- seconds it's offered before the listings refresh instead
local REFRESH_ICON = "|TInterface\\Buttons\\UI-RefreshButton:16:16:0:0|t "

-- Never act on listings that are about to be replaced or are old: while a
-- search is out (a purchase then waits behind it anyway, and would be sized
-- from the listings it replaces), the button is greyed out; once they're
-- older than OLD_AFTER, it refreshes instead of buying.
local SEARCH_MAX = 2  -- seconds a search counts as out without an answer
local OLD_AFTER = 5   -- seconds before listings are too old to buy from

local function Searching()
	return searchSentAt and (not resultsAt or resultsAt < searchSentAt) and GetTime() - searchSentAt < SEARCH_MAX
end

local function Old()
	return not resultsAt or GetTime() - resultsAt > OLD_AFTER
end

local function Held()
	if not holdSince then return false end
	if GetTime() - holdSince > HOLD_MAX then
		holdSince = nil
		return false
	end
	return true
end

-- The button's text, from what's listed now.
local function Update()
	if not (panel and panel:IsShown() and itemID) then return end
	local s = Settings(itemID)
	-- No session: just its Start session button.
	local active = s.active or pending ~= nil
	body:SetShown(active)
	start:SetShown(not active)
	if not active then
		plan, mode = nil, nil
		return
	end
	local max = s.max
	if checkBox then
		local best = max and max > 0 and resultsAt
			and BestSize(itemID, max, math.min(Remaining(itemID), math.floor(GetMoney() / max)))
		checkHint:SetText(best and tostring(best) or "")
		checkHint:SetShown(checkBox:GetText() == "" and not checkBox:HasFocus())
	end
	plan, mode, checkPlan = nil, nil, nil
	local text, enabled = nil, false
	-- Waiting on the auction house (a purchase, new listings, Blizzard's own
	-- dialog): End session waits too. Not for "Got all", "Set the most to
	-- pay" or "Not enough money" - ending the session is the way out of those.
	local busy = pending ~= nil
	if pending then
		text = pending.stage == "quote" and "Checking the price..." or "Buying..."
	elseif not max or max <= 0 then
		text = "Set the most to pay"
	elseif Remaining(itemID) <= 0 then
		text = ("Got all %d"):format(s.want)
	elseif Held() then
		-- The listings are out of date until refreshed: not "Buy..." from them.
		text = holdText
		busy = true
	else
		local count, total = Available(itemID, max, Remaining(itemID))
		local old = staleSince or Old()
		local n = count <= 0 and resultsAt and not staleSince and CheckSize(itemID, max)
		local f = followUp
		if n and f and f.id == itemID and GetTime() - f.at < FOLLOW_UP_WINDOW then
			n = math.min(f.quantity, math.min(Remaining(itemID), math.floor(GetMoney() / max)))
			if n < 1 then n = nil end
		end
		if n then
			-- Nothing within "Up to" on screen: check the price of N.
			checkPlan = { quantity = n, expected = CheapestTotal(itemID, n) }
			text = REFRESH_ICON .. ("Check for %d"):format(n)
			mode, enabled = "check", not BlizzardDialogOpen()
		elseif old or count <= 0 then
			-- Nothing to buy from these listings: the button refreshes them.
			text = REFRESH_ICON .. (old and "Refresh (stale)" or "Refresh")
			mode, enabled = "refresh", not BlizzardDialogOpen()
		elseif total > GetMoney() then
			text = "Not enough money (" .. ns.Money(total) .. ")"
		elseif BlizzardDialogOpen() then
			text = ("Buy %d for %s"):format(count, ns.Money(total))
			busy = true
		else
			text = ("Buy %d for %s"):format(count, ns.Money(total))
			-- Usable even while the auction house is busy with another request
			-- (your auctions list...): the game holds the purchase and sends it the
			-- moment it can (one it drops instead is given up on right away -
			-- AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED).
			plan = { quantity = count, total = total }
			mode, enabled = "buy", true
		end
		-- New listings on the way: wait for them (a refresh then would only
		-- queue behind it, and hold up the purchase after).
		if mode and Searching() then plan, mode, checkPlan, enabled, busy = nil, nil, nil, false, true end
		if (mode == "check" or mode == "refresh") and not enabled then busy = true end -- Blizzard's dialog
	end
	if text then button:SetText(text) end
	if ns.debug and enabled ~= button:IsEnabled() then
		ns.Debug(("quick buy: button %s (%s)"):format(enabled and "on" or "off", mode or text or "?"))
	end
	button:SetEnabled(enabled)
	clear:SetEnabled(not busy)

	local line = message
	local count = s.bought or 0
	if pending and pending.check and pending.stage == "quote" then
		line = ("Checking %d within %s each"):format(pending.quantity, ns.Money(max or 0))
	elseif pending then
		-- What this click is buying, while the button says "Checking the price...".
		line = ("Buying %d for %s"):format(pending.quantity, ns.Money(pending.total))
	elseif not line and count > 0 then
		line = s.want and ("Bought %d of %d"):format(count, s.want) or ("Bought %d"):format(count)
	end
	status:SetText(line or "")
end

-- Refresh the listings. If the game drops the request (the auction house
-- was still busy), answers it without listings (right after a failed
-- purchase it does), or no listings have come back a little later, it's
-- sent again.
local AFTER_PURCHASE = 0.2 -- seconds after a purchase before refreshing: the game finishes it first
local RESEND_AFTER = 1.5   -- seconds without listings before sending the refresh again (they take ~0.2s)
local RESENDS = 3          -- times a refresh answered without listings is sent again, at most
local refreshWaiting = false -- resend when the auction house is ready
local refreshRetried = false
local refreshResends = 0
local refreshOut, refreshAnswered = false, false -- the refresh went out to the auction house / was answered
local refreshCount = 0

local function Refresh(retry, empty)
	local frame = AuctionHouseFrame
	if not (frame and frame.RefreshSearchResults and AuctionHouseSearchContext and itemID) then return end
	refreshWaiting = false
	refreshSentAt, refreshRetried = GetTime(), retry and true or false
	refreshResends = retry and refreshResends + 1 or 0
	refreshOut, refreshAnswered = false, false
	searchSentAt = refreshSentAt
	refreshCount = refreshCount + 1
	ns.Debug(("quick buy: refresh%s"):format(retry and " (again)" or ""))
	pcall(frame.RefreshSearchResults, frame, AuctionHouseSearchContext.BuyCommodities,
		C_AuctionHouse.MakeItemKey(itemID))
	-- No answer a little later (the list stuck on "Searching..."): once more.
	-- (Not "all pages loaded": a long list never is, and that would send a
	-- second refresh every time, holding up a purchase behind it.)
	if (retry and not empty) or not C_Timer then return end
	local count, id, sent = refreshCount, itemID, refreshSentAt
	C_Timer.After(RESEND_AFTER, function()
		if count == refreshCount and id == itemID and not pending
			and not (resultsAt and resultsAt >= sent) then
			Refresh(true)
		end
	end)
end

-- The refresh went out, and the next answer is its. Listings come in with
-- the answer, in the same moment: if they didn't, it's sent again now rather
-- than RESEND_AFTER later.
ns.On("AUCTION_HOUSE_THROTTLED_MESSAGE_SENT", function()
	if refreshSentAt and not pending then refreshOut = true end
end)

ns.On("AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED", function()
	if not (refreshSentAt and refreshOut and not refreshAnswered and not pending and C_Timer) then return end
	refreshAnswered = true
	local count, id, sent = refreshCount, itemID, refreshSentAt
	C_Timer.After(0, function()
		if count == refreshCount and id == itemID and not pending and refreshResends < RESENDS
			and not (resultsAt and resultsAt >= sent) then
			ns.Debug("quick buy: answered without listings")
			Refresh(true, true)
		end
	end)
end)

---------------------------------------------------------------------------
-- Market log, for working out a better "Check for" size: the cheapest
-- listings each time they come in, and every price check (found or not).
--   ns.db.market = {
--     snaps = { { at, id, max, mine, rows = { price, quantity, ... } } },
--     checks = { { at, id, n, max, expected, quoted, hit, age, follow } } }
--   at: seconds (as time(), to the ms); rows: the cheapest SNAP_ROWS, not
--   yours; expected: the cheapest n on screen in all; quoted: the game's
--   price for n (nil: none); age: how old the listings were at the click;
--   follow: a follow-up check; mine: how many of it you've bought in all.
---------------------------------------------------------------------------
local SNAPS_KEPT, CHECKS_KEPT, SNAP_ROWS = 4000, 8000, 20
local clockBase = time() - GetTime()

local function Stamp() return math.floor((clockBase + GetTime()) * 1000 + 0.5) / 1000 end

local function MarketDB()
	local m = ns.db.market
	if type(m) ~= "table" then
		m = { snaps = {}, checks = {} }
		ns.db.market = m
	end
	return m
end

local function Keep(list, entry, kept)
	list[#list + 1] = entry
	while #list > kept do table.remove(list, 1) end
end

local function Snapshot(id)
	local AH = C_AuctionHouse
	local n = id and AH.GetNumCommoditySearchResults(id) or 0
	if n == 0 then return end
	local rows = {}
	for i = 1, math.min(n, SNAP_ROWS) do
		local r = AH.GetCommoditySearchResultInfo(id, i)
		if not r then break end
		local open = r.quantity - (r.numOwnerItems or 0)
		if open > 0 then
			rows[#rows + 1] = r.unitPrice
			rows[#rows + 1] = open
		end
	end
	local snap = { at = Stamp(), id = id, max = Settings(id).max, mine = Settings(id).boughtEver or 0, rows = rows }
	Keep(MarketDB().snaps, snap, SNAPS_KEPT)
	if ns.Ladder then ns.Ladder.Snapped(id, snap.at, snap.mine, rows) end
end

local function LogCheck(p, quoted, hit)
	Keep(MarketDB().checks, { at = Stamp(), id = p.itemID, n = p.quantity, max = Settings(p.itemID).max,
		expected = p.expected, quoted = quoted, hit = hit, age = p.age, follow = p.follow }, CHECKS_KEPT)
end

-- New listings: after a purchase, the refreshed ones are in and the button can
-- be used again. Either way the button follows them now, not at the next tick.
-- Only "received" means new listings came in: "updated" also fires the moment
-- a refresh goes out (the old ones are cleared) and as more pages load.
local function Refreshed()
	resultsAt = GetTime()
	if itemID and Settings(itemID).active then ns.SafeCall(Snapshot, itemID) end
	if refreshSentAt and consumed and refreshSentAt >= consumed.at then consumed = nil end
	if holdSince and refreshSentAt and refreshSentAt >= holdSince then holdSince = nil end
	if staleSince and searchSentAt and searchSentAt >= staleSince then staleSince = nil end
	ns.SafeCall(Update)
end
ns.On("COMMODITY_SEARCH_RESULTS_RECEIVED", Refreshed)
ns.On("COMMODITY_SEARCH_RESULTS_UPDATED", function(id)
	if id == itemID then ns.SafeCall(Update) end
end)

ns.On("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED", function()
	if pending then return end -- a purchase (handled further down)
	-- Most likely ours, if we just sent one - unless a newer search went out
	-- since (yours, from the list's own refresh button): that one replaced it.
	if refreshSentAt and searchSentAt == refreshSentAt and GetTime() - refreshSentAt < 2 and not refreshRetried then
		refreshSentAt, refreshWaiting = nil, true
		local ready = C_AuctionHouse.IsThrottledMessageSystemReady
		if not ready or ready() then Refresh(true) end
	end
end)

ns.On("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function()
	if refreshWaiting then Refresh(true) end
end)

-- /fah debug: what the auction house does around a purchase and refresh.
for _, event in ipairs({ "AUCTION_HOUSE_THROTTLED_MESSAGE_SENT", "AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED",
	"AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED", "AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED",
	"AUCTION_HOUSE_THROTTLED_SYSTEM_READY", "COMMODITY_SEARCH_RESULTS_UPDATED", "COMMODITY_SEARCH_RESULTS_RECEIVED",
	"COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE", "COMMODITY_PURCHASE_SUCCEEDED",
	"COMMODITY_PURCHASE_FAILED" }) do
	ns.On(event, function(...)
		if not ns.debug then return end
		local args = {}
		for i = 1, select("#", ...) do args[#args + 1] = tostring((select(i, ...))) end
		ns.Debug(("%.2f %s %s"):format(GetTime() % 100, event:lower(), table.concat(args, " ")))
	end)
end

---------------------------------------------------------------------------
-- Every purchase attempt, for /fah attempts: how old the listings were at the
-- click, when the price check and the confirmation went out, and how it ended.
--   ns.db.attempts = { since, refreshes, list = { { t, id, q (how many),
--     total, limit, age, qs, qr, cs, r (seconds after the click: price check
--     sent, quoted, confirmation sent, ended), quoted, how, why }, ... } }
--   how: "ok", "quote" (gone before the price check), "buy" (gone between it
--   and the purchase), "dropped", "timeout"; chk: from a "Check for" click
--   (only those that found them within "Up to" - db.checks counts them all)
---------------------------------------------------------------------------
local ATTEMPTS_KEPT = 2000
local attempt -- the one going on

local function AttemptsDB()
	local a = ns.db.attempts
	if type(a) ~= "table" then
		a = { since = time(), refreshes = 0, list = {} }
		ns.db.attempts = a
	end
	return a
end

local function AttemptStart(p)
	attempt = { t = time(), id = p.itemID, q = p.quantity, total = p.total, limit = p.limit, click = GetTime(), chk = p.check,
		age = resultsAt and math.floor((GetTime() - resultsAt) * 1000 + 0.5) / 1000 or nil }
end

local function Since(a)
	return math.floor((GetTime() - a.click) * 1000 + 0.5) / 1000
end

local function AttemptEnd(why)
	local a = attempt
	if not a then return end
	attempt = nil
	a.r = Since(a)
	a.why = why
	if not why then a.how = "ok"
	elseif why:find("^quoted") or why:find("unavailable") then a.how = "quote"
	elseif why:find("confirming") or why:find("purchase failed") then a.how = "buy"
	elseif why:find("dropped") then a.how = "dropped"
	else a.how = "timeout" end
	a.click = nil
	local list = AttemptsDB().list
	list[#list + 1] = a
	while #list > ATTEMPTS_KEPT do table.remove(list, 1) end
end

-- The price check and the confirmation going out, and the quote coming back.
ns.On("AUCTION_HOUSE_THROTTLED_MESSAGE_SENT", function()
	local a = attempt
	if not (a and pending) then return end
	if pending.stage == "quote" and not a.qs then a.qs = Since(a)
	elseif pending.stage == "buying" and not a.cs then a.cs = Since(a) end
end)
ns.On("COMMODITY_PRICE_UPDATED", function(_, totalPrice)
	local a = attempt
	if a and pending and not a.qr then a.qr, a.quoted = Since(a), totalPrice end
end)

local function Median(t)
	if #t == 0 then return nil end
	table.sort(t)
	return t[math.floor((#t + 1) / 2)]
end

function QuickBuy.PrintAttempts()
	local db = AttemptsDB()
	local list = db.list
	if #list == 0 then
		ns.Print("no purchase attempts recorded yet.")
		return
	end
	local n, items, how = 0, 0, {}
	local small, smallOK, big, bigOK = 0, 0, 0, 0
	local ages, sent = {}, {}
	local chk, chkOK, chkItems = 0, 0, 0
	for _, a in ipairs(list) do
		if a.chk then
			chk = chk + 1
			if a.how == "ok" then chkOK, chkItems = chkOK + 1, chkItems + (a.q or 0) end
		end
		n = n + 1
		how[a.how] = (how[a.how] or 0) + 1
		local ok = a.how == "ok"
		if ok then items = items + (a.q or 0) end
		if (a.q or 0) >= 10 then big, bigOK = big + 1, bigOK + (ok and 1 or 0)
		else small, smallOK = small + 1, smallOK + (ok and 1 or 0) end
		if a.age then ages[#ages + 1] = a.age end
		if a.cs then sent[#sent + 1] = a.cs end
	end
	ns.Print(("%d purchase attempts since %s, %d refreshes:"):format(n, date("%b %d %H:%M", db.since), db.refreshes or 0))
	print(("  bought: %d (%d items)"):format(how.ok or 0, items))
	print(("  gone before the price check: %d"):format(how.quote or 0))
	print(("  gone before the purchase: %d"):format(how.buy or 0))
	if (how.dropped or 0) + (how.timeout or 0) > 0 then
		print(("  no answer: %d"):format((how.dropped or 0) + (how.timeout or 0)))
	end
	print(("  1-9 at once: %d of %d bought;  10+: %d of %d"):format(smallOK, small, bigOK, big))
	if (db.checks or 0) > 0 then
		print(("  price checks: %d, found %d within Up to, bought %d (%d items)"):format(db.checks, chk, chkOK, chkItems))
	end
	local age, cs = Median(ages), Median(sent)
	if age then print(("  listings at your click: %.2fs old (median)"):format(age)) end
	if cs then print(("  purchase sent: %.2fs after your click (median)"):format(cs)) end
end

function QuickBuy.ClearAttempts()
	ns.db.attempts = nil
	AttemptsDB()
end

-- Done with a purchase, however it went: close it on the game's side (like
-- Blizzard's Buy popup does whenever it closes - an open one can hold back
-- the refresh, leaving the list stuck on "Searching..."), then refresh a
-- moment later, once the game has finished with it.
local function Finish(text, why)
	if why then ns.Debug("quick buy: not bought - " .. why) end
	AttemptEnd(why)
	if pending then pcall(C_AuctionHouse.CancelCommoditiesPurchase) end
	-- Confirmed but given up on: if it goes through after all, it's still counted.
	if pending and pending.stage == "buying" and not pending.done then
		gaveUp = { itemID = pending.itemID, quantity = pending.quantity, total = pending.total, at = GetTime() }
	end
	pending = nil
	message = text
	holdSince = GetTime()
	-- Bought or not, the listings on screen are out of date: until refreshed
	-- ones come in, the button refreshes instead of buying from them.
	staleSince = holdSince
	holdText = text and "Not bought" or "Buying..."
	if C_Timer then
		-- A refresh sent in the same moment the purchase ends gets no listings
		-- back (the list stays on "Searching...").
		C_Timer.After(AFTER_PURCHASE, function()
			if not pending then Refresh() end
		end)
	else
		Refresh()
	end
	Update()
end

-- "Purchase successful!" after the status line (see Flash).
local done

local function HideDone()
	if done then
		done.anim:Stop()
		done:Hide()
	end
end

local function Buy()
	if pending or not itemID then return end
	Update() -- the plan from the listings as they are this moment
	if not plan then return end
	-- limit: the most it may cost in all - "Up to" for each, on average. If
	-- someone buys some of the cheapest first, the price quoted for the rest
	-- is higher than shown, but still bought while it averages within that.
	local max = Settings(itemID).max or 0
	pending = { itemID = itemID, quantity = plan.quantity, total = plan.total, limit = max * plan.quantity,
		stage = "quote", at = GetTime() }
	message = nil
	HideDone()
	AttemptStart(pending)
	C_AuctionHouse.StartCommoditiesPurchase(itemID, plan.quantity)
	Update()
end

-- A "Check for" click: the price of N, bought if it averages
-- within "Up to".
local function Check()
	if pending or not itemID then return end
	Update()
	if not checkPlan then return end
	local max = Settings(itemID).max or 0
	local n = checkPlan.quantity
	local follow = followUp ~= nil and followUp.id == itemID and followUp.quantity == n
	followUp = nil
	pending = { itemID = itemID, quantity = n, total = max * n, limit = max * n, stage = "quote", at = GetTime(),
		check = true, expected = checkPlan.expected, follow = follow or nil,
		age = resultsAt and math.floor((GetTime() - resultsAt) * 1000 + 0.5) / 1000 or nil }
	message = nil
	HideDone()
	local db = AttemptsDB()
	db.checks = (db.checks or 0) + 1
	AttemptStart(pending)
	C_AuctionHouse.StartCommoditiesPurchase(itemID, n)
	Update()
end

-- A price check quoted `gap` less than the cheapest N on screen: new cheap
-- ones came, too few to bring N within "Up to". The most that would fit, if
-- they're within it at all: the largest k whose cheapest k on screen, less
-- that gap, average within "Up to". (Exact when what they pushed out costs
-- the same; a check of that many buys them all, and some of the cheapest on
-- screen with them.) nil under 2: a copper or two cheaper - not worth a click.
local function FollowUpSize(id, max, gap, below)
	local best
	for k = 1, below - 1 do
		local total = CheapestTotal(id, k)
		if not total then break end
		if total - gap <= max * k then best = k end
	end
	if best and best >= FOLLOW_UP_MIN then return best end
end

-- A price check that found nothing within "Up to": not bought, and not a
-- loss either (not kept as an attempt). The listings refresh, unless the
-- check found the cheapest just as they are on screen - or it found new cheap
-- ones: then the next click checks for the number that fits them. A
-- follow-up that misses the same way gets one too, smaller each time. Not
-- clicked in time: the listings refresh. (The market log: a first follow-up
-- found cheap ones half the time - about 7 bought a click, an ordinary check
-- about 1; the next ones about 2.)
local function CheckMissed(quoted)
	ns.Debug(("quick buy: check - %s for %d"):format(quoted and ns.Money(quoted) or "none", pending.quantity))
	LogCheck(pending, quoted, false)
	attempt = nil
	local same = quoted ~= nil and quoted == pending.expected and not Old()
	local follow
	if quoted and pending.expected and quoted < pending.expected and not Old() then
		local max = Settings(pending.itemID).max or 0
		follow = max > 0 and FollowUpSize(pending.itemID, max, pending.expected - quoted, pending.quantity)
	end
	pcall(C_AuctionHouse.CancelCommoditiesPurchase)
	local id = pending.itemID
	pending = nil
	message = nil
	if follow then
		ns.Debug(("quick buy: new cheap ones - checking for %d next"):format(follow))
		local f = { id = id, quantity = follow, at = GetTime() }
		followUp = f
		if C_Timer then
			C_Timer.After(FOLLOW_UP_WINDOW, function()
				if followUp ~= f then return end
				followUp = nil
				if not pending then
					staleSince = GetTime()
					Refresh()
				end
				Update()
			end)
		end
	elseif not same then
		-- Greyed until the refresh goes out (as after a purchase, see Finish).
		staleSince = GetTime()
		holdSince, holdText = staleSince, "Checking the price..."
		if C_Timer then
			C_Timer.After(AFTER_PURCHASE, function()
				if not pending then Refresh() end
			end)
		else
			Refresh()
		end
	end
	Update()
end

-- One click, one thing: buy what's listed within "Up to", or refresh when
-- there's nothing to buy (or check the price, see Check).
local function Click()
	if pending or not itemID then return end
	Update()
	if mode == "check" then
		Check()
	elseif mode == "refresh" then
		message = nil
		local db = AttemptsDB()
		db.refreshes = (db.refreshes or 0) + 1
		Refresh()
		Update()
	elseif mode == "buy" then
		Buy()
	end
end

-- Confirm the purchase. The game may queue it (the auction house still busy)
-- and then drop it for another request: it's sent again (see below).
local function Confirm()
	pending.at, pending.confirmSent, pending.confirmWhenReady = GetTime(), false, false
	C_AuctionHouse.ConfirmCommoditiesPurchase(pending.itemID, pending.quantity)
end

ns.On("COMMODITY_PRICE_UPDATED", function(unitPrice, totalPrice)
	if not pending and outside then outside.total = totalPrice end
	if not pending then return end
	local ok = totalPrice <= pending.limit and totalPrice <= GetMoney()
	if pending.stage == "buying" then
		-- A new quote after confirming: the price changed in between (someone
		-- bought some first), and the game waits to be told again. Still the
		-- same purchase: confirmed again (a few times at most) while it's
		-- still within "Up to", otherwise given up on.
		pending.total = totalPrice
		if not ok then
			return Finish(TAKEN, ("price changed after confirming: %s for %d, limit %s"):format(ns.Money(totalPrice),
				pending.quantity, ns.Money(pending.limit)))
		end
		pending.reconfirms = (pending.reconfirms or 0) + 1
		if pending.reconfirms > RECONFIRMS then
			return Finish(TAKEN, "price kept changing after confirming")
		end
		ns.Debug(("quick buy: price changed after confirming, confirming again at %s"):format(ns.Money(totalPrice)))
		Confirm()
		return Update()
	end
	if not ok and pending.check then return CheckMissed(totalPrice) end
	if pending.check and pending.stage == "quote" then LogCheck(pending, totalPrice, true) end
	if not ok then
		return Finish(TAKEN, ("quoted %s for %d, limit %s"):format(ns.Money(totalPrice), pending.quantity,
			ns.Money(pending.limit))) -- closes it without buying
	end
	pending.stage, pending.total = "buying", totalPrice
	Confirm()
	Update()
end)

-- The confirmation went out to the auction house.
ns.On("AUCTION_HOUSE_THROTTLED_MESSAGE_SENT", function()
	if pending and pending.stage == "buying" then pending.confirmSent = true end
end)

-- The confirmation was dropped before it went out (the game dropped it from
-- its queue for another request): the price you were quoted still stands, so
-- send it again as soon as the auction house is ready - still the same
-- purchase, from the same click.
ns.On("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED", function()
	if not (pending and pending.stage == "buying" and not pending.confirmSent) then return end
	pending.resends = (pending.resends or 0) + 1
	if pending.resends > RESENDS then
		return Finish("|cffff5050Not bought:|r no answer from the auction house", "the confirmation kept being dropped")
	end
	ns.Debug("quick buy: confirmation dropped, sending it again when the auction house is ready")
	pending.at, pending.confirmWhenReady = GetTime(), true
end)

ns.On("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function()
	if pending and pending.confirmWhenReady then Confirm() end
end)

-- The purchase we just started was dropped: no quote will come, so don't
-- wait out the timeout.
ns.On("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED", function()
	if pending and pending.stage == "quote" and GetTime() - pending.at < 2
		and not (refreshSentAt and refreshSentAt > pending.at) then
		Finish("|cffff5050Not bought:|r no answer from the auction house", "the price check was dropped")
	end
end)

ns.On("COMMODITY_PRICE_UNAVAILABLE", function()
	if not pending then return end
	if pending.check and pending.stage == "quote" then return CheckMissed(nil) end
	Finish(TAKEN, "the game says the price is unavailable")
end)

-- A purchase went through: the button flashes gold, and "Purchase
-- successful!" shows after the status line for a moment.
local flash

local function Flash()
	if not (panel and panel:IsVisible() and button.CreateAnimationGroup) then return end
	if not flash then
		local t = button:CreateTexture(nil, "OVERLAY")
		t:SetTexture("Interface\\Buttons\\UI-Panel-Button-Highlight")
		t:SetTexCoord(0, 0.625, 0, 0.6875)
		t:SetBlendMode("ADD")
		t:SetVertexColor(1, 0.8, 0.2)
		t:SetAllPoints()
		t:SetAlpha(0)
		local g = t:CreateAnimationGroup()
		local on = g:CreateAnimation("Alpha")
		on:SetOrder(1)
		on:SetDuration(0.08)
		on:SetFromAlpha(0)
		on:SetToAlpha(1)
		local off = g:CreateAnimation("Alpha")
		off:SetOrder(2)
		off:SetDuration(0.6)
		off:SetFromAlpha(1)
		off:SetToAlpha(0)
		flash = g
	end
	flash:Stop()
	flash:Play()

	if not done then
		local text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		text:SetTextColor(0.25, 1, 0.25)
		text:SetText("Purchase successful!")
		text:Hide()
		local g = text:CreateAnimationGroup()
		local fade = g:CreateAnimation("Alpha")
		fade:SetStartDelay(1)
		fade:SetDuration(0.5)
		fade:SetFromAlpha(1)
		fade:SetToAlpha(0)
		g:SetScript("OnFinished", function() text:Hide() end)
		text.anim = g
		done = text
	end
	HideDone()
	done:ClearAllPoints()
	done:SetPoint("LEFT", status, "LEFT", (status:GetStringWidth() or 0) + 8, 0)
	done:Show()
	done.anim:Play()
end

ns.On("COMMODITY_PURCHASE_SUCCEEDED", function()
	if not pending and outside and outside.total then
		-- Bought through Blizzard's Buy popup: counts toward the session too.
		Record(outside.itemID, outside.quantity, outside.total)
		outside = nil
		return Update()
	end
	if not pending and gaveUp then
		-- One given up on went through after all.
		local g = gaveUp
		gaveUp = nil
		if GetTime() - g.at > LATE then return end
		Record(g.itemID, g.quantity, g.total)
		ns.Print(("bought %d %s for %s after all"):format(g.quantity, ItemName(g.itemID), ns.Money(g.total)))
		message = nil
		return Update()
	end
	if not (pending and pending.stage == "buying") then return end
	pending.done = true
	local id, quantity, total = pending.itemID, pending.quantity, pending.total
	Record(id, quantity, total)
	local more = consumed and consumed.id == id and consumed.qty or 0
	consumed = { id = id, qty = more + quantity, at = GetTime() }
	if PlaySound and SOUNDKIT then PlaySound(SOUNDKIT.LOOT_WINDOW_COIN_SOUND) end
	local want = Settings(id).want
	local left = want and math.max(0, want - Settings(id).bought)
	ns.Print(("bought %d %s for %s%s"):format(quantity, ItemName(id), ns.Money(total),
		left and (left > 0 and (" (%d more to go)"):format(left) or " - that's all you wanted") or ""))
	if left == 0 then Summary(id) end
	Finish(nil)
	ns.SafeCall(Flash) -- after Finish: the status line says what was bought by now
end)

ns.On("COMMODITY_PURCHASE_FAILED", function()
	if not pending then
		outside, gaveUp = nil, nil
		return
	end
	Finish(TAKEN, "the game says the purchase failed")
end)

-- Purchases through Blizzard's Buy popup: what it starts (and confirms) and
-- the price the game quotes for it. (Quick buy's own are `pending`.)
if C_AuctionHouse and C_AuctionHouse.StartCommoditiesPurchase then
	hooksecurefunc(C_AuctionHouse, "StartCommoditiesPurchase", function(id, quantity)
		gaveUp = nil -- a new purchase: a success from here on is that one's
		if not pending then outside = { itemID = id, quantity = quantity } end
	end)
	hooksecurefunc(C_AuctionHouse, "ConfirmCommoditiesPurchase", function(id, quantity)
		if not pending and outside and outside.itemID == id and quantity then outside.quantity = quantity end
	end)
	hooksecurefunc(C_AuctionHouse, "CancelCommoditiesPurchase", function()
		if not pending then outside = nil end
	end)
	-- The auction house's own searches and refreshes bring fresh listings too.
	for _, fn in ipairs({ "SendSearchQuery", "RefreshCommoditySearchResults" }) do
		if C_AuctionHouse[fn] then
			hooksecurefunc(C_AuctionHouse, fn, function()
				searchSentAt = GetTime()
				ns.SafeCall(Update)
			end)
		end
	end
end

---------------------------------------------------------------------------
-- For the panel on the right (BuyInfo.lua)
---------------------------------------------------------------------------
QuickBuy.RelistPrice = RelistPrice

-- Your own resale price for an item (copper), or nil: the "Target" you set in
-- the panel on the right (BuyInfo.lua). Kept through End session, like Want and Up to.
function QuickBuy.Target(id)
	local s = ns.db.quickBuy[id]
	return s and s.target
end
function QuickBuy.SetTarget(id, price)
	Settings(id).target = price and price > 0 and math.floor(price) or nil
end

-- Every item with a session on, by name: { { id, bought, spent }, ... }
function QuickBuy.Sessions()
	local list = {}
	for id, s in pairs(ns.db.quickBuy) do
		if s.active then list[#list + 1] = { id = id, bought = s.bought or 0, spent = s.spent or 0 } end
	end
	table.sort(list, function(x, y) return ItemName(x.id) < ItemName(y.id) end)
	return list
end

-- End every session (not while a purchase is going through). Returns how many.
function QuickBuy.EndAll()
	if pending then return 0 end
	local list = QuickBuy.Sessions()
	for _, s in ipairs(list) do
		ns.SafeCall(Summary, s.id)
		EndSession(s.id)
	end
	message = nil
	ns.SafeCall(Update)
	return #list
end

-- Sessions from before Start session: still on.
ns.On("PLAYER_LOGIN", function()
	if ns.db.sessionsStarted then return end
	ns.db.sessionsStarted = true
	for _, s in pairs(ns.db.quickBuy) do
		if (s.bought or 0) > 0 then s.active = true end
	end
end)

-- Refresh the listings now (not while a purchase is going through).
function QuickBuy.Refresh()
	if not pending then Refresh() end
end

-- A purchase is going through.
function QuickBuy.Busy() return pending ~= nil end

-- The item's session is on (Start session).
function QuickBuy.Active(id)
	local s = id and ns.db.quickBuy[id]
	return s ~= nil and s.active == true
end

QuickBuy.BlizzardDialogOpen = BlizzardDialogOpen

-- The commodity on the buy page (nil elsewhere).
function QuickBuy.Item()
	return panel and panel:IsVisible() and itemID or nil
end

-- The session's purchases of it and your settings: bought, spent, want, max,
-- and the log ({ { quantity, total, time }, ... } newest first).
function QuickBuy.Session(id)
	local s = Settings(id)
	return s.bought or 0, s.spent or 0, s.want, s.max, s.log or {}
end

-- What you'd relist at: the cheapest listing left after what Quick buy would
-- buy (selling: the cheapest listing), or the usual price (and true) without
-- listings.
function QuickBuy.SellPrice(id, selling)
	local s = Settings(id)
	local sell
	if selling then sell = ListedSellPrice(id, nil, 0) else sell = ListedSellPrice(id, s.max, Remaining(id)) end
	if sell then return sell, false end
	sell = UsualPrice(id)
	if sell and sell > 0 then return sell, true end
	return nil
end

---------------------------------------------------------------------------
-- The panel
---------------------------------------------------------------------------
local function ReadInputs()
	if not itemID then return end
	local s = Settings(itemID)
	local want = tonumber(wantBox:GetText())
	want = want and want > 0 and math.floor(want) or nil
	s.want = want -- what you've bought still counts toward a new goal (End session starts over)
	local size = tonumber(checkBox:GetText())
	s.checkSize = size and size > 0 and math.floor(size) or nil
	local g = tonumber(coinBoxes[1]:GetText()) or 0
	local sv = math.min(99, tonumber(coinBoxes[2]:GetText()) or 0)
	local c = math.min(99, tonumber(coinBoxes[3]:GetText()) or 0)
	local max = math.floor(g) * 10000 + math.floor(sv) * 100 + math.floor(c)
	s.max = max > 0 and max or nil
	message = nil
	Update()
end

-- Show the saved settings for the item on screen; the first time, the most
-- to pay starts at what it's worth crafted (if one of your recipes uses it).
local function ShowItem(id)
	if pending then return end
	if id ~= itemID then staleSince, resultsAt = nil, nil end
	itemID = id
	message = nil
	if not id then return end
	local s = Settings(id)
	s.profit = nil -- from an earlier version
	if s.max == nil and ns.Crafting and ns.Crafting.CraftWorth then
		local ok, best = pcall(ns.Crafting.CraftWorth, id)
		if ok and best then s.max = best.price end
	end
	wantBox:SetText(s.want and tostring(s.want) or "")
	checkBox:SetText(s.checkSize and tostring(s.checkSize) or "")
	checkToggle:SetChecked(s.check == true)
	checkBox:SetEnabled(s.check == true)
	checkBox:SetAlpha(s.check and 1 or 0.5)
	SetCoins(s.max)
	Update()
end

local function Box(parent, width, letters)
	local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	box:SetSize(width, 20)
	box:SetAutoFocus(false)
	box:SetNumeric(true)
	box:SetMaxLetters(letters)
	box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	box:SetScript("OnTabPressed", function(self)
		if self.next then self.next:SetFocus() else self:ClearFocus() end
	end)
	box:SetScript("OnEditFocusLost", function() ns.SafeCall(ReadInputs) end)
	return box
end

local function Label(parent, text, font)
	local fs = parent:CreateFontString(nil, "ARTWORK", font or "GameFontNormal")
	fs:SetText(text)
	return fs
end

local function Coin(parent, box, icon)
	local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	fs:SetPoint("LEFT", box, "RIGHT", 2, 0)
	fs:SetText("|TInterface\\MoneyFrame\\UI-" .. icon .. "Icon:0|t")
	return fs
end

local function Create()
	local buyFrame = AuctionHouseFrame and AuctionHouseFrame.CommoditiesBuyFrame
	local display = buyFrame and buyFrame.BuyDisplay
	if not display then return end

	panel = CreateFrame("Frame", "FireAuctionQuickBuy", buyFrame)
	panel:SetPoint("BOTTOMLEFT", display, "BOTTOMLEFT", 16, 8)
	panel:SetPoint("BOTTOMRIGHT", display, "BOTTOMRIGHT", -16, 8)
	panel:SetHeight(108)

	local title = Label(panel, "Quick buy")
	title:SetPoint("TOPLEFT", 0, 0)

	-- The item's price history in the price window: FireAuction's coin, under
	-- the item's favourite star.
	local item = display.ItemDisplay or display
	local star = item.FavoriteButton
	local history = CreateFrame("Button", "FireAuctionPriceHistory", item)
	history:SetSize(18, 18)
	if star then
		history:SetPoint("TOP", star, "BOTTOM", 0, -4)
	else
		history:SetPoint("TOPRIGHT", item, "TOPRIGHT", -8, -28)
	end
	history:SetFrameLevel((item:GetFrameLevel() or 1) + 5)
	history.icon = history:CreateTexture(nil, "ARTWORK")
	history.icon:SetAllPoints()
	history.icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
	history:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	history:SetScript("OnClick", function()
		if itemID and ns.Window then ns.Window.Search(ItemName(itemID), itemID) end
	end)
	ns.ClickSound(history)
	history:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Price history", 1, 1, 1)
		GameTooltip:AddLine("Opens the price window on this item.", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	history:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- Everything but the title: shown while a session is on (Update).
	body = CreateFrame("Frame", nil, panel)
	body:SetAllPoints()

	local wantLabel = Label(body, "Want", "GameFontHighlight")
	wantLabel:SetPoint("TOPLEFT", 0, -24)
	wantBox = Box(body, 44, 5)
	wantBox:SetPoint("LEFT", wantLabel, "RIGHT", 10, 0)

	local maxLabel = Label(body, "Up to", "GameFontHighlight")
	maxLabel:SetPoint("LEFT", wantBox, "RIGHT", 14, 0)
	coinBoxes = { Box(body, 34, 4), Box(body, 22, 2), Box(body, 22, 2) }
	coinBoxes[1]:SetPoint("LEFT", maxLabel, "RIGHT", 10, 0)
	local g = Coin(body, coinBoxes[1], "Gold")
	coinBoxes[2]:SetPoint("LEFT", g, "RIGHT", 8, 0)
	local sv = Coin(body, coinBoxes[2], "Silver")
	coinBoxes[3]:SetPoint("LEFT", sv, "RIGHT", 8, 0)
	local c = Coin(body, coinBoxes[3], "Copper")
	local each = Label(body, "each", "GameFontHighlight")
	each:SetPoint("LEFT", c, "RIGHT", 4, 0)
	wantBox.next, coinBoxes[1].next, coinBoxes[2].next, coinBoxes[3].next = coinBoxes[1], coinBoxes[2], coinBoxes[3], nil

	-- "Cheapest listing only": each click buys just the lowest price within
	-- "Up to" - fewer listings to lose to someone else.
	local cheapLabel = Label(body, "Cheapest listing only", "GameFontHighlightSmall")
	cheapLabel:SetPoint("TOPRIGHT", 0, -1)
	local cheap = CreateFrame("CheckButton", nil, body, "UICheckButtonTemplate")
	cheap:SetSize(22, 22)
	cheap:SetPoint("RIGHT", cheapLabel, "LEFT", -1, 0)
	cheap:SetChecked(ns.db.quickBuyCheapest)
	cheap:SetScript("OnClick", function(self)
		ns.db.quickBuyCheapest = self:GetChecked() and true or false
		message = nil
		ns.SafeCall(Update)
	end)
	ns.ClickSound(cheap)
	cheap:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Cheapest listing only", 1, 1, 1)
		GameTooltip:AddLine("Buy only the lowest price within \"Up to\". Smaller buys are less likely to be taken by "
			.. "someone else.", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	cheap:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- "Check for [N]": with nothing within "Up to" listed, the button checks
	-- the price of N instead of refreshing (see Check). Empty: how many you
	-- BestSize (shown greyed in the box).
	checkBox = Box(body, 30, 3)
	checkBox:SetPoint("RIGHT", cheap, "LEFT", -12, 0)
	checkHint = checkBox:CreateFontString(nil, "ARTWORK", "GameFontDisable")
	checkHint:SetPoint("LEFT", 0, 0)
	checkBox:HookScript("OnEditFocusGained", function() checkHint:Hide() end)
	local checkLabel = Label(body, "Check for", "GameFontHighlightSmall")
	checkLabel:SetPoint("RIGHT", checkBox, "LEFT", -6, 0)
	checkToggle = CreateFrame("CheckButton", nil, body, "UICheckButtonTemplate")
	checkToggle:SetSize(22, 22)
	checkToggle:SetPoint("RIGHT", checkLabel, "LEFT", -1, 0)
	checkToggle:SetScript("OnClick", function(self)
		if not itemID then return end
		local on = self:GetChecked() and true or false
		Settings(itemID).check = on
		checkBox:SetEnabled(on)
		checkBox:SetAlpha(on and 1 or 0.5)
		message = nil
		ns.SafeCall(Update)
	end)
	ns.ClickSound(checkToggle)
	local function CheckTip(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Check for", 1, 1, 1)
		GameTooltip:AddLine("With nothing within \"Up to\" listed, the button checks the price of this many and buys "
			.. "them if they average within it - faster than a refresh. Off: it refreshes.", nil, nil, nil, true)
		GameTooltip:AddLine("Empty: the number that would have bought the most of your recent finds, "
			.. "at today's listings.", nil, nil, nil, true)
		GameTooltip:Show()
	end
	checkToggle:SetScript("OnEnter", CheckTip)
	checkToggle:SetScript("OnLeave", function() GameTooltip:Hide() end)
	checkBox:SetScript("OnEnter", CheckTip)
	checkBox:SetScript("OnLeave", function() GameTooltip:Hide() end)

	local tips = {
		[wantBox] = { "Want", "How many to buy in total. Leave empty for no limit." },
		[coinBoxes[1]] = { "Up to", "The most to pay per item, on average." },
	}
	tips[coinBoxes[2]], tips[coinBoxes[3]] = tips[coinBoxes[1]], tips[coinBoxes[1]]
	for box, tip in pairs(tips) do
		box:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:SetText(tip[1], 1, 1, 1)
			GameTooltip:AddLine(type(tip[2]) == "function" and tip[2]() or tip[2], nil, nil, nil, true)
			GameTooltip:Show()
		end)
		box:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end

	-- End session: a last summary, then Quick buy goes back to Start session.
	clear = CreateFrame("Button", nil, body, "UIPanelButtonTemplate")
	clear:SetSize(96, 34)
	clear:SetPoint("TOPLEFT", 0, -50)
	clear:SetText("End session")
	clear:SetMotionScriptsWhileDisabled(true)
	clear:SetScript("OnClick", function()
		if pending or not itemID then return end
		ns.SafeCall(Summary, itemID)
		EndSession(itemID)
		message = nil
		ns.SafeCall(Update)
	end)
	ns.ClickSound(clear)
	clear:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("End session", 1, 1, 1)
		GameTooltip:AddLine("Prints a summary. Your listings still up keep counting in the Profit tab.", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	clear:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- Start session: shows Quick buy, and tracks the item's buying and
	-- selling for the Profit tab.
	start = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	start:SetHeight(34)
	start:SetPoint("TOPLEFT", 0, -50)
	start:SetPoint("TOPRIGHT", 0, -50)
	start:SetText("Start session")
	start:SetScript("OnClick", function()
		if pending or not itemID then return end
		StartSession(itemID)
		message = nil
		ns.SafeCall(Update)
	end)
	ns.ClickSound(start)
	start:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Start session", 1, 1, 1)
		GameTooltip:AddLine("Shows Quick buy. What you buy and sell of this item counts in the Profit tab of the "
			.. "price window.", nil, nil, nil, true)
		GameTooltip:Show()
	end)
	start:SetScript("OnLeave", function() GameTooltip:Hide() end)
	start:Hide()

	button = CreateFrame("Button", nil, body, "UIPanelButtonTemplate")
	button:SetHeight(34)
	button:SetPoint("TOPLEFT", clear, "TOPRIGHT", 4, 0)
	button:SetPoint("TOPRIGHT", 0, -50)
	button:SetScript("OnClick", function() ns.SafeCall(Click) end)
	ns.ClickSound(button)
	button:SetMotionScriptsWhileDisabled(true)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		if mode == "refresh" then
			GameTooltip:SetText("Refresh", 1, 1, 1)
		elseif mode == "check" and checkPlan then
			GameTooltip:SetText("Check for " .. checkPlan.quantity, 1, 1, 1)
			GameTooltip:AddLine(("Buys %d if they average within \"Up to\", else refreshes."):format(checkPlan.quantity),
				nil, nil, nil, true)
		else
			GameTooltip:SetText("Quick buy", 1, 1, 1)
			GameTooltip:AddLine("Buys the cheapest first, with no confirmation. If some sell first, the rest are bought "
				.. "only if the average stays within \"Up to\".", nil, nil, nil, true)
		end
		if BlizzardDialogOpen() then GameTooltip:AddLine("Close the Buy dialog first.", 1, 0.3, 0.3, true) end
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)

	status = Label(body, "", "GameFontHighlightSmall")
	status:SetPoint("TOPLEFT", button, "BOTTOMLEFT", 0, -6)
	status:SetPoint("TOPRIGHT", button, "BOTTOMRIGHT", 0, -6)
	status:SetJustifyH("LEFT")

	-- Follow the item on screen; keep the button current as listings change.
	hooksecurefunc(buyFrame, "SetItemIDAndPrice", function(_, id) ns.SafeCall(ShowItem, id) end)
	local elapsed = 0
	panel:SetScript("OnUpdate", function(_, dt)
		elapsed = elapsed + dt
		-- A dropped confirmation, in case the game doesn't say when it's ready.
		local ready = C_AuctionHouse.IsThrottledMessageSystemReady
		if pending and pending.confirmWhenReady and (not ready or ready()) then Confirm() end
		if pending and GetTime() - pending.at > (pending.stage == "quote" and QUOTE_WAIT or QUOTE_TIMEOUT) then
			Finish("|cffff5050Not bought:|r no answer from the auction house", "no answer while " .. pending.stage)
		end
		if elapsed >= 0.25 then
			elapsed = 0
			ns.SafeCall(Update)
		end
	end)
	panel:SetScript("OnShow", function() ns.SafeCall(ShowItem, buyFrame.GetItemID and buyFrame:GetItemID()) end)
	ShowItem(buyFrame.GetItemID and buyFrame:GetItemID())
end

ns.On("AUCTION_HOUSE_SHOW", function()
	if not panel and C_AuctionHouse and C_AuctionHouse.StartCommoditiesPurchase then Create() end
end)

ns.On("AUCTION_HOUSE_CLOSED", function()
	if pending then
		pcall(C_AuctionHouse.CancelCommoditiesPurchase)
		pending = nil
	end
	-- What you bought this visit and haven't had a summary for yet.
	for id in pairs(boughtNow) do ns.SafeCall(Summary, id) end
	wipe(boughtNow)
	holdSince, consumed, staleSince, resultsAt, searchSentAt = nil, nil, nil, nil, nil
	outside, gaveUp = nil, nil
	refreshWaiting, refreshSentAt = false, nil
end)
