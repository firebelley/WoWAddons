-- Scanning: a full copy of the auction house (C_AuctionHouse.ReplicateItems),
-- read a chunk per frame so the game doesn't freeze, then saved as prices.
--
-- The game only answers a full scan every ~15 minutes; asking sooner gets no
-- answer, which is reported after a while.
--
-- Also the small bar above the auction house window: status, Scan, Prices.
local _, ns = ...
local AH = C_AuctionHouse

local Scan = { state = "idle" } -- idle, waiting (asked), settling (data arriving), reading
ns.Scan = Scan

local CHUNK = 2000   -- auctions read per frame
local SETTLE = 1     -- seconds to wait after the last "data arrived" before reading
local TIMEOUT = 30   -- seconds without an answer before giving up

ns.atAH = false
local token = 0      -- invalidates timers from an older scan
local bar
local SetHouse, DetectHouse -- which auction house you're at (further down)

local function UpdateBar()
	if bar and bar:IsShown() then ns.SafeCall(bar.Update, bar) end
end

function Scan.CooldownLeft()
	local realm = ns.Realm()
	if not realm then return 0 end
	return math.max(0, (realm.lastRequest or 0) + ns.SCAN_COOLDOWN - time())
end

function Scan.Busy()
	return Scan.state ~= "idle"
end

local function Finish(msg)
	Scan.state = "idle"
	Scan.reader:Hide()
	token = token + 1
	if msg then ns.Print(msg) end
	UpdateBar()
end

---------------------------------------------------------------------------
-- Reading the results
---------------------------------------------------------------------------
local reader = CreateFrame("Frame")
reader:Hide()
Scan.reader = reader

-- One listing: "buyout,stack,bid" (bid only for bid-only auctions). Identical
-- auctions share a key and are counted together.
local function ListingKey(buyout, count, bid)
	return ("%.0f,%d,%.0f"):format(buyout, count, bid)
end

local function ReadOne(i, prices, bidOnly)
	local ok, name, _, count, _, _, _, _, minBid, _, buyout, bidAmount, _, _, _, _, _, itemID =
		pcall(AH.GetReplicateItemInfo, i)
	if not (ok and type(itemID) == "number" and itemID > 0) then return false end
	if not (count and count > 0) then return true end
	if buyout and buyout > 0 then
		local unit = buyout / count
		local p = prices[itemID]
		if not p then
			p = { low = unit, qty = 0, list = {} }
			prices[itemID] = p
		elseif unit < p.low then
			p.low = unit
		end
		p.qty = p.qty + count
		if name and name ~= "" then p.name = name end
		local key = ListingKey(buyout, count, 0)
		p.list[key] = (p.list[key] or 0) + 1
	else
		-- Bid-only: no buyout, so not part of the price, but still a listing.
		local bid = (bidAmount and bidAmount > 0) and bidAmount or minBid or 0
		local list = bidOnly[itemID]
		if not list then
			list = {}
			bidOnly[itemID] = list
		end
		local key = ListingKey(0, count, bid)
		list[key] = (list[key] or 0) + 1
	end
	return true
end

reader:SetScript("OnUpdate", function(self)
	local ok, err = pcall(function()
		local stop = math.min(self.index + CHUNK, self.total)
		for i = self.index, stop do
			if ReadOne(i, self.prices, self.bidOnly) then self.read = self.read + 1 end
		end
		self.index = stop + 1
		if self.index > self.total then
			-- More may have arrived while reading.
			local total = AH.GetNumReplicateItems() or 0
			if total > self.total then
				self.total = total
				return
			end
			self.done = true
		end
	end)
	if not ok then
		ns.ReportError(err)
		Finish("scan failed.")
		return
	end
	if self.done then
		local items = 0
		for _ in pairs(self.prices) do items = items + 1 end
		-- Bid-only listings go with items that have a price.
		for id, list in pairs(self.bidOnly) do
			local p = self.prices[id]
			if p then
				for key, n in pairs(list) do p.list[key] = (p.list[key] or 0) + n end
			end
		end
		ns.Data.CommitScan(self.prices, true, self.house)
		Finish(("scanned %d auctions: prices for %d items saved."):format(self.read, items))
		if ns.Sync then ns.Sync.ScanDone(self.house) end
		if ns.Window then ns.Window.Refresh() end
		if ns.BagIcons then ns.BagIcons.Refresh() end
		if ns.Crafting then ns.Crafting.Refresh() end
	else
		UpdateBar()
	end
end)

local function StartReading()
	local total = AH.GetNumReplicateItems() or 0
	ns.Debug("reading " .. total .. " auctions")
	if total == 0 then
		Finish("no auctions received - try again in a few minutes.")
		return
	end
	Scan.state = "reading"
	-- Indices start at 0; reading one past each end costs nothing and works
	-- either way.
	reader.index, reader.total, reader.read, reader.done = 0, total, 0, false
	reader.prices, reader.bidOnly = {}, {}
	reader.house = ns.house or "faction"
	reader:Show()
	UpdateBar()
end

ns.On("REPLICATE_ITEM_LIST_UPDATE", function()
	if Scan.state ~= "waiting" and Scan.state ~= "settling" then return end
	Scan.state = "settling"
	token = token + 1
	local mine = token
	C_Timer.After(SETTLE, function()
		if token == mine and Scan.state == "settling" then ns.SafeCall(StartReading) end
	end)
	UpdateBar()
end)

---------------------------------------------------------------------------
-- Asking
---------------------------------------------------------------------------
function Scan.Start(auto)
	if Scan.Busy() then return end
	if not (AH and AH.ReplicateItems) then
		ns.Print("this client can't scan the whole auction house.")
		return
	end
	if not ns.atAH then
		ns.Print("open the auction house to scan.")
		return
	end
	-- Check again: the auctioneer may not have been known yet when the window opened.
	SetHouse(DetectHouse())
	local realm = ns.Realm()
	if not realm then return end

	Scan.state = "waiting"
	realm.lastRequest = time()
	token = token + 1
	local mine = token
	AH.ReplicateItems()
	ns.Debug("asked for a full scan" .. (auto and " (auto)" or ""))
	UpdateBar()

	C_Timer.After(TIMEOUT, function()
		if token == mine and Scan.state == "waiting" then
			Finish("no answer from the auction house - try again later.")
		end
	end)
end

---------------------------------------------------------------------------
-- The bar above the auction house window
---------------------------------------------------------------------------
local MIN_BAR_WIDTH = 330

local function CreateBar()
	local parent = AuctionHouseFrame or AuctionFrame
	if not parent then return nil end
	local f = CreateFrame("Frame", "FireAuctionBar", parent, "BackdropTemplate")
	f:SetSize(MIN_BAR_WIDTH, 28)
	f:SetPoint("BOTTOMRIGHT", parent, "TOPRIGHT", 0, 2)
	if f.SetBackdrop then
		f:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		f:SetBackdropColor(0, 0, 0, 0.8)
	end

	local prices = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	prices:SetSize(60, 20)
	prices:SetPoint("RIGHT", -5, 0)
	prices:SetText("Prices")
	prices:SetScript("OnClick", function() ns.Window.Toggle() end)
	ns.ClickSound(prices)

	local scan = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	scan:SetSize(60, 20)
	scan:SetPoint("RIGHT", prices, "LEFT", -4, 0)
	scan:SetText("Scan")
	scan:SetScript("OnClick", function() Scan.Start(false) end)
	ns.ClickSound(scan)
	scan:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Scan the auction house", 1, 1, 1)
		GameTooltip:AddLine("Saves today's price of everything listed. The game allows this about every 15 minutes.",
			nil, nil, nil, true)
		GameTooltip:Show()
	end)
	scan:SetScript("OnLeave", function() GameTooltip:Hide() end)

	local status = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	status:SetPoint("LEFT", 10, 0)
	status:SetPoint("RIGHT", scan, "LEFT", -6, 0)
	status:SetJustifyH("LEFT")
	status:SetWordWrap(false)

	function f:Update()
		local text
		if Scan.state == "waiting" then
			text = "Asking the auction house..."
		elseif Scan.state == "settling" then
			text = "Receiving auctions..."
		elseif Scan.state == "reading" then
			text = ("Reading auctions... %d%%"):format(math.floor(reader.index / math.max(1, reader.total) * 100))
		else
			text = ns.LastScanText(ns.Realm()) or "Not scanned yet"
			if ns.house == "neutral" then text = "|cffffd100Neutral:|r " .. text end
			local left = Scan.CooldownLeft()
			if left > 0 then
				text = text .. ("  |cff999999(next in %d min)|r"):format(math.ceil(left / 60))
			end
		end
		status:SetText(text)
		-- Grow (leftwards) to fit the text: its margins plus the two buttons.
		-- In steps of 20 so it doesn't twitch as the text changes.
		local textWidth = status.GetUnboundedStringWidth and status:GetUnboundedStringWidth() or status:GetStringWidth()
		local width = math.max(MIN_BAR_WIDTH, math.ceil((textWidth + 16 + 129) / 20) * 20)
		if math.abs(self:GetWidth() - width) > 1 then self:SetWidth(width) end
		scan:SetEnabled(not Scan.Busy())
	end

	local elapsed = 0
	f:SetScript("OnUpdate", function(self, dt)
		elapsed = elapsed + dt
		if elapsed >= 1 then
			elapsed = 0
			self:Update()
		end
	end)
	f:SetScript("OnShow", f.Update)
	return f
end

---------------------------------------------------------------------------
-- Which auction house, in order of trust:
--   1. the town: Booty Bay, Gadgetzan and Everlook have the neutral ones
--   2. the auctioneer: the goblin ones belong to neither faction
--   3. the zone (Stranglethorn, Tanaris, Winterspring): no faction auction
--      houses there
---------------------------------------------------------------------------
local NEUTRAL_TOWNS = { ["Booty Bay"] = true, ["Gadgetzan"] = true, ["Everlook"] = true }
local NEUTRAL_MAPS = {
	[1434] = true, [1446] = true, [1452] = true, -- classic map IDs
	[224] = true, [210] = true, [71] = true, [83] = true, -- modern map IDs
}

-- The player's map and the maps it sits in.
local function MapChain()
	local chain = {}
	local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
	while map and #chain < 6 do
		chain[#chain + 1] = map
		local info = C_Map.GetMapInfo and C_Map.GetMapInfo(map)
		map = info and info.parentMapID
		if map == 0 then map = nil end
	end
	return chain
end

local function InNeutralTown()
	local sub = GetSubZoneText and GetSubZoneText() or ""
	local mini = GetMinimapZoneText and GetMinimapZoneText() or ""
	return NEUTRAL_TOWNS[sub] or NEUTRAL_TOWNS[mini] or false
end

function DetectHouse() -- (declared at the top)
	if InNeutralTown() then return "neutral" end
	if UnitExists("npc") then
		local faction = UnitFactionGroup("npc")
		if faction == "Alliance" or faction == "Horde" then return nil end
		return "neutral"
	end
	for _, map in ipairs(MapChain()) do
		if NEUTRAL_MAPS[map] then return "neutral" end
	end
	return nil
end

-- For /fah debug: what the detection sees.
function Scan.HouseDebug()
	local npc = UnitExists("npc") and ((UnitName("npc") or "?") .. " (" .. tostring(UnitFactionGroup("npc")) .. ")") or "none"
	return ("auction house %s; town %q / %q; auctioneer %s; maps %s; detected %s"):format(
		ns.atAH and "open" or "closed", GetSubZoneText and GetSubZoneText() or "", GetMinimapZoneText and GetMinimapZoneText() or "",
		npc, table.concat(MapChain(), " > "), ns.atAH and ns.HouseName(DetectHouse() or "faction") or "-")
end

-- Tooltips, bag coins and crafting profit follow the auction house you're at.
function SetHouse(house) -- (declared at the top)
	if ns.house == house then return end
	ns.house = house
	ns.Debug("auction house: " .. ns.HouseName())
	if ns.Window then ns.Window.HouseChanged() end
	if ns.BagIcons then ns.BagIcons.Refresh() end
	if ns.Crafting then ns.Crafting.Refresh() end
end

local function OnOpen()
	if ns.atAH then return end
	ns.atAH = true
	SetHouse(DetectHouse())
	C_Timer.After(0, function()
		bar = bar or CreateBar()
		UpdateBar()
	end)
	if ns.db.autoScan and Scan.CooldownLeft() == 0 then
		C_Timer.After(1, function()
			if ns.atAH and not Scan.Busy() then Scan.Start(true) end
		end)
	end
end

local function OnClose()
	if not ns.atAH then return end
	ns.atAH = false
	if Scan.Busy() then
		-- The copy of the auction house goes away with the window.
		local wasReading = Scan.state == "reading"
		Finish(wasReading and "scan stopped: the auction house was closed before it was read." or nil)
	end
	SetHouse(nil)
end

local AUCTIONEER = Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.Auctioneer
ns.On("AUCTION_HOUSE_SHOW", OnOpen)
ns.On("AUCTION_HOUSE_CLOSED", OnClose)
ns.On("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(kind)
	if AUCTIONEER and kind == AUCTIONEER then OnOpen() end
end)
ns.On("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(kind)
	if AUCTIONEER and kind == AUCTIONEER then OnClose() end
end)
