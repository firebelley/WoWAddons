-- Makes action buttons glow (Blizzard's proc glow where the client has it) for
-- abilities that just became usable.
local _, ns = ...
local API = ns.API

local Glow = {}
ns.Glow = Glow

local BAR_PREFIXES = {
	"ActionButton", "MultiBarBottomLeftButton", "MultiBarBottomRightButton",
	"MultiBarRightButton", "MultiBarLeftButton",
	"MultiBar5Button", "MultiBar6Button", "MultiBar7Button", "BonusActionButton",
}
-- Blizzard's proc-glow templates: modern client, then the Wrath-era one.
local TEMPLATES = { "ActionButtonSpellAlertTemplate", "ActionBarButtonSpellActivationAlert" }

local glowing = {} -- [spell name] = true
local shown = {}   -- [button] = true while its glow is up

local function Buttons()
	local list = {}
	for _, prefix in ipairs(BAR_PREFIXES) do
		for i = 1, 12 do
			local b = _G[prefix .. i]
			if b then list[#list + 1] = b end
		end
	end
	return list
end

local function ButtonSlot(b)
	if b.action and b.action ~= 0 then return b.action end
	if b.GetPagedID then return b:GetPagedID() end
	if ActionButton_GetPagedID then return ActionButton_GetPagedID(b) end
end

local function ButtonSpellName(b)
	local slot = ButtonSlot(b)
	if not slot or slot == 0 or not GetActionInfo then return nil end
	local kind, id = GetActionInfo(slot)
	if kind == "spell" and id then return (API.SpellInfo(id)) end
	if kind == "macro" and id and GetMacroSpell then
		local spell = GetMacroSpell(id)
		if spell then return (API.SpellInfo(spell)) end
	end
end

-- Our own copy of the glow on each button, so Blizzard's code never hides it.
local function CreateOwnGlow(b)
	local o = CreateFrame("Frame", nil, b)
	o:SetAllPoints()
	local tex = o:CreateTexture(nil, "OVERLAY")
	tex:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	tex:SetBlendMode("ADD")
	tex:SetVertexColor(1, 0.85, 0.2)
	tex:SetPoint("CENTER")
	local w = b:GetWidth()
	tex:SetSize(w * 1.8, w * 1.8)
	local ag = o:CreateAnimationGroup()
	ag:SetLooping("BOUNCE")
	local a = ag:CreateAnimation("Alpha")
	if a.SetFromAlpha then
		a:SetFromAlpha(1)
		a:SetToAlpha(0.3)
	end
	a:SetDuration(0.5)
	o.pulse = ag
	return o
end

local function GetGlow(b)
	if b.fireProcsGlow then return b.fireProcsGlow end
	local o
	for _, template in ipairs(TEMPLATES) do
		if API.TemplateExists(template) ~= false then
			local ok, f = pcall(CreateFrame, "Frame", nil, b, template)
			if ok and f and (f.ProcStartAnim or f.ProcLoop or f.animIn) then
				o = f
				break
			elseif ok and f then
				f:Hide()
			end
		end
	end
	if o then
		local w, h = b:GetSize()
		o:ClearAllPoints()
		o:SetSize(w * 1.4, h * 1.4)
		o:SetPoint("CENTER", b, "CENTER")
		if o.ProcStartAnim and o.ProcLoop then
			pcall(o.ProcStartAnim.HookScript, o.ProcStartAnim, "OnFinished", function()
				if o:IsShown() then o.ProcLoop:Play() end
			end)
		end
	else
		o = CreateOwnGlow(b)
	end
	o:SetFrameLevel(b:GetFrameLevel() + 5)
	o:Hide()
	b.fireProcsGlow = o
	return o
end

local function ShowGlow(b)
	if shown[b] then return end
	shown[b] = true
	local o = GetGlow(b)
	o:Show()
	if o.ProcStartAnim then o.ProcStartAnim:Play()
	elseif o.ProcLoop then o.ProcLoop:Play()
	elseif o.animIn then o.animIn:Play()
	elseif o.pulse then o.pulse:Play() end
end

local function HideGlow(b)
	if not shown[b] then return end
	shown[b] = nil
	local o = b.fireProcsGlow
	if not o then return end
	for _, key in ipairs({ "ProcStartAnim", "ProcLoop", "animIn", "animOut", "pulse" }) do
		if o[key] then o[key]:Stop() end
	end
	o:Hide()
end

function Glow.Refresh()
	if not next(glowing) and not next(shown) then return end
	for _, b in ipairs(Buttons()) do
		local name = next(glowing) and b:IsVisible() and ButtonSpellName(b)
		if name and glowing[name] then ShowGlow(b) else HideGlow(b) end
	end
end

function Glow.ClearAll()
	wipe(glowing)
	Glow.Refresh()
end

function Glow.Set(name, on)
	if (glowing[name] or false) == (on or false) then return end
	glowing[name] = on or nil
	Glow.Refresh()
end

for _, event in ipairs({
	"ACTIONBAR_SLOT_CHANGED", "ACTIONBAR_PAGE_CHANGED", "UPDATE_BONUS_ACTIONBAR",
	"UPDATE_SHAPESHIFT_FORM", "ACTIONBAR_SHOWGRID", "ACTIONBAR_HIDEGRID",
}) do
	ns.On(event, Glow.Refresh)
end
