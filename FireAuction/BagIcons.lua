-- A gold coin on items in your bags whose auction price (lowest buyout per
-- item, latest scan) is at least the amount set in the options.
--
-- Works with FireBags (through its button hook) or Blizzard's bags.
local _, ns = ...

local BagIcons = {}
ns.BagIcons = BagIcons

local COIN = "Interface\\MoneyFrame\\UI-GoldIcon"

local function IsValuable(link, isBound)
	local db = ns.db
	if not (db and db.markValuable and link) or isBound then return false end
	local id = tonumber(link:match("item:(%d+)"))
	local rec = id and ns.Data.Get(id)
	return rec and rec.p and rec.p >= (db.markPrice or 0) or false
end

local function Decorate(button, link, isBound)
	local valuable = IsValuable(link, isBound)
	local icon = button.faValuable
	if not icon then
		if not valuable then return end
		icon = button:CreateTexture(nil, "OVERLAY", nil, 7)
		icon:SetTexture(COIN)
		icon:SetSize(13, 13)
		icon:SetPoint("TOPRIGHT", -2, -2)
		button.faValuable = icon
	end
	icon:SetShown(valuable)
end

---------------------------------------------------------------------------
-- Blizzard's bags (when FireBags isn't running). Only our own texture is
-- touched; Blizzard's frames are never called, so nothing gets tainted.
---------------------------------------------------------------------------
local seen = {} -- [button] = true for every Blizzard bag button decorated

local function DecorateBlizzardButton(b)
	local bag = b.GetBagID and b:GetBagID()
	local slot = b:GetID()
	if not (bag and slot) then return end
	local info = C_Container.GetContainerItemInfo(bag, slot)
	seen[b] = true
	Decorate(b, info and info.hyperlink, info and info.isBound)
end

local function HookBlizzardBags()
	local frames = {}
	for i = 1, NUM_CONTAINER_FRAMES or 13 do
		local f = _G["ContainerFrame" .. i]
		if f then frames[#frames + 1] = f end
	end
	if ContainerFrameCombinedBags then frames[#frames + 1] = ContainerFrameCombinedBags end
	for _, f in ipairs(frames) do
		if f.UpdateItems and f.EnumerateValidItems then
			hooksecurefunc(f, "UpdateItems", function(self)
				for _, b in self:EnumerateValidItems() do ns.SafeCall(DecorateBlizzardButton, b) end
			end)
		end
	end
end

---------------------------------------------------------------------------
-- Redraw after a scan or a settings change.
---------------------------------------------------------------------------
function BagIcons.Refresh()
	if FireBags and FireBags.UpdateButtons then FireBags.UpdateButtons() end
	for b in pairs(seen) do
		if b:IsVisible() then ns.SafeCall(DecorateBlizzardButton, b) end
	end
end

ns.On("PLAYER_LOGIN", function()
	if FireBags and FireBags.AddButtonHook then
		FireBags.AddButtonHook(Decorate)
	else
		HookBlizzardBags()
	end
end)
