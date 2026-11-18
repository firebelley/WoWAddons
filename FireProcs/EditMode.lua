-- The announcements in Edit Mode, like the game's own elements
-- (FireEditMode.lua): turned on or off there, moved, and sized in their settings.
local _, ns = ...

local function Copy(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do out[k] = Copy(v) end
	return out
end

ns.On("PLAYER_LOGIN", function()
	local db, Display = ns.db, ns.Display
	ns.editMode = FireEditMode.Register({
		name = "FireProcs",
		label = "Proc Announcements",
		frame = Display.frame,
		GetState = function() return { position = Copy(db.position), scale = db.scale } end,
		SetState = function(s)
			db.position, db.scale = s.position, s.scale
			Display.ApplyScale(false)
			Display.ApplyPosition()
		end,
		Moved = function(frame)
			local point, _, relPoint, x, y = frame:GetPoint()
			db.position = { point, relPoint, x, y }
		end,
		Toggle = {
			get = function() return not db.hidden end,
			set = function(on)
				db.hidden = not on or nil
				Display.ApplyShown()
			end,
		},
		settings = {
			{
				label = "Size", min = 50, max = 200, step = 5,
				get = function() return math.floor((db.scale or 1) * 100 + 0.5) end,
				set = function(v)
					db.scale = v / 100
					if db.position then
						Display.ApplyScale(true) -- staying centred where it is
					else
						Display.ApplyScale(false) -- still in its default place
						Display.ApplyPosition()
					end
				end,
				format = function(v) return ("%d%%"):format(v) end,
			},
		},
		Default = Display.ResetPosition,
		IsDefault = function() return db.position == nil end,
		Editing = Display.Preview,
	})
end)
