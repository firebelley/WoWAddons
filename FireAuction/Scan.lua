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

local function ReadOne(i, prices)
	local ok, name, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = pcall(AH.GetReplicateItemInfo, i)
	if not (ok and type(itemID) == "number" and itemID > 0) then return false end
	if buyout and buyout > 0 and count and count > 0 then -- bid-only auctions have no buyout
		local unit = buyout / count
		local p = prices[itemID]
		if not p then
			p = { low = unit, qty = 0 }
			prices[itemID] = p
		elseif unit < p.low then
			p.low = unit
		end
		p.qty = p.qty + count
		if name and name ~= "" then p.name = name end
	end
	return true
end

reader:SetScript("OnUpdate", function(self)
	local ok, err = pcall(function()
		local stop = math.min(self.index + CHUNK, self.total)
		for i = self.index, stop do
			if ReadOne(i, self.prices) then self.read = self.read + 1 end
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
		ns.Data.CommitScan(self.prices, true)
		Finish(("scanned %d auctions: prices for %d items saved."):format(self.read, items))
		if ns.Window then ns.Window.Refresh() end
	else
		UpdateBar()
	end
end)

local function StartReading()
	local total = AH.GetNumReplicateItems() or 0
	ns.Debug("reading " .. total .. " auctions")
	if total == 0 then
		Finish("the auction house sent no auctions (it may be empty, or scanned too recently - try again in a few minutes).")
		return
	end
	Scan.state = "reading"
	-- Indices start at 0; reading one past each end costs nothing and works
	-- either way.
	reader.index, reader.total, reader.read, reader.done, reader.prices = 0, total, 0, false, {}
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
			Finish("the auction house didn't answer. It allows a full scan about every 15 minutes - try again later.")
		end
	end)
end

---------------------------------------------------------------------------
-- The bar above the auction house window
---------------------------------------------------------------------------
local function CreateBar()
	local parent = AuctionHouseFrame or AuctionFrame
	if not parent then return nil end
	local f = CreateFrame("Frame", "FireAuctionBar", parent, "BackdropTemplate")
	f:SetSize(330, 28)
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

	local scan = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	scan:SetSize(60, 20)
	scan:SetPoint("RIGHT", prices, "LEFT", -4, 0)
	scan:SetText("Scan")
	scan:SetScript("OnClick", function() Scan.Start(false) end)
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
			local realm = ns.Realm()
			if realm and (realm.lastScan or 0) > 0 then
				text = "Last scan " .. ns.TimeAgo(realm.lastScan)
			else
				text = "Not scanned yet"
			end
			local left = Scan.CooldownLeft()
			if left > 0 then
				text = text .. ("  |cff999999(next in %d min)|r"):format(math.ceil(left / 60))
			end
		end
		status:SetText(text)
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

local function OnOpen()
	if ns.atAH then return end
	ns.atAH = true
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
