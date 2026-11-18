-- FireMove: drag Blizzard's windows (character, spellbook, merchant, mail,
-- auction house...) by any empty spot. They stay where you put them, through
-- reloads. /firemove reset puts them all back.
--
-- Which windows: every one the game opens as a panel (UIPanelWindows, and any
-- shown with ShowUIPanel - including ones that load later). The game places
-- panels itself whenever one opens or closes; a moved one is put back where
-- you left it right after.
--
-- Layers: in Edit Mode, a box under the selected frame's settings brings it
-- forward or sends it back, kept with the Edit Mode layout. /firemove layers
-- puts this layout's back.
--
-- Extra action bars: see Bars.lua. Attaching elements to each other: Attach.lua.
-- The main bar's look for the game's other bars: Style.lua.
local _, ns = ...
local DB -- FireMoveDB: [frame name] = { point, relativePoint, x, y }

local made, waiting = {}, {}
local home = {} -- [frame] = its points before any moving, for a reset
-- Never moved: the Escape menu (too easy to drag by accident), and Edit
-- Mode's window (the game moves it itself; placing it from an addon taints
-- leaving Edit Mode, and the game blocks that).
local SKIP = { GameMenuFrame = true, EditModeManagerFrame = true }

local function Locked(frame)
	return frame:IsProtected() and InCombatLockdown()
end

-- Put a moved window back where you left it.
local function Place(frame)
	local name = frame:GetName()
	local pos = DB and name and DB[name]
	if not pos or Locked(frame) then return end
	frame:ClearAllPoints()
	frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
end

local function PlaceShown()
	for frame in pairs(made) do
		if frame:IsShown() then Place(frame) end
	end
end
Place = ns.Timed("Place", Place)
PlaceShown = ns.Timed("PlaceShown", PlaceShown)

-- A child laid over the whole window (like the group finder's tabs) takes the
-- clicks, so it drags the window too.
local function Covers(child, frame)
	if not child:IsObjectType("Frame") or child:IsObjectType("Button") or child:IsObjectType("ScrollFrame") then return false end
	if not child:IsMouseEnabled() then return false end
	local n = child:GetNumPoints()
	if n == 2 then
		local p1, r1, _, x1, y1 = child:GetPoint(1)
		local p2, r2, _, x2, y2 = child:GetPoint(2)
		if r1 == frame and r2 == frame and x1 == 0 and y1 == 0 and x2 == 0 and y2 == 0
			and ((p1 == "TOPLEFT" and p2 == "BOTTOMRIGHT") or (p1 == "BOTTOMRIGHT" and p2 == "TOPLEFT")) then
			return true
		end
	end
	local w, h, fw, fh = child:GetWidth(), child:GetHeight(), frame:GetWidth(), frame:GetHeight()
	return w > 0 and h > 0 and math.abs(w - fw) < 2 and math.abs(h - fh) < 2
end

local function Grip(handle, frame)
	handle:RegisterForDrag("LeftButton")
	handle:HookScript("OnDragStart", function()
		if not Locked(frame) then frame:StartMoving() end
	end)
	handle:HookScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		-- Ours to keep, not the game's layout file (it would fight the panel placement).
		frame:SetUserPlaced(false)
		local point, _, relativePoint, x, y = frame:GetPoint(1)
		if point then DB[frame:GetName()] = { point, relativePoint, x, y } end
	end)
	for _, child in ipairs({ handle:GetChildren() }) do
		if not (child.IsForbidden and child:IsForbidden()) and Covers(child, handle) then Grip(child, frame) end
	end
end

local function Make(frame)
	if made[frame] or not frame.GetName or not frame:GetName() or SKIP[frame:GetName()] then return end
	if frame.IsForbidden and frame:IsForbidden() then return end
	if Locked(frame) then
		waiting[frame] = true
		return
	end
	made[frame] = true
	local points = {}
	for i = 1, frame:GetNumPoints() do points[i] = { frame:GetPoint(i) } end
	home[frame] = points
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	Grip(frame, frame)
	frame:HookScript("OnShow", Place)
	if frame:IsShown() then Place(frame) end
end

local function MakeAll()
	if not UIPanelWindows then return end
	for name in pairs(UIPanelWindows) do
		local frame = _G[name]
		if type(frame) == "table" and frame.SetMovable then Make(frame) end
	end
end

-- The game just placed its panels: put the moved ones back.
if ShowUIPanel then
	hooksecurefunc("ShowUIPanel", function(frame)
		if frame then Make(frame) end
		PlaceShown()
	end)
end
if HideUIPanel then hooksecurefunc("HideUIPanel", PlaceShown) end
if UpdateUIPanelPositions then hooksecurefunc("UpdateUIPanelPositions", PlaceShown) end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function(_, event, addon)
	if event == "ADDON_LOADED" and addon == "FireMove" then
		FireMoveDB = FireMoveDB or {}
		DB = FireMoveDB
		for name in pairs(SKIP) do DB[name] = nil end
	elseif event == "PLAYER_REGEN_ENABLED" then
		-- Ones that couldn't be set up during combat.
		for frame in pairs(waiting) do
			waiting[frame] = nil
			Make(frame)
		end
		PlaceShown()
		return
	end
	-- Windows that load later (auction house, trainers...) register as they load.
	if DB then MakeAll() end
end)

-- Every window back where the game puts it, open ones too.
local function Reset()
	if not DB then return end
	wipe(DB)
	for frame, points in pairs(home) do
		if #points > 0 and not Locked(frame) then
			frame:ClearAllPoints()
			for _, p in ipairs(points) do frame:SetPoint(unpack(p)) end
		end
	end
	if UpdateUIPanelPositions then UpdateUIPanelPositions() end
	print("|cffff8030FireMove|r: windows are back in their usual places.")
end

---------------------------------------------------------------------------
-- Layers: in Edit Mode, a box under the selected frame's settings puts it in
-- front of or behind other frames (its frame strata). Kept with the Edit Mode
-- layout in use: switch layouts and the layers switch too; a new layout starts
-- with the layers of the one it's made from. Never during combat: then once
-- it ends.
---------------------------------------------------------------------------
local LAYERS = { "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG" }
local LAYER_NAMES = { BACKGROUND = "Bottom", LOW = "Low", MEDIUM = "Middle", HIGH = "High", DIALOG = "Top" }
-- FireMoveLayers: profiles = { [layout] = { [frame] = strata } },
-- own = { [frame] = its own strata, before any change },
-- bars = { [layout] = { [bar] = its settings } } (Bars.lua),
-- attach = { [layout] = { [frame] = { to, side, off, gap } } } (Attach.lua),
-- style = { [layout] = { [bar] = "main" } } (Style.lua)
local LDB
local layers         -- the layout in use's { [frame] = strata }, once known
local current, previous -- the layout in use, and the one before it
local names = {}     -- [layout index] = layout key, to follow renames and deletes
local layerPending = {} -- [frame] = strata, waiting for combat to end
local box

local function LayerIndex(strata)
	for i, s in ipairs(LAYERS) do
		if s == strata then return i end
	end
end

-- How a frame is kept: its name, or for unnamed ones (the end caps) its Edit
-- Mode system and index, "system:index".
local function Key(frame)
	local name = frame.GetName and frame:GetName()
	if name then return name end
	if type(frame.system) == "number" then return frame.system .. ":" .. (frame.systemIndex or "") end
end

ns.Key = Key

local function Find(key)
	local system, index = key:match("^(%d+):(%d*)$")
	if not system then return _G[key] end
	local manager = EditModeManagerFrame
	if not (manager and manager.GetRegisteredSystemFrame) then return end
	return manager:GetRegisteredSystemFrame(tonumber(system), tonumber(index))
end

ns.Find = Find

local function Usable(frame)
	return type(frame) == "table" and frame.SetFrameStrata and Key(frame)
		and not (frame.IsForbidden and frame:IsForbidden())
end

local function SetStrata(frame, strata)
	if Locked(frame) then
		layerPending[frame] = strata
		return
	end
	layerPending[frame] = nil
	frame:SetFrameStrata(strata)
end

-- How a layout is kept: account-wide ones and presets by name, a character's
-- own by character and name.
local function LayoutKey(info)
	if not (info and info.layoutName) then return end
	local types = Enum and Enum.EditModeLayoutType or {}
	if types.Character and info.layoutType == types.Character then
		local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName and GetRealmName()) or ""
		return "char:" .. (UnitName("player") or "") .. "-" .. realm .. ":" .. info.layoutName
	elseif types.Preset and info.layoutType == types.Preset then
		return "preset:" .. info.layoutName
	end
	return "account:" .. info.layoutName
end

local function Layouts()
	local manager = EditModeManagerFrame
	return manager and manager.layoutInfo and manager.layoutInfo.layouts
end

local function Snapshot()
	wipe(names)
	for i, info in ipairs(Layouts() or {}) do names[i] = LayoutKey(info) end
end

local function Depth(frame)
	local d, parent = 0, frame:GetParent()
	while parent and d < 50 do
		d, parent = d + 1, parent:GetParent()
	end
	return d
end

local ApplyLayers

-- The game puts action bars back on their usual layer whenever the button
-- grid shows or hides (on top while dragging a spell: left alone, it puts
-- them back after). Then: ours again.
local watched = {}
local function Reapply(bar)
	if bar:GetFrameStrata() ~= "TOOLTIP" then ApplyLayers() end
end

local function Watch(frame)
	while frame and frame ~= UIParent and not watched[frame] do
		watched[frame] = true
		if frame.UpdateFrameStrata then hooksecurefunc(frame, "UpdateFrameStrata", Reapply) end
		frame = frame:GetParent()
	end
end

-- Every frame ever layered: on this layout's layer, or back on its own. A
-- frame's layer carries to the frames inside it (the end caps are inside the
-- main action bar): so the ones on their own first, then the layered ones,
-- outer before inner.
function ApplyLayers()
	if not (LDB and layers) then return end
	local list = {}
	for key, own in pairs(LDB.own) do
		local frame = Find(key)
		if Usable(frame) then
			Watch(frame)
			if frame:GetFrameStrata() ~= "TOOLTIP" then
				list[#list + 1] = { frame = frame, strata = layers[key] or own, set = layers[key] ~= nil, depth = Depth(frame) }
			end
		end
	end
	table.sort(list, function(a, b)
		if a.set ~= b.set then return not a.set end
		return a.depth < b.depth
	end)
	for _, e in ipairs(list) do SetStrata(e.frame, e.strata) end
end

-- The frame Edit Mode has selected (its settings are open).
local function Selected()
	local dialog = EditModeSystemSettingsDialog
	local frame = dialog and dialog:IsShown() and dialog.attachedToSystem
	if frame and Usable(frame) then return frame end
end

local function Strata(frame)
	return layerPending[frame] or frame:GetFrameStrata()
end

local function UpdateBox()
	if not box then return end
	local frame = Selected()
	if not (frame and layers) then return box:Hide() end
	local strata = Strata(frame)
	local i = LayerIndex(strata)
	box.value:SetText("Layer: " .. (LAYER_NAMES[strata] or strata))
	box.back:SetEnabled(i ~= nil and i > 1)
	box.forward:SetEnabled(i ~= nil and i < #LAYERS)
	box.default:SetEnabled(layers[Key(frame)] ~= nil)
	local styled = ns.Style and box.style and box.style.Refresh()
	box:SetHeight(styled and 148 or 118)
	box:Show()
	if ns.Attach then ns.Attach.Refresh() end
end

-- The layout in use (Edit Mode just applied one): its layers.
local function Switch()
	if not LDB then return end
	Snapshot()
	local manager = EditModeManagerFrame
	local key = LayoutKey(manager and manager.GetActiveLayoutInfo and manager:GetActiveLayoutInfo())
	if not key then return end
	if key ~= current then previous, current = current, key end
	LDB.profiles[key] = LDB.profiles[key] or {}
	layers = LDB.profiles[key]
	-- Layers from before they were kept per layout: the first layout seen gets them.
	if LDB.legacy then
		for frame, strata in pairs(LDB.legacy) do
			if layers[frame] == nil then layers[frame] = strata end
		end
		LDB.legacy = nil
	end
	ApplyLayers()
	UpdateBox()
	if ns.LayoutChanged then ns.LayoutChanged() end
	if ns.Style then ns.Style.Apply() end
	if ns.Attach then ns.Attach.Apply() end
end

-- The layout in use, as it's kept (nil until known).
function ns.Layout() return current end

local function SetLayer(frame, strata)
	local key = Key(frame)
	-- The layered frame it's inside, if any: without a layer of its own, it has that one's.
	local outer
	local parent = frame:GetParent()
	while parent and parent ~= UIParent do
		local k = Usable(parent) and Key(parent)
		if k and layers[k] and LDB.own[k] then
			outer = k
			break
		end
		parent = parent:GetParent()
	end
	-- Its own: what it has, unless that's from the layered frame it's inside.
	LDB.own[key] = LDB.own[key] or (outer and LDB.own[outer]) or frame:GetFrameStrata()
	local natural = outer and layers[outer] or LDB.own[key]
	layers[key] = strata ~= natural and strata or nil
	ApplyLayers()
	UpdateBox()
	ns.Changed()
end

local function Step(delta)
	local frame = Selected()
	local i = frame and layers and LayerIndex(Strata(frame))
	local to = i and LAYERS[i + delta]
	if to then SetLayer(frame, to) end
end

local function Default()
	local frame = Selected()
	local key = frame and Key(frame)
	if key and layers and layers[key] then
		layers[key] = nil
		ApplyLayers()
		UpdateBox()
		ns.Changed()
	end
end

local function LayerButton(text, width, onClick, tip)
	local b = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(text)
	b:SetScript("OnClick", onClick)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:SetText(tip, 1, 1, 1)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return b
end

local function CreateBox(dialog)
	box = CreateFrame("Frame", "FireMoveLayerBox", UIParent, "BackdropTemplate")
	box:SetSize(240, 118)
	box:SetFrameStrata("DIALOG")
	box:SetFrameLevel((dialog:GetFrameLevel() or 200) + 10)
	box:SetClampedToScreen(true)
	box:SetPoint("TOP", dialog, "BOTTOM", 0, -2)
	box:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	box.value = box:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	box.value:SetPoint("TOPLEFT", 14, -12)
	box.default = LayerButton("Default", 70, Default, "Back to its usual layer")
	box.default:SetPoint("TOPRIGHT", -10, -8)
	box.back = LayerButton("Send back", 106, function() Step(-1) end, "Behind more frames")
	box.back:SetPoint("TOPLEFT", 10, -36)
	box.forward = LayerButton("Bring forward", 106, function() Step(1) end, "In front of more frames")
	box.forward:SetPoint("TOPRIGHT", -10, -36)
	if ns.Attach then
		box.attach = ns.Attach.CreateRow(box, Selected, 216)
		box.attach:SetPoint("BOTTOM", 0, 10)
	end
	if ns.Style then
		local row
		row, box.style = ns.Style.CreateRow(box, Selected, 216)
		row:SetPoint("TOP", 0, -64)
	end
	box:Hide()
end

local function DeepCopy(t)
	local copy = {}
	for k, v in pairs(t) do copy[k] = type(v) == "table" and DeepCopy(v) or v end
	return copy
end

---------------------------------------------------------------------------
-- Unsaved changes: as with the game's own frames, what's changed in Edit
-- Mode (layers, the extra bars) is kept by Save, and put back by Revert All
-- Changes or by leaving without saving. Changes made outside Edit Mode are
-- kept at once.
---------------------------------------------------------------------------
local saved -- as last saved: { profiles, bars, char }
local stash -- as it was just before a revert (a new layout made from unsaved changes gets them)
local dirty

local function Editing()
	local manager = EditModeManagerFrame
	return manager and manager.IsEditModeActive and manager:IsEditModeActive() and true or false
end

local function Now()
	return {
		profiles = DeepCopy(LDB.profiles),
		bars = DeepCopy(LDB.bars),
		attach = DeepCopy(LDB.attach),
		style = DeepCopy(LDB.style),
		char = DeepCopy(ns.CharBars and ns.CharBars() or {}),
	}
end

-- The Fire addons' unsaved Edit Mode changes: { [addon] = true }. Shared, so
-- each one keeps the game's Save and Revert buttons on for the others' too.
FireEditModeUnsaved = FireEditModeUnsaved or {}

-- The game's Save and Revert buttons: on while anything's unsaved, ours too.
local function SyncButtons()
	FireEditModeUnsaved.FireMove = dirty or nil
	local manager = EditModeManagerFrame
	if not (manager and manager.HasActiveChanges) then return end
	local on = dirty or manager:HasActiveChanges() and true or false
	for _, v in pairs(FireEditModeUnsaved) do
		if v then on = true end
	end
	if manager.SaveChangesButton then manager.SaveChangesButton:SetEnabled(on) end
	if manager.RevertAllChangesButton then manager.RevertAllChangesButton:SetEnabled(on) end
end

-- Saved: what's there now. Presets can't be saved: theirs stay as they were.
local function Commit()
	if not LDB then return end
	local now = Now()
	if saved then
		for _, name in ipairs({ "profiles", "bars", "attach", "style" }) do
			for key in pairs(now[name]) do
				if key:match("^preset:") then now[name][key] = nil end
			end
			for key, value in pairs(saved[name] or {}) do
				if key:match("^preset:") then now[name][key] = DeepCopy(value) end
			end
		end
	end
	saved = now
	dirty = false
	SyncButtons()
end

local function Restore(from)
	LDB.profiles = DeepCopy(from.profiles)
	LDB.bars = DeepCopy(from.bars)
	LDB.attach = DeepCopy(from.attach or {})
	LDB.style = DeepCopy(from.style or {})
	if ns.SetCharBars then ns.SetCharBars(DeepCopy(from.char)) end
	layers = nil
	Switch()
end

-- Something of ours changed: unsaved while in Edit Mode, else kept.
function ns.Changed()
	if Editing() then
		dirty = true
		SyncButtons()
	else
		Commit()
	end
end

-- A bar's settings in this layout as last saved.
function ns.SavedBar(n)
	local layout = saved and current and saved.bars[current]
	return layout and layout[n]
end

-- Left Edit Mode with only our changes unsaved (the game didn't ask): ask.
-- Our own box, not the game's popups: writing to those taints the Escape key.
local ask
local function Ask(unsaved)
	if not ask then
		ask = CreateFrame("Frame", "FireMoveUnsaved", UIParent, "BackdropTemplate")
		ask:SetSize(330, 96)
		ask:SetPoint("TOP", 0, -135)
		ask:SetFrameStrata("DIALOG")
		ask:EnableMouse(true)
		ask:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			tile = true, tileSize = 32, edgeSize = 32,
			insets = { left = 11, right = 12, top = 12, bottom = 11 },
		})
		local text = ask:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		text:SetPoint("TOP", 0, -22)
		text:SetWidth(290)
		text:SetText("Save your changes to FireMove's action bars and layers?")
		local save = CreateFrame("Button", nil, ask, "UIPanelButtonTemplate")
		save:SetSize(120, 22)
		save:SetPoint("BOTTOMRIGHT", ask, "BOTTOM", -6, 18)
		save:SetText(SAVE or "Save")
		save:SetScript("OnClick", function()
			ask:Hide()
			Restore(ask.unsaved)
			Commit()
		end)
		local discard = CreateFrame("Button", nil, ask, "UIPanelButtonTemplate")
		discard:SetSize(120, 22)
		discard:SetPoint("BOTTOMLEFT", ask, "BOTTOM", 6, 18)
		discard:SetText("Discard")
		discard:SetScript("OnClick", function() ask:Hide() end)
	end
	ask.unsaved = unsaved
	ask:Show()
end

-- Revert All Changes, or leaving Edit Mode (the game reverts what's unsaved).
local function Reverted()
	if not (LDB and saved) then return end
	local exiting = not Editing()
	local before = dirty and Now()
	stash = before or nil
	if stash then C_Timer.After(0, function() stash = nil end) end
	local unsavedDialog = EditModeUnsavedChangesDialog
	local asking = exiting and before and not (unsavedDialog and unsavedDialog:IsShown())
	dirty = false
	Restore(saved)
	SyncButtons()
	if asking then Ask(before) end
end

-- What's kept per layout: layers, and the extra bars' settings (as they are, and as saved).
local function Stores()
	local list = { LDB.profiles, LDB.bars, LDB.attach, LDB.style }
	if saved then
		for _, name in ipairs({ "profiles", "bars", "attach", "style" }) do
			if saved[name] then list[#list + 1] = saved[name] end
		end
	end
	return list
end

-- A layout renamed: its layers and bars go with it.
local function Renamed(_, index)
	local old, new = names[index], LayoutKey((Layouts() or {})[index])
	if old and new and old ~= new then
		for _, store in ipairs(Stores()) do
			if store[old] then
				store[new] = store[old]
				store[old] = nil
			end
		end
		if current == old then current = new end
	end
	Snapshot()
end

-- A layout deleted: its layers and bars too.
local function Deleted(_, index)
	local old = names[index]
	if old and old ~= current then
		for _, store in ipairs(Stores()) do store[old] = nil end
	end
	Snapshot()
end

-- A new layout: the layers and bars of the one it was made from, unsaved
-- changes and all (not for imports). It's saved.
local function Made(_, _, layoutType, layoutName, imported)
	local key = LayoutKey({ layoutType = layoutType, layoutName = layoutName })
	local from = current == key and previous or current
	if imported or not key or not from then return end
	local changed
	for _, name in ipairs({ "profiles", "bars", "attach", "style" }) do
		local source = ((stash or LDB)[name] or {})[from]
		if source and not (LDB[name][key] and next(LDB[name][key])) then
			LDB[name][key] = DeepCopy(source)
			if saved and saved[name] then saved[name][key] = DeepCopy(source) end
			changed = true
		end
	end
	if changed and current == key then
		layers = LDB.profiles[key] or layers
		ApplyLayers()
		UpdateBox()
		if ns.LayoutChanged then ns.LayoutChanged() end
		if ns.Style then ns.Style.Apply() end
		if ns.Attach then ns.Attach.Apply() end
	end
end

local hooked
local function HookEditMode()
	local dialog, manager = EditModeSystemSettingsDialog, EditModeManagerFrame
	if hooked or not (dialog and dialog.AttachToSystemFrame and manager and manager.UpdateLayoutInfo) then return end
	hooked = true
	CreateBox(dialog)
	hooksecurefunc(dialog, "AttachToSystemFrame", UpdateBox)
	dialog:HookScript("OnHide", function() box:Hide() end)
	hooksecurefunc(manager, "UpdateLayoutInfo", Switch)
	if manager.RenameLayout then hooksecurefunc(manager, "RenameLayout", Renamed) end
	if manager.DeleteLayout then hooksecurefunc(manager, "DeleteLayout", Deleted) end
	if manager.MakeNewLayout then hooksecurefunc(manager, "MakeNewLayout", Made) end
	if manager.PrepareSystemsForSave then hooksecurefunc(manager, "PrepareSystemsForSave", Commit) end
	if manager.RevertAllChanges then hooksecurefunc(manager, "RevertAllChanges", Reverted) end
	if manager.SetHasActiveChanges then hooksecurefunc(manager, "SetHasActiveChanges", SyncButtons) end
	-- The game re-stacks its bars (one shown or hidden...): attached ones go back next to theirs.
	for _, fn in ipairs({ "UpdateBottomActionBarPositions", "UpdateRightActionBarPositions" }) do
		if manager[fn] then hooksecurefunc(manager, fn, function() if ns.Attach then ns.Attach.Soon() end end) end
	end
	if EventRegistry then
		EventRegistry:RegisterCallback("EditMode.Enter", function() if ask then ask:Hide() end end, {})
	end
end

-- This layout's frames back on their usual layers.
local function ResetLayers()
	if not layers then return end
	wipe(layers)
	ApplyLayers()
	UpdateBox()
	ns.Changed()
	print("|cffff8030FireMove|r: frames are back on their usual layers in this layout.")
end

local layerEvents = CreateFrame("Frame")
layerEvents:RegisterEvent("ADDON_LOADED")
layerEvents:RegisterEvent("PLAYER_LOGIN")
layerEvents:RegisterEvent("PLAYER_ENTERING_WORLD")
layerEvents:RegisterEvent("PLAYER_REGEN_ENABLED")
layerEvents:SetScript("OnEvent", function(_, event, addon)
	if event == "ADDON_LOADED" then
		if addon == "FireMove" then
			FireMoveLayers = FireMoveLayers or {}
			LDB = FireMoveLayers
			-- Before layouts: { [frame] = { strata, own } }.
			local old = {}
			for key, saved in pairs(LDB) do
				if type(saved) == "table" and type(saved[1]) == "string" then old[key] = saved end
			end
			LDB.profiles = LDB.profiles or {}
			LDB.own = LDB.own or {}
			LDB.bars = LDB.bars or {}
			LDB.attach = LDB.attach or {}
			LDB.style = LDB.style or {}
			LDB.dump = nil -- from a one-off look at the buttons' frames
			for key, saved in pairs(old) do
				LDB.legacy = LDB.legacy or {}
				LDB.legacy[key] = saved[1]
				LDB.own[key] = LDB.own[key] or saved[2]
				LDB[key] = nil
			end
		elseif addon == "Blizzard_EditMode" then
			HookEditMode()
		end
	elseif event == "PLAYER_REGEN_ENABLED" then
		wipe(layerPending)
		ApplyLayers()
		UpdateBox()
	else
		HookEditMode()
		Switch()
		if not saved then Commit() end -- as loaded: saved
	end
end)

-- Options > AddOns > FireMove.
local function BuildOptions()
	if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then return end
	local panel = CreateFrame("Frame")
	panel:Hide()
	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("FireMove")
	local about = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	about:SetPoint("TOPLEFT", 16, -40)
	about:SetPoint("RIGHT", -16, 0)
	about:SetJustifyH("LEFT")
	about:SetText("Drag any Blizzard window by an empty spot. It stays where you put it. In Edit Mode, the Layer box "
		.. "under a frame's settings puts it in front of or behind others, saved with the layout. "
		.. "\"New action bar\" under the Edit Mode window adds more bars.")
	local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	reset:SetSize(180, 22)
	reset:SetPoint("TOPLEFT", 20, -76)
	reset:SetText("Reset window positions")
	reset:SetScript("OnClick", Reset)
	local resetLayers = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	resetLayers:SetSize(180, 22)
	resetLayers:SetPoint("LEFT", reset, "RIGHT", 8, 0)
	resetLayers:SetText("Reset layers")
	resetLayers:SetScript("OnClick", ResetLayers)
	local category = Settings.RegisterCanvasLayoutCategory(panel, "FireMove")
	Settings.RegisterAddOnCategory(category)
end

local options = CreateFrame("Frame")
options:RegisterEvent("PLAYER_LOGIN")
options:SetScript("OnEvent", BuildOptions)

SLASH_FIREMOVE1 = "/firemove"
SlashCmdList.FIREMOVE = function(msg)
	msg = msg and msg:lower() or ""
	if msg:match("layers") then
		ResetLayers()
	elseif msg:match("reset") then
		Reset()
	else
		print("|cffff8030FireMove|r: drag any Blizzard window by an empty spot. /firemove reset puts them all back; "
			.. "/firemove layers puts this Edit Mode layout's frames back on their usual layers.")
	end
end

-- TEMPORARY (Profile.lua)
ApplyLayers = ns.Timed("ApplyLayers", ApplyLayers)
Reapply = ns.Timed("Reapply", Reapply)
UpdateBox = ns.Timed("UpdateBox", UpdateBox)
Switch = ns.Timed("Switch", Switch)
events:SetScript("OnEvent", ns.Timed("FireMove event", events:GetScript("OnEvent"), true))
layerEvents:SetScript("OnEvent", ns.Timed("Layers event", layerEvents:GetScript("OnEvent"), true))
