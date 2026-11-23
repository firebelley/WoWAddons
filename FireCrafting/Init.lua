-- Shared setup: saved data, printing, errors and a tiny event bus.
local ADDON, ns = ...

function ns.Print(msg)
	print("|cffff9933FireCrafting|r: " .. msg)
end

-- WoW hides Lua errors unless scriptErrors is on; print each one once.
local reported = {}
function ns.ReportError(err)
	local msg = tostring(err)
	if reported[msg] then return end
	reported[msg] = true
	ns.Print("|cffff4040error:|r " .. msg)
end

function ns.SafeCall(fn, ...)
	return xpcall(fn, ns.ReportError, ...)
end

-- /firecrafting debug: chat notes on what the Craft button does.
function ns.Debug(msg)
	if ns.db and ns.db.debug then print("|cff80a0ffFireCrafting debug|r: " .. msg) end
end

SLASH_FIRECRAFTING1 = "/firecrafting"
SlashCmdList.FIRECRAFTING = function(arg)
	if not ns.db then return end
	if (arg or ""):lower():match("^%s*debug") then
		ns.db.debug = not ns.db.debug or nil
		ns.Print("debug " .. (ns.db.debug and "on" or "off") .. ".")
	else
		ns.Print("/firecrafting debug - chat notes on what the Craft button does.")
	end
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
	for _, fn in ipairs(handlers[event]) do ns.SafeCall(fn, ...) end
end)

-- FireCraftingCharDB:
--   lists   = { [professionID] = { { id = recipeID, n = count }, ... } }
--   recipes = { [recipeID] = { name, icon, prof, out = itemID, made = n,
--               r = { { qty, itemID, alternative itemIDs... }, ... } } }
--             every learned recipe of each profession window you've opened
--   useBags, useBank = count what's there as "have" (default bags only)
--   hidden  = the panel is closed (its tab shows it again)
ns.On("ADDON_LOADED", function(name)
	if name ~= ADDON then return end
	FireCraftingCharDB = FireCraftingCharDB or {}
	local db = FireCraftingCharDB
	db.lists = db.lists or {}
	db.recipes = db.recipes or {}
	-- What counts as "have" (the panel's Bags / Bank toggles).
	if db.useBags == nil then db.useBags = not db.noBags end
	if db.useBank == nil then db.useBank = false end
	db.noBags, db.noBank = nil, nil -- older names
	ns.db = db
end)
