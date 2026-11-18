-- FireTodo: a todo list. Each todo has a checkbox; tracked ones also show on
-- screen (Tracker.lua), like the quest tracker. The list: Window.lua (/todo).
--
-- FireTodoDB (account-wide): todos = { { id, text, done, tracked } } in
-- order, nextID, windowPoint, trackerPoint, trackerCollapsed.
local ADDON, ns = ...

local Todo = {}
ns.Todo = Todo

function ns.Print(msg)
	print("|cffff8030FireTodo|r: " .. msg)
end

-- WoW hides Lua errors unless scriptErrors is on: each distinct one printed once.
local reported = {}
function ns.SafeCall(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok and not reported[tostring(err)] then
		reported[tostring(err)] = true
		ns.Print("|cffff4040error:|r " .. tostring(err))
	end
	return ok, err
end

-- Something changed: the list and the tracker redraw.
local listeners = {}
function ns.OnChange(fn) listeners[#listeners + 1] = fn end
local function Changed()
	for _, fn in ipairs(listeners) do ns.SafeCall(fn) end
end
ns.Changed = Changed

---------------------------------------------------------------------------
-- The todos
---------------------------------------------------------------------------
local function Clean(text)
	text = type(text) == "string" and text:gsub("[\r\n]+", " ") or ""
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

function Todo.List() return ns.db.todos end

function Todo.Get(id)
	for i, t in ipairs(ns.db.todos) do
		if t.id == id then return t, i end
	end
end

-- A new todo goes at the bottom, tracked.
function Todo.Add(text)
	text = Clean(text)
	if text == "" then return nil end
	local db = ns.db
	local t = { id = db.nextID, text = text, tracked = true }
	db.nextID = db.nextID + 1
	db.todos[#db.todos + 1] = t
	Changed()
	return t
end

function Todo.Edit(id, text)
	local t = Todo.Get(id)
	text = Clean(text)
	if not t or text == "" or text == t.text then return end
	t.text = text
	Changed()
end

function Todo.Delete(id)
	local _, i = Todo.Get(id)
	if not i then return end
	table.remove(ns.db.todos, i)
	Changed()
end

function Todo.SetDone(id, done)
	local t = Todo.Get(id)
	if not t then return end
	t.done = done and true or nil
	Changed()
end

function Todo.SetTracked(id, on)
	local t = Todo.Get(id)
	if not t then return end
	t.tracked = on and true or nil
	Changed()
end

-- To position index in the list (1 = top).
function Todo.Move(id, index)
	local list = ns.db.todos
	local t, i = Todo.Get(id)
	if not t then return end
	table.remove(list, i)
	index = math.max(1, math.min(index, #list + 1))
	table.insert(list, index, t)
	if index ~= i then Changed() end
end

function Todo.ClearDone()
	local list = ns.db.todos
	for i = #list, 1, -1 do
		if list[i].done then table.remove(list, i) end
	end
	Changed()
end

function Todo.AnyDone()
	for _, t in ipairs(ns.db.todos) do
		if t.done then return true end
	end
	return false
end

---------------------------------------------------------------------------
-- Links: shift-clicking an item (a spell, a quest...) while typing a todo
-- puts its link in. Forever sends shift-clicks through ChatFrameUtil.InsertLink
-- (older clients ChatEdit_InsertLink); items also pass HandleModifiedItemClick.
-- One click may reach several of them, so it's taken once.
---------------------------------------------------------------------------
local boxes = {}
function ns.LinkBox(box) boxes[#boxes + 1] = box end

local lastLink, lastTime
local function InsertLink(link)
	if type(link) ~= "string" then return end
	for _, box in ipairs(boxes) do
		if box:IsVisible() and box:HasFocus() then
			local now = GetTime()
			if link == lastLink and now == lastTime then return end
			lastLink, lastTime = link, now
			box:Insert(link)
			return
		end
	end
end

-- Links in a todo's text: their tooltip on hover, clicked like in chat.
-- frame.linkAt: when one was last clicked (so the click isn't also the frame's).
function ns.Hyperlinks(frame)
	frame:SetHyperlinksEnabled(true)
	frame:SetScript("OnHyperlinkEnter", function(self, link)
		GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
		if pcall(GameTooltip.SetHyperlink, GameTooltip, link) then GameTooltip:Show() else GameTooltip:Hide() end
	end)
	frame:SetScript("OnHyperlinkLeave", function() GameTooltip:Hide() end)
	frame:SetScript("OnHyperlinkClick", function(self, link, text, button)
		self.linkAt = GetTime()
		if SetItemRef then pcall(SetItemRef, link, text, button, self) end
	end)
end

-- A click on the frame that wasn't on one of its links (they come in either order).
function ns.UnlessLink(frame, fn)
	local at = GetTime()
	C_Timer.After(0, function()
		if frame.linkAt ~= at then ns.SafeCall(fn) end
	end)
end

---------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(_, event, name)
	if event == "ADDON_LOADED" and name == ADDON then
		FireTodoDB = FireTodoDB or {}
		local db = FireTodoDB
		db.todos = db.todos or {}
		local maxID = 0
		for _, t in ipairs(db.todos) do maxID = math.max(maxID, t.id or 0) end
		db.nextID = math.max(db.nextID or 1, maxID + 1)
		ns.db = db
	elseif event == "PLAYER_LOGIN" then
		if ChatFrameUtil and type(ChatFrameUtil.InsertLink) == "function" then
			hooksecurefunc(ChatFrameUtil, "InsertLink", function(link) ns.SafeCall(InsertLink, link) end)
		end
		if type(ChatEdit_InsertLink) == "function" then
			hooksecurefunc("ChatEdit_InsertLink", function(link) ns.SafeCall(InsertLink, link) end)
		end
		if type(HandleModifiedItemClick) == "function" then
			hooksecurefunc("HandleModifiedItemClick", function(link)
				if IsModifiedClick("CHATLINK") then ns.SafeCall(InsertLink, link) end
			end)
		end
		Changed()
	end
end)

---------------------------------------------------------------------------
-- /todo: show or hide the list; /todo <text>: add a todo.
---------------------------------------------------------------------------
SLASH_FIRETODO1 = "/todo"
SLASH_FIRETODO2 = "/firetodo"
SlashCmdList.FIRETODO = function(msg)
	if Clean(msg) ~= "" then
		Todo.Add(msg)
	else
		ns.Window.Toggle()
	end
end

function FireTodo_Toggle() ns.Window.Toggle() end
BINDING_HEADER_FIRETODO = "FireTodo"
BINDING_NAME_FIRETODO_TOGGLE = "Show/hide the todo list"
