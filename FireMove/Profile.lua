-- TEMPORARY: finds what makes FireMove freeze the game. Its entry points are
-- wrapped with ns.Timed; on a frame where FireMove spent over SLOW ms, chat
-- shows what took it (time includes what each called, so the chain shows).
-- Remove this file (and the ns.Timed wraps) once found.
local _, ns = ...

local SLOW = 100 -- ms

local spent, calls = {}, {}
local depth, total = 0, 0

local function Pack(...) return { n = select("#", ...), ... } end

-- name: a label; withEvent: add the event (the handler's second argument).
function ns.Timed(name, fn, withEvent)
	return function(...)
		local label = name
		if withEvent then label = name .. " " .. tostring((select(2, ...))) end
		depth = depth + 1
		local start = debugprofilestop()
		local r = Pack(fn(...))
		local t = debugprofilestop() - start
		depth = depth - 1
		spent[label] = (spent[label] or 0) + t
		calls[label] = (calls[label] or 0) + 1
		if depth == 0 then total = total + t end
		return unpack(r, 1, r.n)
	end
end

local frame = CreateFrame("Frame")
frame:SetScript("OnUpdate", function()
	if total > SLOW then
		local list = {}
		for label, t in pairs(spent) do list[#list + 1] = label end
		table.sort(list, function(a, b) return spent[a] > spent[b] end)
		print(("|cffff8030FireMove|r slow frame: %d ms"):format(total))
		for i = 1, math.min(10, #list) do
			local label = list[i]
			print(("  %s: %d ms, %d calls"):format(label, spent[label], calls[label]))
		end
	end
	wipe(spent)
	wipe(calls)
	depth, total = 0, 0
end)
