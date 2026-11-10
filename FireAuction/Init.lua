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
	local text = ("%+d%%"):format(math.floor(pct + (pct > 0 and 0.5 or -0.5)))
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
	ns.db = db
end)

-- Prices for the auction house you use: per realm and faction.
local realmKey
function ns.Realm()
	if not ns.db then return nil end
	if not realmKey then
		local faction = UnitFactionGroup("player")
		if not faction then return nil end -- too early
		realmKey = (GetRealmName() or "?") .. " - " .. faction
	end
	local realms = ns.db.realms
	if not realms[realmKey] then realms[realmKey] = { items = {}, lastScan = 0, lastRequest = 0 } end
	return realms[realmKey]
end
