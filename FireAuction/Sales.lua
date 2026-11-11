-- Your auction sales: a big announcement when one sells (wherever you are),
-- and what's owed to you until you take the money from the mailbox.
--
--   Your listings: remembered whenever the auction house lists them for you
--   (FireAuction asks when you open it and after you post), so a sale can be
--   matched to its price.
--   A sale: the game's "auction sold" notice (with the auction's ID), or its
--   "A buyer has been found for your auction of ..." chat message.
--   The mailbox: each sale's mail says exactly what it pays out (price, minus
--   the auction house's cut, plus your deposit back). A sale whose mail was in
--   the mailbox and no longer is has been claimed, and is dropped.
--
-- Kept per character (FireAuctionDB.chars["Name - Realm"]): { owned, sales }.
local _, ns = ...
local AH = C_AuctionHouse

local Sales = {}
ns.Sales = Sales

local AH_CUT = 0.05
local DELIVERY_GRACE = 2 * 3600 -- a sale with no mail (or "sale pending" notice) this long is dropped
local SOLD = Enum and Enum.AuctionHouseNotification and Enum.AuctionHouseNotification.AuctionSold or 4
local EXPIRED = Enum and Enum.AuctionHouseNotification and Enum.AuctionHouseNotification.AuctionExpired or 5
local AUCTIONEER = Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.Auctioneer

local function Char()
	if not ns.db then return nil end
	local name = UnitName("player")
	if not name then return nil end
	local key = name .. " - " .. (GetRealmName() or "?")
	ns.db.chars = ns.db.chars or {}
	local c = ns.db.chars[key]
	if not c then
		c = { owned = {}, sales = {} }
		ns.db.chars[key] = c
	end
	return c
end

local function ItemName(id)
	return id and C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id) or nil
end

---------------------------------------------------------------------------
-- Your listings
---------------------------------------------------------------------------
local function ReadOwned()
	local c = Char()
	if not (c and AH and AH.GetNumOwnedAuctions and AH.GetOwnedAuctionInfo) then return end
	local fresh = {}
	for i = 1, AH.GetNumOwnedAuctions() or 0 do
		local ok, a = pcall(AH.GetOwnedAuctionInfo, i)
		if ok and a and a.auctionID then
			local id = a.itemKey and a.itemKey.itemID
			local link = a.itemLink
			fresh[a.auctionID] = {
				name = (link and link:match("%[(.-)%]")) or ItemName(id),
				link = link, id = id, qty = a.quantity or 1,
				buyout = a.buyoutAmount, bid = a.bidAmount,
			}
		end
	end
	-- A partial list only adds; a full one replaces (cancelled ones go).
	local full = not AH.HasFullOwnedAuctionResults or AH.HasFullOwnedAuctionResults()
	if full then
		c.owned = fresh
	else
		for k, v in pairs(fresh) do c.owned[k] = v end
	end
	local n = 0
	for _ in pairs(c.owned) do n = n + 1 end
	ns.Debug(("your auctions: %d listed"):format(n))
end
ns.On("OWNED_AUCTIONS_UPDATED", ReadOwned)

local queryPending = false
local function QueryOwned(delay)
	if queryPending or not (AH and AH.QueryOwnedAuctions) then return end
	queryPending = true
	C_Timer.After(delay, function()
		queryPending = false
		if ns.atAH then pcall(AH.QueryOwnedAuctions, {}) end
	end)
end
ns.On("AUCTION_HOUSE_SHOW", function() QueryOwned(2) end)
ns.On("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(kind)
	if AUCTIONEER and kind == AUCTIONEER then QueryOwned(2) end
end)
ns.On("AUCTION_HOUSE_AUCTION_CREATED", function() QueryOwned(1) end)

-- One of your listings by item name (for the chat message, which has no ID).
local function OwnedByName(c, name)
	local bestID, best
	for auctionID, a in pairs(c.owned) do
		if a.name == name then
			-- Buyers usually take the cheapest first.
			local price = (a.buyout and a.buyout > 0 and a.buyout / a.qty) or math.huge
			local bestPrice = best and ((best.buyout and best.buyout > 0 and best.buyout / best.qty) or math.huge)
			if not best or price < bestPrice then bestID, best = auctionID, a end
		end
	end
	return bestID, best
end

---------------------------------------------------------------------------
-- What's owed
---------------------------------------------------------------------------
-- Returns the total copper owed (counting estimates), how many sales, whether
-- any price is unknown, and the sales (newest first).
function Sales.Owed()
	local c = Char()
	local list, total, unknown = {}, 0, false
	if not c then return 0, 0, false, list end
	for _, s in ipairs(c.sales) do
		list[#list + 1] = s
		if s.net then total = total + s.net else unknown = true end
	end
	table.sort(list, function(a, b) return (a.t or 0) > (b.t or 0) end)
	return total, #list, unknown, list
end

local function SaleText(s)
	local text = s.link or s.name or "?"
	if (s.qty or 1) > 1 then text = text .. " x" .. s.qty end
	return text
end

-- Lines for a tooltip (or chat): each sale, then the total.
function Sales.AddLines(tooltip, max)
	local total, n, unknown, list = Sales.Owed()
	if n == 0 then return false end
	tooltip:AddLine(" ")
	tooltip:AddLine("Sold - money owed to you:", 1, 0.82, 0)
	for i = 1, math.min(n, max or 10) do
		local s = list[i]
		local right = s.net and ((s.exact and "" or "~") .. ns.Money(s.net)) or "?"
		if not s.inMail then right = "|cff999999(on its way)|r " .. right end
		tooltip:AddDoubleLine("  " .. SaleText(s), right, 1, 1, 1, 1, 1, 1)
	end
	if n > (max or 10) then tooltip:AddLine(("  ...and %d more"):format(n - (max or 10)), 0.7, 0.7, 0.7) end
	tooltip:AddDoubleLine("Total", (unknown and "at least " or "") .. ns.Money(total), 1, 0.82, 0, 1, 1, 1)
	return true
end

---------------------------------------------------------------------------
-- A sale
---------------------------------------------------------------------------
local function PlayCoin()
	pcall(PlaySound, SOUNDKIT and SOUNDKIT.LOOT_WINDOW_COIN_SOUND or 120, "Master")
end

local function Announce(s, test)
	if not (ns.db.announceSales or test) then return end
	local price = s.gross and ns.Money(s.gross) or "an unknown price"
	local name = s.name or "?"
	local q = s.id and C_Item and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(s.id)
	local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
	if c and c.hex then name = c.hex .. name .. "|r" end
	if (s.qty or 1) > 1 then name = name .. " x" .. s.qty end
	local big = ("Sold: %s for %s"):format(name, price)
	if RaidNotice_AddMessage and RaidWarningFrame then
		RaidNotice_AddMessage(RaidWarningFrame, big, { r = 1, g = 0.82, b = 0 })
	elseif UIErrorsFrame then
		UIErrorsFrame:AddMessage(big, 1, 0.82, 0)
	end
	PlayCoin()
	if test then
		ns.Print(("|cff40ff40Sold|r %s for %s. |cff999999(a test - nothing was recorded)|r"):format(SaleText(s), price))
		return
	end
	local total, _, unknown = Sales.Owed()
	ns.Print(("|cff40ff40Sold|r %s for %s. Owed to you in all: %s%s"):format(SaleText(s), price,
		unknown and "at least " or "", ns.Money(total)))
end

local function Sold(name, auction)
	local c = Char()
	if not c then return end
	local s = { name = name, t = time() }
	if auction then
		s.name, s.link, s.id, s.qty = auction.name or name, auction.link, auction.id, auction.qty
		local gross = (auction.buyout and auction.buyout > 0 and auction.buyout) or auction.bid
		if gross and gross > 0 then
			s.gross = gross
			s.net = math.floor(gross * (1 - AH_CUT))
		end
	end
	c.sales[#c.sales + 1] = s
	Announce(s)
end

-- The notice with the auction's ID; the chat message waits a moment to see
-- whether one came (both arrive for the same sale).
local noticed = {} -- [name] = notices not yet paired with a chat message

ns.On("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", function(kind, text, auctionID)
	local c = Char()
	if not c then return end
	if kind == EXPIRED then
		if auctionID then c.owned[auctionID] = nil end
		return
	end
	if kind ~= SOLD then return end
	local a = auctionID and c.owned[auctionID]
	if auctionID then c.owned[auctionID] = nil end
	local name = (a and a.name) or text
	noticed[name] = (noticed[name] or 0) + 1
	if text and text ~= name then noticed[text] = (noticed[text] or 0) + 1 end
	ns.Debug(("sold notice: %s (auction %s, %s)"):format(tostring(text), tostring(auctionID), a and "price known" or "price unknown"))
	Sold(name, a)
end)

local soldPattern
if ERR_AUCTION_SOLD_S then
	soldPattern = "^" .. ERR_AUCTION_SOLD_S:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%%%s", "(.+)") .. "$"
end

ns.On("CHAT_MSG_SYSTEM", function(msg)
	if not (soldPattern and type(msg) == "string") then return end
	local name = msg:match(soldPattern)
	if not name then return end
	C_Timer.After(1, function()
		if (noticed[name] or 0) > 0 then
			noticed[name] = noticed[name] - 1
			return
		end
		local c = Char()
		if not c then return end
		local auctionID, a = OwnedByName(c, name)
		if auctionID then c.owned[auctionID] = nil end
		ns.Debug("sold message: " .. name .. (a and " (price known)" or " (price unknown)"))
		ns.SafeCall(Sold, name, a)
	end)
end)

---------------------------------------------------------------------------
-- The mailbox
---------------------------------------------------------------------------
local atMailbox = false

-- The first unused entry for this sale: same item, same amount if known.
local function Take(list, s)
	local fallback
	for _, m in ipairs(list) do
		if not m.used and m.name == s.name then
			if not (m.qty and s.qty) or m.qty == s.qty then
				m.used = true
				return m
			end
			fallback = fallback or m
		end
	end
	if fallback then fallback.used = true end
	return fallback
end

local function ReadInbox()
	local c = Char()
	if not (c and GetInboxNumItems and GetInboxInvoiceInfo) then return end
	local shown, total = GetInboxNumItems()
	shown = shown or 0
	local complete = (total or shown) <= shown -- every mail is shown (no more than 50)
	local mails, pending = {}, {}
	for i = 1, shown do
		local kind, itemName, _, bid, _, _, _, _, _, _, count = GetInboxInvoiceInfo(i)
		if kind == "seller" and itemName then
			local money = select(5, GetInboxHeaderInfo(i))
			if money and money > 0 then
				mails[#mails + 1] = { name = itemName, money = money, gross = bid, qty = count }
			end
		elseif kind == "seller_temp_invoice" and itemName then
			pending[#pending + 1] = { name = itemName, qty = count }
		end
	end

	local keep, now = {}, time()
	for _, s in ipairs(c.sales) do
		local m = Take(mails, s)
		if m then
			s.net, s.exact, s.inMail = m.money, true, true
			if m.gross and m.gross > 0 then s.gross = m.gross end
			keep[#keep + 1] = s
		elseif s.inMail then
			-- It was here, and now it's gone: you took the money.
			if not complete then keep[#keep + 1] = s end
		elseif Take(pending, s) or now - (s.t or 0) < DELIVERY_GRACE or not complete then
			keep[#keep + 1] = s -- not delivered yet
		end
	end
	-- Sales FireAuction didn't see (sold while you were offline).
	for _, m in ipairs(mails) do
		if not m.used then
			keep[#keep + 1] = { name = m.name, qty = m.qty, gross = m.gross, net = m.money,
				exact = true, inMail = true, t = now }
		end
	end
	c.sales = keep
end

local inboxPending = false
ns.On("MAIL_INBOX_UPDATE", function()
	if not atMailbox or inboxPending then return end
	inboxPending = true
	C_Timer.After(0.2, function()
		inboxPending = false
		if atMailbox then ns.SafeCall(ReadInbox) end
	end)
end)
ns.On("MAIL_SHOW", function() atMailbox = true end)
ns.On("MAIL_CLOSED", function()
	if atMailbox then ns.SafeCall(ReadInbox) end
	atMailbox = false
end)

---------------------------------------------------------------------------
-- /fah testsale: what the announcement looks like (nothing is recorded)
---------------------------------------------------------------------------
function Sales.Test()
	local id = 4306 -- Silk Cloth
	local name = ItemName(id) or "Silk Cloth"
	local GetInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
	local link = GetInfo and select(2, GetInfo(id))
	Announce({ name = name, link = link, id = id, qty = 20, gross = 40000 }, true)
end

---------------------------------------------------------------------------
-- /fah sales
---------------------------------------------------------------------------
function Sales.Print()
	local total, n, unknown, list = Sales.Owed()
	if n == 0 then
		ns.Print("no money owed to you from sales.")
		return
	end
	ns.Print(("%d sale%s to collect from the mailbox, %s%s:"):format(n, n == 1 and "" or "s",
		unknown and "at least " or "", ns.Money(total)))
	for _, s in ipairs(list) do
		print(("  %s - %s%s%s"):format(SaleText(s), s.net and ((s.exact and "" or "~") .. ns.Money(s.net)) or "?",
			s.inMail and "" or " (on its way)", " |cff999999" .. ns.TimeAgo(s.t) .. "|r"))
	end
end
