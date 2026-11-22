-- The list in Edit Mode, like the game's own elements (FireEditMode.lua):
-- turned on or off there, moved, and its text sized.
local _, ns = ...
local Display = ns.Display

local EditMode = {}
ns.EditMode = EditMode

local function Copy(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do out[k] = Copy(v) end
	return out
end

function EditMode.Init()
	local db = ns.db
	ns.editMode = FireEditMode.Register({
		name = "FireCooldowns",
		label = "Crafting Cooldowns",
		frame = Display.Frame(),
		GetState = function() return { point = Copy(db.point), textSize = db.textSize } end,
		SetState = function(s)
			db.point, db.textSize = s.point, s.textSize
			Display.Place()
			Display.Refresh()
		end,
		Moved = function() Display.Pin() end,
		Toggle = {
			get = function() return db.shown end,
			set = function(on)
				db.shown = on
				Display.Refresh()
			end,
		},
		settings = {
			{
				label = "Text Size", min = Display.MIN_TEXT, max = Display.MAX_TEXT, step = 1,
				get = Display.TextSize,
				set = function(v)
					db.textSize = v
					Display.Refresh()
				end,
			},
		},
		Default = Display.ResetPosition,
		IsDefault = function() return db.point == nil end,
		Editing = Display.SetEditing,
	})
end
