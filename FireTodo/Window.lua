-- The list: every todo, in order. Type a new one at the top (Enter adds it;
-- shift-click items to link them). Each row: its checkbox, its text (click to
-- edit), and on hover Track and Delete. Drag a row to move it; right-click
-- for the rest.
local _, ns = ...
local Todo = ns.Todo

local Window = {}
ns.Window = Window

local WIDTH, HEIGHT = 360, 440
local ROW_MIN = 26
local TRACK_ICON = "Interface\\GossipFrame\\AvailableQuestIcon"

local frame, newBox, scroll, content, editor, insertLine, emptyText, clearButton
local rows = {}
local editing  -- the id of the todo being edited
local dragging -- the row being dragged

local function SavePoint()
	local point, _, rel, x, y = frame:GetPoint()
	ns.db.windowPoint = { point, rel, x, y }
end

local function Tip(owner, text)
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	GameTooltip:SetText(text, 1, 1, 1)
	GameTooltip:Show()
end

---------------------------------------------------------------------------
-- Editing a todo's text, in place
---------------------------------------------------------------------------
local function RowFor(id)
	for _, row in ipairs(rows) do
		if row:IsShown() and row.id == id then return row end
	end
end

local function PlaceEditor()
	local row = editing and RowFor(editing)
	if not row then
		-- Deleted while being edited.
		editing = nil
		editor:ClearFocus()
		editor:Hide()
		for _, r in ipairs(rows) do r.text:Show() end
		return
	end
	for _, r in ipairs(rows) do r.text:SetShown(r ~= row) end
	editor:ClearAllPoints()
	editor:SetPoint("TOPLEFT", row, "TOPLEFT", 36, -3)
	editor:SetPoint("RIGHT", row, "RIGHT", -46, 0)
	editor:Show()
end

local function StopEditing(save)
	if not editing then return end
	local id, text = editing, editor:GetText()
	editing = nil
	editor:ClearFocus()
	editor:Hide()
	for _, r in ipairs(rows) do r.text:Show() end
	if save then Todo.Edit(id, text) end
end

local function StartEditing(id)
	StopEditing(true)
	local t = Todo.Get(id)
	if not t then return end
	editing = id
	editor:SetText(t.text)
	PlaceEditor()
	editor:SetFocus()
	editor:SetCursorPosition(#t.text)
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------
local function Hover(row)
	local over = row:IsMouseOver() and not dragging
	local t = row.id and Todo.Get(row.id)
	local tracked = t and t.tracked
	row.hl:SetShown(over)
	row.delete:SetShown(over)
	row.track:SetShown(over or tracked)
	row.track.icon:SetDesaturated(not tracked)
	row.track.icon:SetAlpha(tracked and 1 or 0.5)
end

local function Menu(row)
	local t = Todo.Get(row.id)
	if not (t and MenuUtil and MenuUtil.CreateContextMenu) then return end
	local id = t.id
	MenuUtil.CreateContextMenu(row, function(_, root)
		root:CreateButton("Edit", function() StartEditing(id) end)
		root:CreateButton(t.tracked and "Untrack" or "Track", function() Todo.SetTracked(id, not t.tracked) end)
		root:CreateButton("Move to Top", function() Todo.Move(id, 1) end)
		root:CreateButton("Move to Bottom", function() Todo.Move(id, #Todo.List()) end)
		root:CreateButton("Delete", function() Todo.Delete(id) end)
	end)
end

-- Where a dragged row would go: before the row the cursor is above the middle of.
local function DropIndex()
	local _, cy = GetCursorPosition()
	local offset = content:GetTop() - cy / content:GetEffectiveScale()
	local n = 0
	for i, row in ipairs(rows) do
		if not row:IsShown() then break end
		n = i
		if offset < (row.top + row.bottom) / 2 then return i end
	end
	return n + 1
end

local function DragUpdate()
	if not dragging then return end
	local index = DropIndex()
	local row = rows[index]
	local y = (row and row:IsShown()) and row.top or (rows[index - 1] and rows[index - 1].bottom or 0)
	insertLine:ClearAllPoints()
	insertLine:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -y + 1)
	insertLine:SetPoint("RIGHT", content, "RIGHT", -4, 0)
	insertLine:Show()
	-- Near the top or bottom: scroll.
	local _, cy = GetCursorPosition()
	cy = cy / scroll:GetEffectiveScale()
	local now, range = scroll:GetVerticalScroll(), scroll:GetVerticalScrollRange()
	if cy > scroll:GetTop() - 12 then
		scroll:SetVerticalScroll(math.max(0, now - 6))
	elseif cy < scroll:GetBottom() + 12 then
		scroll:SetVerticalScroll(math.min(range, now + 6))
	end
end

local function DragStop()
	local row = dragging
	if not row then return end
	dragging = nil
	row.droppedAt = GetTime() -- (not a click too)
	frame:SetScript("OnUpdate", nil)
	insertLine:Hide()
	row:SetAlpha(1)
	local index = DropIndex()
	local _, from = Todo.Get(row.id)
	if from and index > from then index = index - 1 end
	Todo.Move(row.id, index)
	for _, r in ipairs(rows) do Hover(r) end
end

local function CreateRow()
	local row = CreateFrame("Button", nil, content)
	row:SetHeight(ROW_MIN)
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	row:RegisterForDrag("LeftButton")
	ns.Hyperlinks(row)

	row.hl = row:CreateTexture(nil, "BACKGROUND")
	row.hl:SetAllPoints()
	row.hl:SetColorTexture(1, 1, 1, 0.06)

	local check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
	check:SetSize(26, 26)
	check:SetPoint("TOPLEFT", 4, 0)
	check:SetScript("OnClick", function(self) Todo.SetDone(row.id, self:GetChecked()) end)
	row.check = check

	local text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	text:SetPoint("TOPLEFT", 34, -7)
	text:SetJustifyH("LEFT")
	text:SetWordWrap(true)
	row.text = text

	local track = CreateFrame("Button", nil, row)
	track:SetSize(16, 16)
	track:SetPoint("TOPRIGHT", -26, -5)
	track.icon = track:CreateTexture(nil, "ARTWORK")
	track.icon:SetAllPoints()
	track.icon:SetTexture(TRACK_ICON)
	track:SetScript("OnClick", function()
		local t = Todo.Get(row.id)
		if t then Todo.SetTracked(t.id, not t.tracked) end
		local now = Todo.Get(row.id)
		if now then Tip(track, now.tracked and "Untrack" or "Track") end
	end)
	track:SetScript("OnEnter", function(self)
		local t = Todo.Get(row.id)
		Tip(self, (t and t.tracked) and "Untrack" or "Track")
		Hover(row)
	end)
	row.track = track

	local delete = CreateFrame("Button", nil, row)
	delete:SetSize(16, 16)
	delete:SetPoint("TOPRIGHT", -6, -5)
	delete:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
	delete:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Highlight", "ADD")
	delete:SetScript("OnClick", function() Todo.Delete(row.id) end)
	delete:SetScript("OnEnter", function(self) Tip(self, "Delete"); Hover(row) end)
	row.delete = delete

	local function Leave()
		GameTooltip:Hide()
		Hover(row)
	end
	track:SetScript("OnLeave", Leave)
	delete:SetScript("OnLeave", Leave)
	check:SetScript("OnEnter", function() Hover(row) end)
	check:SetScript("OnLeave", Leave)
	row:SetScript("OnEnter", function() Hover(row) end)
	row:SetScript("OnLeave", function() Hover(row) end)

	row:SetScript("OnClick", function(self, button)
		if dragging or self.droppedAt == GetTime() then return end
		if button == "RightButton" then
			Menu(self)
		else
			local id = self.id
			ns.UnlessLink(self, function() StartEditing(id) end)
		end
	end)
	row:SetScript("OnDragStart", function(self)
		if editing then StopEditing(true) end
		dragging = self
		self:SetAlpha(0.5)
		for _, r in ipairs(rows) do Hover(r) end
		frame:SetScript("OnUpdate", DragUpdate)
	end)
	row:SetScript("OnDragStop", DragStop)
	row:SetScript("OnHide", function(self) if dragging == self then DragStop() end end)
	return row
end

function Window.Refresh()
	if not (frame and frame:IsShown()) then return end
	local list = Todo.List()
	local width = scroll:GetWidth()
	content:SetWidth(width)
	local y = 0
	for i, t in ipairs(list) do
		local row = rows[i]
		if not row then
			row = CreateRow()
			rows[i] = row
		end
		row.id = t.id
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
		row:SetWidth(width)
		row.text:SetWidth(width - 34 - 48)
		row.text:SetText(t.text)
		row.text:SetAlpha(t.done and 0.45 or 1)
		row.check:SetChecked(t.done == true)
		local h = math.max(ROW_MIN, math.ceil(row.text:GetStringHeight()) + 14)
		row:SetHeight(h)
		row.top, row.bottom = y, y + h
		y = y + h
		row:Show()
		Hover(row)
	end
	for i = #list + 1, #rows do
		rows[i]:Hide()
		rows[i].id = nil
	end
	content:SetHeight(math.max(y, 1))
	emptyText:SetShown(#list == 0)
	clearButton:SetEnabled(Todo.AnyDone())
	if editing then PlaceEditor() end
end

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------
local function Build()
	local ok, f = pcall(CreateFrame, "Frame", "FireTodoFrame", UIParent, "BasicFrameTemplateWithInset")
	if not ok then
		f = CreateFrame("Frame", "FireTodoFrame", UIParent, "BackdropTemplate")
		f:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			tile = true, tileSize = 32, edgeSize = 32,
			insets = { left = 11, right = 12, top = 12, bottom = 11 },
		})
		local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
		close:SetPoint("TOPRIGHT", -4, -4)
	end
	frame = f
	f:SetSize(WIDTH, HEIGHT)
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		SavePoint()
	end)
	local p = ns.db.windowPoint or { "CENTER", "CENTER", 0, 40 }
	f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
	f:Hide()
	table.insert(UISpecialFrames, "FireTodoFrame") -- Escape closes it

	local title = type(f.TitleText) == "table" and f.TitleText or f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	if not f.TitleText then title:SetPoint("TOP", 0, -6) end
	title:SetText("Todo")

	-- A new todo.
	newBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
	newBox:SetPoint("TOPLEFT", 20, -32)
	newBox:SetPoint("TOPRIGHT", -16, -32)
	newBox:SetHeight(24)
	newBox:SetAutoFocus(false)
	newBox:SetMaxLetters(500)
	local hint = newBox:CreateFontString(nil, "ARTWORK", "GameFontDisable")
	hint:SetPoint("LEFT", 2, 0)
	hint:SetText("New todo")
	local function Hint() hint:SetShown(newBox:GetText() == "" and not newBox:HasFocus()) end
	newBox:SetScript("OnTextChanged", Hint)
	newBox:SetScript("OnEditFocusGained", Hint)
	newBox:SetScript("OnEditFocusLost", Hint)
	newBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	newBox:SetScript("OnEnterPressed", function(self)
		local added = Todo.Add(self:GetText())
		self:SetText("")
		if added then
			C_Timer.After(0, function() scroll:SetVerticalScroll(scroll:GetVerticalScrollRange()) end)
		else
			self:ClearFocus()
		end
	end)
	ns.LinkBox(newBox)

	scroll = CreateFrame("ScrollFrame", "FireTodoScroll", f, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 10, -62)
	scroll:SetPoint("BOTTOMRIGHT", -30, 38)
	content = CreateFrame("Frame", nil, scroll)
	content:SetSize(WIDTH - 40, 1)
	scroll:SetScrollChild(content)
	scroll:SetScript("OnSizeChanged", function() Window.Refresh() end)

	emptyText = f:CreateFontString(nil, "ARTWORK", "GameFontDisable")
	emptyText:SetPoint("CENTER", scroll, "CENTER")
	emptyText:SetText("Nothing to do.")

	insertLine = CreateFrame("Frame", nil, content)
	insertLine:SetHeight(2)
	insertLine:SetFrameLevel(content:GetFrameLevel() + 20)
	local line = insertLine:CreateTexture(nil, "OVERLAY")
	line:SetAllPoints()
	line:SetColorTexture(1, 0.82, 0, 1)
	insertLine:Hide()

	editor = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
	editor:SetHeight(20)
	editor:SetAutoFocus(false)
	editor:SetMaxLetters(500)
	editor:SetFrameLevel(content:GetFrameLevel() + 10)
	editor:SetScript("OnEnterPressed", function() StopEditing(true) end)
	editor:SetScript("OnEscapePressed", function() StopEditing(false) end)
	editor:SetScript("OnEditFocusLost", function() StopEditing(true) end)
	editor:Hide()
	ns.LinkBox(editor)

	clearButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	clearButton:SetSize(120, 22)
	clearButton:SetPoint("BOTTOMRIGHT", -10, 10)
	clearButton:SetText("Clear Completed")
	clearButton:SetScript("OnClick", function() Todo.ClearDone() end)

	local footer = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	footer:SetPoint("BOTTOMLEFT", 14, 16)
	footer:SetText("Drag to reorder. Shift-click items to link.")

	f:SetScript("OnShow", function() Window.Refresh() end)
	f:SetScript("OnHide", function()
		StopEditing(true)
		newBox:ClearFocus()
		if dragging then DragStop() end
	end)
end

function Window.Show()
	if not frame then Build() end
	frame:Show()
	Window.Refresh()
end

function Window.Toggle()
	if frame and frame:IsShown() then
		frame:Hide()
	else
		Window.Show()
	end
end

-- Show the list at this todo.
function Window.ShowTodo(id)
	Window.Show()
	local row = RowFor(id)
	if not row then return end
	local view = scroll:GetHeight()
	local now = scroll:GetVerticalScroll()
	if row.top < now or row.bottom > now + view then
		scroll:SetVerticalScroll(math.max(0, math.min(scroll:GetVerticalScrollRange(), row.top - 8)))
	end
end

ns.OnChange(Window.Refresh)
