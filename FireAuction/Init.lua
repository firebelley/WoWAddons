-- Shared setup: saved settings, printing, money/time formatting and a tiny
-- event bus every file uses.
local ADDON, ns = ...
ns.ADDON = ADDON

local DEFAULTS = {
	autoScan = true,  -- scan by itself when you open the auction house (if the game allows one)
	tooltip = true,   -- auction price + trend in item tooltips
	minimapButton = true, -- the coin on the minimap (MinimapButton.lua)
	markValuable = true,  -- gold coin on bag items worth at least markPrice (BagIcons.lua)
	markPrice = 5000,     -- copper per item (50 silver)
	craftProfit = true,   -- profit line in profession windows (Crafting.lua)
	craftWorth = true,    -- "Worth as <crafted item>" on reagent tooltips, from your saved recipes (Crafting.lua)
	announceSales = true, -- big announcement when one of your auctions sells (Sales.lua)
	buyInfo = false,      -- the tracker beside the auction house's buy page, opened by its side tab (BuyInfo.lua)
	seedWindow = false,   -- the seed listing window, opened by the second side tab (Seed.lua)
	quickBuyCheapest = false, -- Quick buy takes only the lowest price within "Up to" per click (QuickBuy.lua)
	historyDays = 30, -- how many days of prices to keep
	trendDays = 7,    -- how far back the trend looks (and how far ahead it projects)
}
ns.DEFAULTS = DEFAULTS

-- The game allows a full auction house scan about this often.
ns.SCAN_COOLDOWN = 15 * 60

function ns.Print(msg)
	print("|cffff8030FireAuction|r: " .. msg)
end

ns.debug = false
function ns.Debug(msg)
	if ns.debug then print("|cff80a0ffFireAuction debug|r: " .. msg) end
end

---------------------------------------------------------------------------
-- Errors: WoW hides Lua errors unless scriptErrors is on, so FireAuction
-- prints its own (each distinct message once per session).
---------------------------------------------------------------------------
local reported = {}
function ns.ReportError(err)
	local msg = tostring(err)
	if reported[msg] then return end
	reported[msg] = true
	ns.Print("|cffff4040error:|r " .. msg)
end

function ns.SafeCall(fn, ...)
	local n, args = select("#", ...), { ... }
	return xpcall(function() return fn(unpack(args, 1, n)) end, ns.ReportError)
end

-- The standard click sound for our own buttons (Blizzard's play it in their
-- own click handlers); checkboxes get the on / off ones. sound: a SOUNDKIT
-- name to play instead.
function ns.ClickSound(widget, sound)
	widget:HookScript("OnClick", function(self)
		if not (PlaySound and SOUNDKIT) then return end
		local kit = SOUNDKIT[sound or "IG_MAINMENU_OPTION"]
		if not sound and self.GetChecked and self:GetObjectType() == "CheckButton" then
			kit = self:GetChecked() and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF
		end
		if kit then PlaySound(kit) end
	end)
end

---------------------------------------------------------------------------
-- Events: ns.On(event, fn). Events this client doesn't have are ignored.
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local handlers = {}

function ns.On(event, fn)
	if not handlers[event] then
		handlers[event] = {}
		pcall(eventFrame.RegisterEvent, eventFrame, event)
	end
	table.insert(handlers[event], fn)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
	for _, fn in ipairs(handlers[event]) do
		ns.SafeCall(fn, ...)
	end
end)

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------
local GOLD = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
local SILVER = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
local COPPER = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"

-- "12g 34s 56c" with coin icons; small coins are left off big amounts.
-- How long an auction lasts, in seconds, by the duration's place in the Sell
-- page's list (1 = the shortest). Read from the game's own labels ("2 Hours"),
-- as the lengths differ between clients; 2, 8 and 24 hours if they can't be read.
function ns.DurationSeconds(index)
	local text = ({ AUCTION_DURATION_ONE, AUCTION_DURATION_TWO, AUCTION_DURATION_THREE })[index]
	local hours = type(text) == "string" and tonumber(text:match("(%d+)"))
	return (hours or ({ 2, 8, 24 })[index] or 24) * 3600
end

function ns.Money(copper)
	copper = math.floor((copper or 0) + 0.5)
	local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
	local parts = {}
	if g > 0 then parts[#parts + 1] = (BreakUpLargeNumbers and BreakUpLargeNumbers(g) or g) .. GOLD end
	if s > 0 and g < 100 then parts[#parts + 1] = s .. SILVER end
	if (c > 0 and g == 0) or #parts == 0 then parts[#parts + 1] = c .. COPPER end
	return table.concat(parts, " ")
end

-- "+12%" in green, "-8%" in red, "0%" in grey.
function ns.Percent(pct)
	if math.abs(pct) < 0.5 then return "|cff9999990%|r" end
	local rounded = pct > 0 and math.floor(pct + 0.5) or math.ceil(pct - 0.5)
	local text = ("%+d%%"):format(rounded)
	return (pct > 0 and "|cff40ff40" or "|cffff5050") .. text .. "|r"
end

function ns.TimeAgo(t)
	local s = math.max(0, time() - (t or 0))
	if s < 60 then return "just now" end
	if s < 3600 then
		local m = math.floor(s / 60)
		return m .. (m == 1 and " minute ago" or " minutes ago")
	end
	if s < 86400 then
		local h = math.floor(s / 3600)
		return h .. (h == 1 and " hour ago" or " hours ago")
	end
	local d = math.floor(s / 86400)
	return d .. (d == 1 and " day ago" or " days ago")
end

-- The newest full scan we have: our own, or one a guild member synced.
-- Returns its time (0 = none) and whether it came from a sync.
function ns.LastScan(realm)
	if not realm then return 0, false end
	local own, synced = realm.lastScan or 0, realm.syncedFull or 0
	return math.max(own, synced), synced > own
end

-- "Last scan 5 minutes ago (synced)", or nil if there's none.
function ns.LastScanText(realm)
	local t, synced = ns.LastScan(realm)
	if t <= 0 then return nil end
	return "Last scan " .. ns.TimeAgo(t) .. (synced and " (synced)" or "")
end

---------------------------------------------------------------------------
-- Saved settings
---------------------------------------------------------------------------
ns.On("ADDON_LOADED", function(name)
	if name ~= ADDON then return end
	FireAuctionDB = FireAuctionDB or {}
	local db = FireAuctionDB
	for k, v in pairs(DEFAULTS) do
		if db[k] == nil then db[k] = v end
	end
	db.realms = db.realms or {} -- ["Realm - Faction"] = { items = {...}, lastScan, lastRequest }
	db.vendorPrices = db.vendorPrices or {} -- [itemID] = copper per item, learned at merchants
	db.favorites = db.favorites or {} -- [itemID] = true: pinned to the top of the price window
	db.recipes = db.recipes or {} -- [recipeID] = { o = output itemID, m = made per craft, r = { { qty, itemID, ... }, ... } }
	db.craftMaxPrice, db.targetProfit = nil, nil -- replaced by craftWorth
	db.quickBuy = db.quickBuy or {} -- [itemID] = { want = how many, max = copper each } (QuickBuy.lua)
	ns.db = db
end)

-- Prices per auction house: your faction's ("Realm - Horde") and the neutral
-- one in Booty Bay, Gadgetzan and Everlook ("Realm - Neutral").
--   house: "faction" or "neutral"; nil means the one you're using - the
--   neutral house while you're at it (ns.house, set by Scan.lua), otherwise
--   your faction's.
ns.house = nil

function ns.HouseName(house)
	house = house or ns.house or "faction"
	if house == "neutral" then return "Neutral" end
	return UnitFactionGroup("player") or "Faction"
end

function ns.Realm(house)
	if not ns.db then return nil end
	local faction = UnitFactionGroup("player")
	if not faction then return nil end -- too early
	house = house or ns.house or "faction"
	local key = (GetRealmName() or "?") .. " - " .. (house == "neutral" and "Neutral" or faction)
	local realms = ns.db.realms
	if not realms[key] then realms[key] = { items = {}, lastScan = 0, lastRequest = 0 } end
	return realms[key]
end
