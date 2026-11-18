-- The tracker in Edit Mode, like the game's own elements (FireEditMode.lua):
-- turned on or off there, moved, sized from its corner, and its text sized.
local _, ns = ...
local Tracker = ns.Tracker

local function Copy(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do out[k] = Copy(v) end
	return out
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function()
	local db, T = ns.db, Tracker
	ns.editMode = FireEditMode.Register({
		name = "FireTodo",
		label = "Todo Tracker",
		frame = T.Frame(),
		GetState = function()
			return { point = Copy(db.trackerPoint), width = db.trackerWidth, height = db.trackerHeight,
				textSize = db.trackerTextSize }
		end,
		SetState = function(s)
			db.trackerPoint, db.trackerWidth, db.trackerHeight = s.point, s.width, s.height
			db.trackerTextSize = s.textSize
			T.Place()
			T.Refresh()
		end,
		Moved = function() T.Pin() end,
		Toggle = {
			get = T.Enabled,
			set = function(on)
				db.trackerShown = on
				T.Refresh()
			end,
		},
		resize = { T.MIN_W, T.MIN_H, T.MAX_W, T.MAX_H },
		settings = {
			{
				label = "Text Size", min = T.MIN_TEXT, max = T.MAX_TEXT, step = 1,
				get = T.TextSize,
				set = function(v)
					db.trackerTextSize = v
					T.Refresh()
				end,
			},
		},
		Sizing = function(w, h)
			db.trackerWidth, db.trackerHeight = w, h
			T.Refresh() -- its todos wrap to the new width as it goes
		end,
		Default = function()
			db.trackerPoint = nil
			T.Place()
		end,
		IsDefault = function() return db.trackerPoint == nil end,
		Editing = T.SetEditing,
	})
end)
