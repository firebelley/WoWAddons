-- The To Craft panel, docked beside Blizzard's profession window - left of it
-- when there's room, else right of its profession tabs (Recipes tab, your own
-- professions only):
--   top:       count + Add puts the selected recipe on the list
--   Recipes:   the list - type a count, click to select, right-click or X to
--              remove; crafting one takes one off
--   Materials: everything the list needs, have/need, with crafted materials
--              you're short of broken down into theirs
--   Craft:     the next thing - crafted materials first (deepest first), then
--              the list top to bottom; selects it, then presses Blizzard's
--              Create / Create All (see RefreshCraft)
-- Costs show when FireAuction is installed. A To Craft tab under the window's
-- profession tabs shows and hides the panel.
local _, ns = ...

local Panel = {}
ns.Panel = Panel
local Data = ns.Data

local WIDTH = 300
local ROW = 20
local INDENT = 12
local GREY = "|cff999999"
local BANK_COLOR = "ff8cb3ff" -- the same blue as FireBags' bank counts

local page, form, panel, scroll, content, addBox, addButton, selName, emptyText, craftButton
local headers, recipeRows, materialRows = {}, {}, {}
local profID
local Position -- below
local tab -- the To Craft tab under the window's profession tabs

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------
local requested = {} -- names asked for once; GET_ITEM_INFO_RECEIVED redraws
local function ItemName(id)
	local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
	if not name and not requested[id] and C_Item and C_Item.RequestLoadItemDataByID then
		requested[id] = true
		C_Item.RequestLoadItemDataByID(id)
	end
	return name or ("item " .. id)
end

local function ItemIcon(id)
	return (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)) or 134400 -- question mark
end

local function CostText(copper, complete)
	if not copper then return "" end
	if copper == 0 and not complete then return GREY .. "?|r" end
	local s = Data.Money(copper)
	if not complete then s = s .. " " .. GREY .. "+?|r" end
	return s
end

local function SelectedRecipe()
	if not (form and form.GetRecipeInfo) then return nil end
	local ok, info = pcall(form.GetRecipeInfo, form)
	return ok and info or nil
end

local function RefreshAdd()
	local info = SelectedRecipe()
	local ok = info and info.learned and info.recipeID and true or false
	addButton:SetEnabled(ok)
	selName:SetText(ok and info.name or "")
end

local function AddSelected()
	local info = SelectedRecipe()
	addBox:ClearFocus()
	if not (info and info.learned and profID) then return end
	Data.Add(profID, info.recipeID, tonumber(addBox:GetText()) or 1)
	addBox:SetText("1")
	Panel.Refresh()
end

local function NumberBox(parent, width)
	local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	box:SetSize(width, 18)
	box:SetAutoFocus(false)
	box:SetNumeric(true)
	box:SetMaxLetters(3)
	box:SetJustifyH("CENTER")
	box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	return box
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------
local function Header(i)
	if headers[i] then return headers[i] end
	local h = CreateFrame("Frame", nil, content)
	h:SetHeight(ROW)
	h.left = h:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	h.left:SetPoint("LEFT", 4, 0)
	h.right = h:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	h.right:SetPoint("RIGHT", -4, 0)
	headers[i] = h
	return h
end

local function RecipeTooltip(row)
	local e = row.entry
	local r = e and e.recipe
	if not r then return end
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	if r.out then GameTooltip:SetItemByID(r.out) else GameTooltip:SetText(r.name, 1, 1, 1) end
	if e.cost and e.n > 0 then
		GameTooltip:AddDoubleLine("Cost each", CostText(e.cost / e.n, e.complete), 1, 0.82, 0, 1, 1, 1)
	end
	GameTooltip:AddLine("Click to select. Right-click to remove.", 0.6, 0.6, 0.6)
	GameTooltip:Show()
end

local function CommitCount(box)
	local row = box:GetParent()
	local e = row.entry
	local n = tonumber(box:GetText())
	if e and n and n ~= e.n and profID then
		Data.SetCount(profID, e.id, n)
		Panel.Refresh()
	elseif e then
		box:SetText(e.n)
	end
end

local function RecipeRow(i)
	if recipeRows[i] then return recipeRows[i] end
	local row = CreateFrame("Button", nil, content)
	row:SetHeight(ROW)
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

	row.selected = row:CreateTexture(nil, "BACKGROUND")
	row.selected:SetAllPoints()
	row.selected:SetColorTexture(1, 0.82, 0, 0.12)

	row.count = NumberBox(row, 26)
	row.count:SetPoint("LEFT", 8, 0)
	row.count:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	row.count:SetScript("OnEditFocusLost", CommitCount)

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(16, 16)
	row.icon:SetPoint("LEFT", row.count, "RIGHT", 4, 0)

	row.remove = CreateFrame("Button", nil, row)
	row.remove:SetSize(16, 16)
	row.remove:SetPoint("RIGHT", -2, 0)
	row.remove:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
	row.remove:SetPushedTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Down")
	row.remove:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Highlight", "ADD")
	row.remove:SetScript("OnClick", function()
		if row.entry and profID then
			Data.SetCount(profID, row.entry.id, 0)
			Panel.Refresh()
		end
	end)

	row.cost = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.cost:SetPoint("RIGHT", row.remove, "LEFT", -4, 0)

	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
	row.name:SetPoint("RIGHT", row.cost, "LEFT", -4, 0)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)

	row:SetScript("OnClick", function(self, button)
		local e = self.entry
		if not e then return end
		if button == "RightButton" then
			Data.SetCount(profID, e.id, 0)
			Panel.Refresh()
		elseif C_TradeSkillUI.OpenRecipe then
			-- Blizzard's window selects it when the game answers.
			C_TradeSkillUI.OpenRecipe(e.id)
		end
	end)
	row:SetScript("OnEnter", RecipeTooltip)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)
	recipeRows[i] = row
	return row
end

local function MaterialTooltip(row)
	local m = row.material
	if not m then return end
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	GameTooltip:SetItemByID(m.id)
	local bags, bank = Data.Counts(m.id)
	GameTooltip:AddDoubleLine("Bags / bank", bags .. " / " .. bank, 1, 0.82, 0, 1, 1, 1)
	if m.crafts > 0 then GameTooltip:AddDoubleLine("Craft", m.crafts .. "x", 1, 0.82, 0, 1, 1, 1) end
	if m.short > 0 then GameTooltip:AddDoubleLine("Still need", m.short, 1, 0.82, 0, 1, 0.4, 0.4) end
	GameTooltip:Show()
end

local function MaterialRow(i)
	if materialRows[i] then return materialRows[i] end
	local row = CreateFrame("Button", nil, content)
	row:SetHeight(ROW - 2)
	row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(16, 16)

	row.count = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.count:SetPoint("RIGHT", -4, 0)

	row.note = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.note:SetPoint("RIGHT", row.count, "LEFT", -6, 0)

	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
	row.name:SetPoint("RIGHT", row.note, "LEFT", -4, 0)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)

	row:SetScript("OnClick", function(self)
		-- Shift-click links it in chat.
		local m = self.material
		if not (m and IsModifiedClick and IsModifiedClick("CHATLINK")) then return end
		local link = select(2, (C_Item and C_Item.GetItemInfo or GetItemInfo)(m.id))
		if link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
	end)
	row:SetScript("OnEnter", MaterialTooltip)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)
	materialRows[i] = row
	return row
end

---------------------------------------------------------------------------
-- Craft: the next thing on the plan you can make now.
---------------------------------------------------------------------------
local function Craftable(recipeID)
	local ok, n = pcall(C_TradeSkillUI.GetCraftableCount, recipeID)
	return ok and type(n) == "number" and n or 0
end

-- recipeID, count, name - or nil when nothing can be crafted right now.
local function NextCraft(result)
	-- Crafted materials, deepest first (their own materials come before them).
	local deepest = 0
	for _, m in ipairs(result.materials) do deepest = math.max(deepest, m.depth) end
	for depth = deepest, 0, -1 do
		for _, m in ipairs(result.materials) do
			local r = m.recipe and ns.db.recipes[m.recipe]
			if m.depth == depth and m.crafts > 0 and r and r.prof == profID then
				local n = math.min(m.crafts, Craftable(m.recipe))
				if n > 0 then return m.recipe, n, r.name end
			end
		end
	end
	for _, e in ipairs(result.recipes) do
		local n = e.recipe and math.min(e.n, Craftable(e.id)) or 0
		if n > 0 then return e.id, n, e.recipe.name end
	end
end

-- Busy: casting (a craft in progress) or in combat (cast info may be secret).
local function Casting()
	if InCombatLockdown and InCombatLockdown() then return true end
	return (UnitCastingInfo and UnitCastingInfo("player")) ~= nil or (UnitChannelInfo and UnitChannelInfo("player")) ~= nil
end

-- The recipe's row in Blizzard's recipe list, if it's on screen.
local function BlizzardRow(recipeID)
	local box = page.RecipeList and page.RecipeList.ScrollBox
	local frames = box and box.GetFrames and box:GetFrames()
	for _, frame in ipairs(frames or {}) do
		local node = frame:IsVisible() and frame.GetElementData and frame:GetElementData()
		local data = node and node.GetData and node:GetData()
		local info = data and data.recipeInfo
		if info then
			if info.recipeID == recipeID then return frame end
			local highest = Professions and Professions.GetHighestLearnedRecipe and Professions.GetHighestLearnedRecipe(info)
			if highest and highest.recipeID == recipeID then return frame end
		end
	end
end

-- Addons can't craft (CraftRecipe is Blizzard-only), so the button is a
-- secure "click" button that presses Blizzard's own Create / Create All for
-- the recipe selected in its window. Two steps:
--   next recipe not selected: "Select <name>" clicks its row in Blizzard's
--     list (instant); if the row isn't on screen, asks the game to open it
--     (OpenRecipe - slow, it waits for the list to reload)
--   selected: "Craft N <name>" presses Create All when you need all you can
--     make, else Create (the count in Blizzard's box)
-- A secure button can't change in combat, so this waits until combat ends.
local function RefreshCraft(result)
	if InCombatLockdown() then return end
	local b = craftButton
	local id, n, name = NextCraft(result)
	local selected = SelectedRecipe()
	selected = selected and selected.recipeID
	b.selectID = nil
	b:SetAttribute("type", nil)
	b:SetAttribute("clickbutton", nil)
	if not id then
		b:SetText("Craft")
		b:Disable()
		return
	end
	if id ~= selected then
		b.selectID = id
		b:SetText("Select " .. name)
		b:Enable()
		return
	end
	local target, perClick
	local all, one, box = page.CreateAllButton, page.CreateButton, page.CreateMultipleInputBox
	local craftable = Craftable(id)
	if all and all:IsShown() and n >= craftable then
		target, perClick = all, craftable
	else
		target = one
		local ok, v = pcall(box.GetValue, box)
		perClick = ok and type(v) == "number" and v > 0 and v or 1
	end
	if not target then return end
	b:SetAttribute("type", "click")
	b:SetAttribute("clickbutton", target)
	b:SetText(("Craft %d %s"):format(perClick, name))
	b:SetEnabled(target:IsEnabled() and not Casting())
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------
local function Place(frame, y)
	frame:ClearAllPoints()
	frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, y)
	frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, y)
	frame:Show()
end

local function Draw()
	profID = Data.CurrentProfession()
	if not profID then return end
	local icon = Data.ProfessionIcon(profID)
	if icon and panel.SetPortraitToAsset then pcall(panel.SetPortraitToAsset, panel, icon) end
	RefreshAdd()

	local use = { bags = ns.db.useBags, bank = ns.db.useBank }
	local result = Data.Compute(profID, use)
	local prices = Data.HasPrices()
	local selected = SelectedRecipe()
	selected = selected and selected.recipeID
	local y = 0

	local h1 = Header(1)
	h1.left:SetText("Recipes")
	h1.right:SetText(prices and #result.recipes > 0 and ("Total " .. CostText(result.total, result.totalComplete)) or "")
	Place(h1, y)
	y = y - ROW

	for i, e in ipairs(result.recipes) do
		local row = RecipeRow(i)
		row.entry = e
		local r = e.recipe
		row.icon:SetTexture((r and r.icon) or (r and r.out and ItemIcon(r.out)) or 134400)
		row.name:SetText(r and r.name or ("recipe " .. e.id))
		if not row.count:HasFocus() then row.count:SetText(e.n) end
		row.cost:SetText(prices and CostText(e.cost, e.complete) or "")
		row.selected:SetShown(e.id == selected)
		Place(row, y)
		y = y - ROW
	end
	for i = #result.recipes + 1, #recipeRows do
		recipeRows[i]:Hide()
		recipeRows[i].entry = nil
	end
	emptyText:SetShown(#result.recipes == 0)
	if #result.recipes == 0 then
		emptyText:ClearAllPoints()
		emptyText:SetPoint("TOPLEFT", content, "TOPLEFT", 8, y - 4)
		y = y - ROW
	end

	local h2 = Header(2)
	if #result.materials > 0 then
		y = y - 8
		h2.left:SetText("Materials")
		h2.right:SetText(prices and ("To buy " .. CostText(result.toBuy, result.toBuyComplete)) or "")
		Place(h2, y)
		y = y - ROW
	else
		h2:Hide()
	end

	for i, m in ipairs(result.materials) do
		local row = MaterialRow(i)
		row.material = m
		row.icon:ClearAllPoints()
		row.icon:SetPoint("LEFT", 6 + m.depth * INDENT, 0)
		row.icon:SetTexture(ItemIcon(m.id))
		row.name:SetText(ItemName(m.id))
		local color = m.have >= m.need and "ff40c040" or (m.short == 0 and "ffffd100" or "ffff5050")
		local text = ("|c%s%d/%d|r"):format(color, m.have, m.need)
		-- How many of those are in the bank (to fetch), in FireBags' bank blue.
		if use.bags and use.bank and m.bank > 0 then text = text .. (" |c%s(%d)|r"):format(BANK_COLOR, m.bank) end
		row.count:SetText(text)
		row.note:SetText(m.crafts > 0 and ("craft " .. m.crafts) or "")
		Place(row, y)
		y = y - (ROW - 2)
	end
	for i = #result.materials + 1, #materialRows do
		materialRows[i]:Hide()
		materialRows[i].material = nil
	end

	content:SetHeight(math.max(1, -y))
	-- Crafting goes by what you really have, whatever the toggles say.
	RefreshCraft((use.bags and use.bank) and result or Data.Compute(profID))
end

-- Batched: bags and item info can update many times a second.
local pending = false
function Panel.Refresh()
	if not (panel and page and page:IsVisible()) then return end
	local own = Data.ViewingOwnProfession() and Data.CurrentProfession() ~= nil
	local show = own and not ns.db.hidden
	if tab then
		tab:SetShown(own)
		tab:SetChecked(show)
	end
	-- Holding a secure button makes the panel protected: no moving or
	-- showing it in combat (PLAYER_REGEN_ENABLED catches up).
	if not InCombatLockdown() then
		if show then ns.SafeCall(Position) end
		panel:SetShown(show)
	end
	if not show or pending then return end
	pending = true
	C_Timer.After(0.1, function()
		pending = false
		if panel:IsVisible() then ns.SafeCall(Draw) end
	end)
end

---------------------------------------------------------------------------
-- Where it sits: left of the window when there's room on screen, else right
-- of it, past the profession tabs on its right edge.
---------------------------------------------------------------------------
local LEFT_GAP = 10 -- clear of the window's portrait, which sticks out a little
local placed

-- How far things (the profession tabs) stick out past the window's right edge.
local function RightOverhang()
	local pf = ProfessionsFrame
	local edge = pf:GetRight()
	if not edge then return 0 end
	local most = 0
	for _, child in ipairs({ pf:GetChildren() }) do
		if child:IsShown() then
			local l, r = child:GetLeft(), child:GetRight()
			if l and r and l >= edge - 12 and r - edge > most then most = r - edge end
		end
	end
	local r = tab and tab:IsShown() and tab:GetRight() -- ours isn't the window's child
	if r and r - edge > most then most = r - edge end
	return most
end

function Position()
	if InCombatLockdown() then return end
	local pf = ProfessionsFrame
	local left = pf:GetLeft()
	if not left then return end
	local where
	if left >= WIDTH + LEFT_GAP then
		where = "left"
	else
		where = "right" .. math.floor(RightOverhang() + 0.5)
	end
	if where == placed then return end
	placed = where
	panel:ClearAllPoints()
	if where == "left" then
		panel:SetPoint("TOPRIGHT", pf, "TOPLEFT", -LEFT_GAP, 0)
		panel:SetPoint("BOTTOMRIGHT", pf, "BOTTOMLEFT", -LEFT_GAP, 0)
	else
		local x = math.floor(RightOverhang() + 0.5) + 2
		panel:SetPoint("TOPLEFT", pf, "TOPRIGHT", x, 0)
		panel:SetPoint("BOTTOMLEFT", pf, "BOTTOMRIGHT", x, 0)
	end
end

local positionQueued = false
local function PositionSoon()
	if positionQueued then return end
	positionQueued = true
	C_Timer.After(0, function()
		positionQueued = false
		ns.SafeCall(Position)
	end)
end

---------------------------------------------------------------------------
-- Building it
---------------------------------------------------------------------------
-- A checkbox for ns.db[key] (true / false).
local function Toggle(parent, key, text, tip)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	cb:SetSize(22, 22)
	local label = cb.Text or cb.text
	if not label then
		label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
	end
	label:SetFontObject("GameFontHighlightSmall")
	label:SetText(text)
	cb.label = label
	cb:SetChecked(ns.db[key])
	cb:SetScript("OnClick", function(self)
		ns.db[key] = self:GetChecked() and true or false
		if PlaySound and SOUNDKIT then
			PlaySound(self:GetChecked() and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
		end
		Panel.Refresh()
	end)
	cb:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(tip, 1, 1, 1)
		GameTooltip:Show()
	end)
	cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return cb
end

local function Build()
	local ok, f = pcall(CreateFrame, "Frame", "FireCraftingPanel", page, "PortraitFrameTemplate")
	if not ok then
		f = CreateFrame("Frame", "FireCraftingPanel", page, BackdropTemplateMixin and "BackdropTemplate")
		if f.SetBackdrop then
			f:SetBackdrop({
				bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
				edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
				tile = true, tileSize = 16, edgeSize = 16,
				insets = { left = 4, right = 4, top = 4, bottom = 4 },
			})
			f:SetBackdropColor(0.06, 0.06, 0.06, 0.95)
		end
	end
	panel = f
	f:SetWidth(WIDTH)
	f:EnableMouse(true)
	if type(f.CloseButton) == "table" then f.CloseButton:Hide() end
	if f.SetTitle then
		pcall(f.SetTitle, f, "To Craft")
	else
		local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		title:SetPoint("TOP", 0, -8)
		title:SetText("To Craft")
	end
	if ok then
		local insetOK, inset = pcall(CreateFrame, "Frame", nil, f, "InsetFrameTemplate")
		if insetOK and inset then
			inset:SetPoint("TOPLEFT", 4, -62)
			inset:SetPoint("BOTTOMRIGHT", -6, 4)
			inset:SetFrameLevel(f:GetFrameLevel())
		end
	end

	addBox = NumberBox(f, 30)
	addBox:SetPoint("TOPLEFT", 72, -34)
	addBox:SetText("1")
	addBox:SetScript("OnEnterPressed", AddSelected)

	addButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	addButton:SetSize(56, 22)
	addButton:SetPoint("LEFT", addBox, "RIGHT", 6, 0)
	addButton:SetText("Add")
	addButton:SetScript("OnClick", AddSelected)

	selName = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	selName:SetPoint("LEFT", addButton, "RIGHT", 6, 0)
	selName:SetPoint("RIGHT", f, "RIGHT", -12, 0)
	selName:SetJustifyH("LEFT")
	selName:SetWordWrap(false)

	scroll = CreateFrame("ScrollFrame", "FireCraftingScroll", f, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 10, -68)
	scroll:SetPoint("BOTTOMRIGHT", -30, 64)

	-- Which of what you own counts as "have": untick both for a full
	-- shopping list.
	local useLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	useLabel:SetPoint("BOTTOMLEFT", 14, 42)
	useLabel:SetText("Use what's in:")
	local bags = Toggle(f, "useBags", "Bags", "Count what's in your bags.")
	bags:SetPoint("LEFT", useLabel, "RIGHT", 4, 0)
	local bank = Toggle(f, "useBank", "Bank", "Count what's in your bank.")
	bank:SetPoint("LEFT", bags.label, "RIGHT", 10, 0)

	craftButton = CreateFrame("Button", "FireCraftingCraftButton", f, "SecureActionButtonTemplate,UIPanelButtonTemplate")
	craftButton:SetHeight(22)
	craftButton:SetPoint("BOTTOMLEFT", 10, 10)
	craftButton:SetPoint("BOTTOMRIGHT", -12, 10)
	craftButton:RegisterForClicks("AnyUp")
	craftButton:SetAttribute("useOnKeyDown", false)
	-- Selecting: list rows get reused as it scrolls, so find the row right
	-- before the secure click presses it.
	craftButton:HookScript("PreClick", function(self)
		if not self.selectID or InCombatLockdown() then return end
		local row = BlizzardRow(self.selectID)
		if row then
			self:SetAttribute("type", "click")
			self:SetAttribute("clickbutton", row)
		else
			self:SetAttribute("type", nil)
			self:SetAttribute("clickbutton", nil)
			if C_TradeSkillUI.OpenRecipe then C_TradeSkillUI.OpenRecipe(self.selectID) end
		end
	end)
	craftButton:SetText("Craft")
	local label = craftButton:GetFontString()
	if label then
		label:ClearAllPoints()
		label:SetPoint("LEFT", 10, 0)
		label:SetPoint("RIGHT", -10, 0)
		label:SetWordWrap(false)
	end
	craftButton:Disable()
	content = CreateFrame("Frame", nil, scroll)
	content:SetSize(WIDTH - 42, 1)
	scroll:SetScrollChild(content)

	emptyText = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	emptyText:SetText("Select a recipe and click Add.")

	f:SetScript("OnShow", Panel.Refresh)
end

---------------------------------------------------------------------------
-- The tab: under the profession tabs on the window's right edge; shows and
-- hides the panel (remembered).
---------------------------------------------------------------------------
local TAB_ICON = "Interface\\Icons\\INV_Misc_Note_01"

local function PlaceTab()
	if InCombatLockdown() then return end
	local pf = ProfessionsFrame
	local below = pf.ProfessionsOverviewTab
	for _, t in ipairs(pf.rightProfessionTabs or {}) do
		if t:IsShown() then below = t end
	end
	tab:ClearAllPoints()
	if below then
		tab:SetPoint("TOPLEFT", below, "BOTTOMLEFT", 0, -2)
	else
		tab:SetPoint("TOPLEFT", pf, "TOPRIGHT", 0, -60)
	end
	placed = nil -- the panel may have to clear it
	PositionSoon()
end

local function BuildTab()
	-- Blizzard's large side tab, as the window's own tabs use; else the
	-- spellbook-style one. Clicks, icon and tooltip are ours either way.
	local ok, t = pcall(CreateFrame, "Button", "FireCraftingTab", page, "LargeSideTabButtonTemplate")
	if not ok or not t then
		t = CreateFrame("CheckButton", "FireCraftingTab", page, "RightSideTabTemplate")
	end
	tab = t
	if not t.Icon then
		t.Icon = t:CreateTexture(nil, "ARTWORK")
		t.Icon:SetPoint("CENTER")
		t.Icon:SetSize(30, 30)
	end
	t.Icon:SetTexture(TAB_ICON)
	-- Large side tabs show "checked" their own way; plain buttons have no checks.
	local setChecked = t.SetChecked
	function t:SetChecked(on)
		if setChecked then pcall(setChecked, self, on and true or false) end
	end
	t:SetScript("OnClick", function()
		if InCombatLockdown() then return end -- the panel can't show or hide in combat
		ns.db.hidden = not ns.db.hidden
		if PlaySound and SOUNDKIT then
			PlaySound(ns.db.hidden and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
		end
		Panel.Refresh()
	end)
	t:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("To Craft")
		GameTooltip:Show()
	end)
	t:SetScript("OnLeave", function() GameTooltip:Hide() end)
	PlaceTab()
	if ProfessionsFrame.RefreshRightTabs then hooksecurefunc(ProfessionsFrame, "RefreshRightTabs", PlaceTab) end
end

local function SetUp()
	if panel or not (ProfessionsFrame and ProfessionsFrame.CraftingPage) then return end
	page = ProfessionsFrame.CraftingPage
	form = page.SchematicForm
	Build()
	BuildTab()
	page:HookScript("OnShow", Panel.Refresh)
	-- Blizzard moves the window when other panels open beside it.
	hooksecurefunc(ProfessionsFrame, "SetPoint", PositionSoon)
	if form and form.Init then hooksecurefunc(form, "Init", function() Panel.Refresh() end) end
	Panel.Refresh()
end

ns.On("ADDON_LOADED", function(name)
	if name == "Blizzard_Professions" then SetUp() end
end)
ns.On("PLAYER_LOGIN", SetUp) -- in case it loaded first

for _, event in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED",
	"BAG_UPDATE_DELAYED", "GET_ITEM_INFO_RECEIVED", "BANKFRAME_CLOSED", "PLAYERBANKSLOTS_CHANGED", "MERCHANT_CLOSED",
	"UPDATE_TRADESKILL_CAST_STOPPED", "PLAYER_REGEN_ENABLED" }) do
	ns.On(event, Panel.Refresh)
end
