-- Attaching Edit Mode elements to each other. In Edit Mode, under an
-- element's settings (and in an extra bar's dialog): pick a side, click
-- Attach, then click the element to attach it to. It then sits on that side
-- of it - as close as it was (or 2 apart, if they overlapped), as far along
-- as it was - and moves with it. When the one it's attached to is hidden, it
-- takes its place (and so on down a chain); when it shows again, it moves
-- back.
--
-- Fine-tuning: Gap - and + (below zero overlaps them: bars whose outlines
-- leave space), or the arrow keys on a selected element (Edit Mode's
-- nudging: along it, or nearer and farther).
--
-- Kept with the Edit Mode layout, like layers (FireMove.lua: Save, Revert).
-- Detach, Revert, or a layout without it: back where Edit Mode had it.
-- Dragging an attached element detaches it, where you drop it. Never during
-- combat (action bars can't be moved then): once it ends.
--
-- Only plain anchoring of the frames you pick: nothing of Edit Mode's own is
-- changed (asking it to re-place a frame would write to its tables, which
-- taints it) - so where Edit Mode had a frame is remembered from before it
-- was first moved here.
local _, ns = ...

local Attach = {}
ns.Attach = Attach

local SIDES = { { "TOP", "Above" }, { "BOTTOM", "Below" }, { "LEFT", "Left of" }, { "RIGHT", "Right of" } }
local SIDE_WORDS = { TOP = "above", BOTTOM = "below", LEFT = "left of", RIGHT = "right of" }
local GAP, GAP_MAX = 2, 40 -- apart, unless they already were a little apart

local side = "TOP" -- for the next one attached
local pending      -- waiting for combat to end
local soon         -- an update already on its way
local hooked = {}  -- [frame] = true: its show/hide, drag and nudges are watched
local placed = {}  -- [frame] = { home = its points before, last = the points we gave it }
local rows = {}    -- the controls (see Attach.CreateRow)

local function Store(create)
	local all = FireMoveLayers and FireMoveLayers.attach
	if not all then return end
	local key = ns.Layout and ns.Layout() or "none"
	if create then all[key] = all[key] or {} end
	return all[key]
end

function Attach.Of(frame)
	local s, key = Store(), frame and ns.Key(frame)
	return s and key and s[key]
end

-- "Action Bar 2", "Vehicle Exit Button"...
local function Label(frame)
	if not frame then return "?" end
	if frame.n and frame.actionButtons then return "Action Bar " .. frame.n end
	if frame.GetSystemName then
		local ok, name = pcall(frame.GetSystemName, frame)
		if ok and type(name) == "string" then return name end
	end
	return frame:GetName() or "?"
end

---------------------------------------------------------------------------
-- Placing
---------------------------------------------------------------------------

local function Points(frame)
	local list = {}
	for i = 1, frame:GetNumPoints() do list[i] = { frame:GetPoint(i) } end
	return list
end

local function SetPoints(frame, list)
	frame:ClearAllPoints()
	for _, p in ipairs(list) do pcall(frame.SetPoint, frame, unpack(p)) end
end

-- Has something else placed it since we did (the game applying a layout)?
local function Moved(frame, last)
	if not last then return true end
	local now = Points(frame)
	if #now ~= #last then return true end
	for i, p in ipairs(now) do
		local q = last[i]
		for j = 1, 5 do
			local a, b = p[j], q[j]
			if type(a) == "number" and type(b) == "number" then
				if math.abs(a - b) > 0.01 then return true end
			elseif a ~= b then
				return true
			end
		end
	end
	return false
end

-- Next to its target, or in its place while it's hidden. false if the game
-- won't (the target is placed relative to it): then it's left as it was.
local function Place(frame, a)
	local target = ns.Find(a.to)
	if not (target and target.IsVisible) then return true end
	local p = placed[frame]
	if not p or Moved(frame, p.last) then
		p = { home = Points(frame) }
		placed[frame] = p
	end
	local shown = target:IsVisible()
	local off, gap = a.off or 0, shown and (a.gap or GAP) or 0
	local point, rel, x, y
	if a.side == "TOP" then
		point, rel, x, y = "BOTTOM", shown and "TOP" or "BOTTOM", off, gap
	elseif a.side == "BOTTOM" then
		point, rel, x, y = "TOP", shown and "BOTTOM" or "TOP", off, -gap
	elseif a.side == "LEFT" then
		point, rel, x, y = "RIGHT", shown and "LEFT" or "RIGHT", -gap, off
	else
		point, rel, x, y = "LEFT", shown and "RIGHT" or "LEFT", gap, off
	end
	local old = Points(frame)
	frame:ClearAllPoints()
	if pcall(frame.SetPoint, frame, point, target, rel, x, y) then
		p.last = Points(frame)
		return true
	end
	SetPoints(frame, old)
	if not p.last then placed[frame] = nil end
	return false
end

local Watch

function Attach.Apply()
	soon = nil
	if InCombatLockdown() then
		pending = true
		return
	end
	pending = false
	local s = Store() or {}
	-- No longer attached (detached, reverted, a layout without it): back
	-- where Edit Mode had it - unless something has placed it since.
	for frame, p in pairs(placed) do
		local key = ns.Key(frame)
		if not (key and s[key]) then
			if not Moved(frame, p.last) then SetPoints(frame, p.home) end
			placed[frame] = nil
		end
	end
	for key, a in pairs(s) do
		local frame = ns.Find(key)
		if frame and not (frame.IsForbidden and frame:IsForbidden()) then
			Watch(frame)
			local target = ns.Find(a.to)
			if target then Watch(target) end
			Place(frame, a)
		end
	end
end

-- Several changes at once (a layout applied, bars shown...): one update.
function Attach.Soon()
	if soon then return end
	soon = true
	C_Timer.After(0, Attach.Apply)
end

---------------------------------------------------------------------------
-- Attaching and detaching
---------------------------------------------------------------------------

local function Refresh()
	for _, r in ipairs(rows) do r.Refresh() end
end
Attach.Refresh = Refresh

-- Would attaching frame to target make a loop (target attached, down the line, to frame)?
local function Loops(frame, target)
	local s, key, to = Store(), ns.Key(frame), ns.Key(target)
	local seen = {}
	while to and not seen[to] do
		if to == key then return true end
		seen[to] = true
		to = s and s[to] and s[to].to
	end
	return false
end

-- How it sits beside the target now: how far along, and how far apart.
local function Measure(frame, target, s)
	local fl, fb, fw, fh = frame:GetRect()
	local tl, tb, tw, th = target:GetRect()
	if not (fl and tl) then return 0, GAP end
	local k = target:GetEffectiveScale() / frame:GetEffectiveScale()
	tl, tb, tw, th = tl * k, tb * k, tw * k, th * k
	local off, gap
	if s == "TOP" or s == "BOTTOM" then
		off = (fl + fw / 2) - (tl + tw / 2)
		gap = s == "TOP" and fb - (tb + th) or tb - (fb + fh)
	else
		off = (fb + fh / 2) - (tb + th / 2)
		gap = s == "LEFT" and tl - (fl + fw) or fl - (tl + tw)
	end
	if gap < 0 or gap > GAP_MAX then gap = GAP end
	return math.floor(off + 0.5), math.floor(gap + 0.5)
end

local function Say(text) print("|cffff8030FireMove|r: " .. text) end

function Attach.Set(frame, target, s)
	if not (frame and target) or frame == target or InCombatLockdown() then return end
	if Loops(frame, target) then
		return Say(("%s is attached to %s: can't attach it the other way too."):format(Label(target), Label(frame)))
	end
	local key, to = ns.Key(frame), ns.Key(target)
	if not (key and to) then return end
	local off, gap = Measure(frame, target, s)
	local store = Store(true)
	local before = store[key]
	store[key] = { to = to, side = s, off = off, gap = gap }
	Watch(frame)
	Watch(target)
	if not Place(frame, store[key]) then
		store[key] = before
		return Say(("can't attach %s to %s: it's placed relative to %s."):format(Label(frame), Label(target), Label(frame)))
	end
	ns.Changed()
	Refresh()
end

-- Off its target: back where Edit Mode had it - or, dragged off, where it
-- was dropped (Edit Mode keeps that itself).
function Attach.Detach(frame, dragged)
	local s, key = Store(), frame and ns.Key(frame)
	if not (s and key and s[key]) then return end
	s[key] = nil
	if dragged then placed[frame] = nil end
	Attach.Apply()
	ns.Changed()
	Refresh()
end

-- Nearer or farther (gap), or along the edge (off).
local function Adjust(frame, gap, off)
	local a = Attach.Of(frame)
	if not a then return end
	a.gap = math.max(-GAP_MAX, math.min(GAP_MAX, (a.gap or GAP) + (gap or 0)))
	a.off = (a.off or 0) + (off or 0)
	Attach.Apply()
	ns.Changed()
	Refresh()
end

-- Edit Mode's arrow keys moved an attached element (dx right, dy up):
-- the same, kept with the attachment.
local function Nudged(frame, dx, dy)
	local a = Attach.Of(frame)
	if not a then return end
	if a.side == "TOP" then Adjust(frame, dy, dx)
	elseif a.side == "BOTTOM" then Adjust(frame, -dy, dx)
	elseif a.side == "LEFT" then Adjust(frame, -dx, dy)
	else Adjust(frame, dx, dy) end
end

-- A different side for one attached already: as close as before, centred.
local function SetSide(frame, s)
	local a = Attach.Of(frame)
	if not a or a.side == s then return end
	a.side, a.off, a.gap = s, 0, a.gap or GAP
	Attach.Apply()
	ns.Changed()
end

-- Watched: shown or hidden (what's attached to it moves), dragged in Edit
-- Mode (it's detached), nudged with the arrow keys (kept).
function Watch(frame)
	if hooked[frame] then return end
	hooked[frame] = true
	frame:HookScript("OnShow", Attach.Soon)
	frame:HookScript("OnHide", Attach.Soon)
	if frame.system then
		if frame.OnDragStop then
			hooksecurefunc(frame, "OnDragStop", function(self)
				if Attach.Of(self) then Attach.Detach(self, true) end
			end)
		end
		if frame.BreakFrameSnap then
			hooksecurefunc(frame, "BreakFrameSnap", function(self, dx, dy)
				if (dx and dx ~= 0) or (dy and dy ~= 0) then Nudged(self, dx or 0, dy or 0) end
			end)
		end
	end
end

---------------------------------------------------------------------------
-- Picking what to attach to: the next click on an Edit Mode element
---------------------------------------------------------------------------

local catcher, picking

local function Candidates()
	local list = {}
	local manager = EditModeManagerFrame
	for _, f in ipairs(manager and manager.registeredSystemFrames or {}) do list[#list + 1] = f end
	for _, f in ipairs(ns.BarFrames and ns.BarFrames() or {}) do list[#list + 1] = f end
	return list
end

-- The element under the mouse (the smallest, when they overlap).
local function Under()
	local best, area
	for _, f in ipairs(Candidates()) do
		if f ~= picking and f:IsVisible() and f:IsMouseOver() then
			local w, h = f:GetSize()
			local a = (w or 0) * (h or 0) * f:GetEffectiveScale() ^ 2
			if not best or a < area then best, area = f, a end
		end
	end
	return best
end

local function StopPicking()
	picking = nil
	if catcher then catcher:Hide() end
	Refresh()
end

local function CreateCatcher()
	catcher = CreateFrame("Frame", "FireMoveAttachPicker", UIParent)
	catcher:SetAllPoints(UIParent)
	catcher:SetFrameStrata("FULLSCREEN_DIALOG")
	catcher:EnableMouse(true)
	catcher:EnableKeyboard(true)
	catcher.hint = catcher:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
	catcher.hint:SetPoint("TOP", 0, -120)
	catcher.elapsed = 0
	catcher:SetScript("OnUpdate", function(self, elapsed)
		self.elapsed = self.elapsed + elapsed
		if self.elapsed < 0.1 then return end
		self.elapsed = 0
		local under = Under()
		self.hint:SetText(("Attach %s %s: %s  |cff999999(Escape or right-click: cancel)|r"):format(Label(picking),
			SIDE_WORDS[side], under and ("|cffffd100" .. Label(under) .. "|r") or "click an element"))
	end)
	-- A click on an element attaches to it; anywhere else, or right-click, cancels.
	catcher:SetScript("OnMouseDown", function(_, button)
		local frame, target = picking, button ~= "RightButton" and Under()
		StopPicking()
		if target then Attach.Set(frame, target, side) end
	end)
	catcher:SetScript("OnKeyDown", function(self, key)
		if key == "ESCAPE" then
			self:SetPropagateKeyboardInput(false)
			StopPicking()
		else
			self:SetPropagateKeyboardInput(true)
		end
	end)
	catcher:Hide()
end

function Attach.Pick(frame)
	if not frame or InCombatLockdown() then return end
	if not catcher then CreateCatcher() end
	picking = frame
	catcher.elapsed = 1
	catcher:Show()
	Refresh()
end

---------------------------------------------------------------------------
-- The controls: "Attached above Action Bar 2", Gap - 2 +, the side,
-- Attach, Detach. getFrame: the element they're for (or nil).
---------------------------------------------------------------------------

function Attach.CreateRow(parent, getFrame, width)
	width = width or 200
	local row = CreateFrame("Frame", nil, parent)
	row:SetSize(width, 46)
	row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.text:SetPoint("TOPLEFT")
	row.text:SetWidth(width - 74)
	row.text:SetJustifyH("LEFT")
	row.text:SetWordWrap(false)
	local function Small(text, onClick)
		local b = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		b:SetSize(20, 18)
		b:SetText(text)
		b:SetScript("OnClick", function() onClick(IsShiftKeyDown() and 10 or 1) end)
		return b
	end
	local plus = Small("+", function(step) Adjust(getFrame(), step) end)
	plus:SetPoint("TOPRIGHT", 0, 2)
	local gap = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	gap:SetPoint("RIGHT", plus, "LEFT", -2, 0)
	gap:SetWidth(22)
	local minus = Small("-", function(step) Adjust(getFrame(), -step) end)
	minus:SetPoint("RIGHT", gap, "LEFT", -2, 0)
	for _, b in ipairs({ minus, plus }) do
		b:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:SetText("Gap", 1, 1, 1)
			GameTooltip:AddLine("Below 0 overlaps them. Shift: 10. Arrow keys in Edit Mode nudge it too.", nil, nil, nil, true)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end
	local dd = CreateFrame("DropdownButton", nil, row, "WowStyle1DropdownTemplate")
	dd:SetWidth(width - 128)
	dd:SetPoint("BOTTOMLEFT", 0, 0)
	dd:SetupMenu(function(_, root)
		for _, option in ipairs(SIDES) do
			root:CreateRadio(option[2], function()
				local a = Attach.Of(getFrame())
				return (a and a.side or side) == option[1]
			end, function()
				side = option[1]
				local frame = getFrame()
				if frame then SetSide(frame, option[1]) end
				Refresh()
			end)
		end
	end)
	local function Button(text, onClick)
		local b = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		b:SetSize(60, 22)
		b:SetText(text)
		b:SetScript("OnClick", onClick)
		return b
	end
	local attach = Button("Attach", function() Attach.Pick(getFrame()) end)
	attach:SetPoint("BOTTOMRIGHT", -62, 0)
	local detach = Button("Detach", function() Attach.Detach(getFrame()) end)
	detach:SetPoint("BOTTOMRIGHT", 0, 0)
	local r = { row = row }
	function r.Refresh()
		local frame = getFrame()
		local a = frame and Attach.Of(frame)
		if picking and picking == frame then
			row.text:SetText("|cffffd100Click what to attach it to|r")
		elseif a then
			row.text:SetText(("Attached %s %s"):format(SIDE_WORDS[a.side] or "to", Label(ns.Find(a.to))))
		else
			row.text:SetText("|cff999999Not attached|r")
		end
		gap:SetText(a and tostring(a.gap or GAP) or "")
		minus:SetShown(a ~= nil)
		plus:SetShown(a ~= nil)
		attach:SetEnabled(frame ~= nil and not InCombatLockdown())
		detach:SetEnabled(a ~= nil)
		dd:GenerateMenu()
	end
	rows[#rows + 1] = r
	r.Refresh()
	return row
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function()
	if pending then Attach.Apply() end
	Refresh()
end)

-- TEMPORARY (Profile.lua)
Attach.Apply = ns.Timed("Attach.Apply", Attach.Apply)
events:SetScript("OnEvent", ns.Timed("Attach event", events:GetScript("OnEvent"), true))
