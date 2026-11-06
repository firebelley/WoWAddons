-- Works out which bags exist and groups them into sections:
-- one main section for normal bags, then one section per special bag type.
-- Used for the live inventory, the live bank, and saved bank snapshots.
local _, ns = ...
local API = ns.API

local BagIndex = Enum and Enum.BagIndex or {}

local BACKPACK = BACKPACK_CONTAINER or BagIndex.Backpack or 0
-- Forever puts the keyring at -1 (where old clients kept the main bank slots).
local KEYRING = BagIndex.Keyring or KEYRING_CONTAINER

-- Two bank models:
--   "tabs":   modern clients (incl. Forever). The bank is a set of purchasable
--             tabs, each its own bag (CharacterBankTab_1, _2, ...).
--   "legacy": one main bank container plus purchasable bank bags.
local BANK_TABS = {}
do
	local i = 1
	while BagIndex["CharacterBankTab_" .. i] do
		table.insert(BANK_TABS, BagIndex["CharacterBankTab_" .. i])
		i = i + 1
	end
end
ns.bankModel = #BANK_TABS > 0 and "tabs" or "legacy"

local BANK = BANK_CONTAINER or BagIndex.Bank
if BANK == nil and ns.bankModel == "legacy" then BANK = -1 end
ns.BANK_CONTAINER = BANK -- nil on tab-based clients

-- Only treat a reagent bag as real if the client actually has a reagent bag slot.
local NUM_REAGENT = NUM_REAGENTBAG_SLOTS or (CharacterReagentBag0Slot and 1) or 0
local REAGENT_BAG = NUM_REAGENT > 0 and Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag or nil

local bit_band = bit and bit.band

-- Bag family bit flags, as returned by GetContainerNumFreeSlots / GetItemFamily.
local FAMILY_NAMES = {
	[0x0001] = "Quiver",
	[0x0002] = "Ammo Pouch",
	[0x0004] = "Soul Bag",
	[0x0008] = "Leatherworking Bag",
	[0x0010] = "Inscription Bag",
	[0x0020] = "Herb Bag",
	[0x0040] = "Enchanting Bag",
	[0x0080] = "Engineering Bag",
	[0x0100] = "Keyring",
	[0x0200] = "Gem Bag",
	[0x0400] = "Mining Bag",
}

local function FamilyName(family)
	if family == "reagent" then return "Reagent Bag" end
	if family == "keyring" then return "Keyring" end
	if FAMILY_NAMES[family] then return FAMILY_NAMES[family] end
	-- Bags that allow several families: name it after the lowest known bit.
	if bit_band then
		local bit = 1
		while bit <= 0x8000 do
			if bit_band(family, bit) ~= 0 and FAMILY_NAMES[bit] then
				return FAMILY_NAMES[bit]
			end
			bit = bit * 2
		end
	end
	return "Special Bag"
end

local function SortValue(family)
	if family == "keyring" then return math.huge end
	if family == "reagent" then return 1e9 end
	return family
end

---------------------------------------------------------------------------
-- Bag IDs
---------------------------------------------------------------------------
local function LastBagID()
	return (NUM_BAG_SLOTS or 4) + NUM_REAGENT
end

function ns.GetInventoryBagIDs()
	local ids = {}
	for bag = BACKPACK, LastBagID() do table.insert(ids, bag) end
	return ids
end

local bankBagIDs
function ns.GetBankBagIDs()
	if bankBagIDs then return bankBagIDs end
	if ns.bankModel == "tabs" then
		bankBagIDs = BANK_TABS
	else
		bankBagIDs = { BANK }
		local first = BagIndex.BankBag_1 or (LastBagID() + 1)
		for i = 0, (NUM_BANKBAGSLOTS or 6) - 1 do
			table.insert(bankBagIDs, first + i)
		end
	end
	return bankBagIDs
end

-- Is this bag ID one of the player's carried bags (not bank)?
function ns.IsInventoryBag(bag)
	if KEYRING and bag == KEYRING then return true end
	return bag >= BACKPACK and bag <= LastBagID()
end

function ns.IsBankBag(bag)
	for _, id in ipairs(ns.GetBankBagIDs()) do
		if id == bag then return true end
	end
	return false
end

-- True once the client has sent us the bank's contents (at a banker).
function ns.IsBankLoaded()
	for _, bag in ipairs(ns.GetBankBagIDs()) do
		if API.GetNumSlots(bag) > 0 then return true end
	end
	return false
end

-- Tab names from the client, when it has them. bagID -> name
local function BankTabNames()
	local names = {}
	if C_Bank and C_Bank.FetchPurchasedBankTabData and Enum.BankType then
		local ok, tabs = pcall(C_Bank.FetchPurchasedBankTabData, Enum.BankType.Character)
		if ok and type(tabs) == "table" then
			for _, tab in ipairs(tabs) do
				if tab.ID and tab.name and tab.name ~= "" then names[tab.ID] = tab.name end
			end
		end
	end
	return names
end

---------------------------------------------------------------------------
-- Entries: { bag, numSlots, numFree, family }
---------------------------------------------------------------------------
local function LiveEntry(bag)
	local numSlots = API.GetNumSlots(bag)
	if numSlots <= 0 then return nil end
	local free, family = API.GetFreeSlots(bag)
	family = family or 0
	if REAGENT_BAG and bag == REAGENT_BAG then family = "reagent" end
	return { bag = bag, numSlots = numSlots, numFree = free or 0, family = family }
end

-- The keyring is big (32 slots) and keys go there automatically, so only show
-- it when it has keys, and only as many rows as it needs.
local function KeyringEntry()
	if not KEYRING then return nil end
	local size = GetKeyRingSize and GetKeyRingSize() or API.GetNumSlots(KEYRING)
	if not size or size <= 0 then return nil end
	local used, last = 0, 0
	for slot = 1, size do
		if API.GetSlotInfo(KEYRING, slot) then
			used = used + 1
			last = slot
		end
	end
	if used == 0 then return nil end
	local cols = ns.db.columns
	local shown = math.min(size, math.ceil(last / cols) * cols)
	return { bag = KEYRING, numSlots = shown, numFree = shown - used, family = "keyring" }
end

--[[
Groups entries into an ordered list of sections:
  {
    key    = "main" | "family:<n>" | "reagent" | "keyring",
    title  = string or nil (nil for the main section),
    family = number | "reagent" | "keyring",
    bags   = { entry, ... },
    numSlots, numFree,
  }
The main section always comes first, even when empty.
]]
function ns.GroupSections(entries)
	local main = { key = "main", family = 0, bags = {}, numSlots = 0, numFree = 0 }
	local byFamily, special = {}, {}

	for _, entry in ipairs(entries) do
		local family = entry.family or 0
		local section = main
		if family ~= 0 then
			section = byFamily[family]
			if not section then
				section = {
					key = type(family) == "string" and family or ("family:" .. family),
					title = FamilyName(family),
					family = family,
					bags = {},
					numSlots = 0,
					numFree = 0,
				}
				byFamily[family] = section
				table.insert(special, section)
			end
		end
		table.insert(section.bags, entry)
		section.numSlots = section.numSlots + entry.numSlots
		section.numFree = section.numFree + entry.numFree
	end

	table.sort(special, function(a, b) return SortValue(a.family) < SortValue(b.family) end)
	local sections = { main }
	for _, section in ipairs(special) do table.insert(sections, section) end
	return sections
end

function ns.GetInventorySections()
	local entries = {}
	for _, bag in ipairs(ns.GetInventoryBagIDs()) do
		local entry = LiveEntry(bag)
		if entry then table.insert(entries, entry) end
	end
	if ns.db.showKeyring then
		local keyring = KeyringEntry()
		if keyring then table.insert(entries, keyring) end
	end
	return ns.GroupSections(entries)
end

-- Bank tabs each get their own titled section (like Blizzard's bank tabs);
-- legacy banks group bank bags like the inventory does.
local function BankSections(entries)
	if ns.bankModel ~= "tabs" then
		return ns.GroupSections(entries)
	end
	local sections = {}
	for i, entry in ipairs(entries) do
		table.insert(sections, {
			key = "tab:" .. entry.bag,
			title = entry.title or ("Tab " .. i),
			family = 0,
			plain = true, -- normal (untinted) empty slots
			bags = { entry },
			numSlots = entry.numSlots,
			numFree = entry.numFree,
		})
	end
	return sections
end

function ns.GetLiveBankSections()
	local names = ns.bankModel == "tabs" and BankTabNames() or {}
	local entries = {}
	for _, bag in ipairs(ns.GetBankBagIDs()) do
		local entry = LiveEntry(bag)
		if entry then
			entry.title = names[bag]
			table.insert(entries, entry)
		end
	end
	return BankSections(entries)
end

-- Snapshot bags are stored as entries with an extra `items` table.
-- Bags that aren't bank bags (from older, buggy snapshots) are skipped.
function ns.GetSnapshotSections(snapshot)
	local entries = {}
	for _, entry in ipairs(snapshot.bags) do
		if ns.IsBankBag(entry.bag) then table.insert(entries, entry) end
	end
	return BankSections(entries)
end
