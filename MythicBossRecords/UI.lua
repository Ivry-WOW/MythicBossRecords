local ADDON, ns = ...

-- =====================================================================
--  Mythic Boss Records - Encounter Journal style UI
--  1) dungeon grid  ->  2) the dungeon bosses (book page)
--  3) class list        ->  4) top DPS for each spec of the class
-- =====================================================================

local UI = {}
ns.UI = UI

local floor, format, unpack = math.floor, string.format, unpack

local EJTEX = "Interface\\EncounterJournal\\UI-EncounterJournalTextures"
local COORD = {
	dungeonUp   = { 0.00195313, 0.34179688, 0.42871094, 0.52246094 },
	dungeonDown = { 0.00195313, 0.34179688, 0.33300781, 0.42675781 },
	dungeonHL   = { 0.34570313, 0.68554688, 0.33300781, 0.42675781 },
	bossUp      = { 0.00195313, 0.63671875, 0.21386719, 0.26757813 },
	bossDown    = { 0.00195313, 0.63671875, 0.10253906, 0.15625000 },
	bossHL      = { 0.00195313, 0.63671875, 0.15820313, 0.21191406 },
}
local PAPER_TEXT = { 1, 1, 1 }          -- text in the dark panel
local PAPER_HEAD = { 1, 0.82, 0 }        -- titles (gold)
local PAPER_DIM  = { 0.62, 0.62, 0.62 }  -- dimmed text

local GRID_COLS, GRID_W, GRID_H, GRID_GAP_X, GRID_GAP_Y = 4, 174, 96, 13, 14
local ROW_H, NUM_ROWS = 20, 15
local RIGHT_W = 362

local function SetFont(fs, name, fallback)
	fs:SetFontObject(_G[name] and name or fallback)
end

local function SetEJButtonTextures(b, up, down, hl)
	b:SetNormalTexture(EJTEX);    b:GetNormalTexture():SetTexCoord(unpack(up))
	b:SetPushedTexture(EJTEX);    b:GetPushedTexture():SetTexCoord(unpack(down))
	b:SetHighlightTexture(EJTEX); b:GetHighlightTexture():SetTexCoord(unpack(hl))
end

-- class color (rows sit on a dark panel, so normal colors)
local function PaperClassColor(class)
	local r, g, b = ns.ClassColor(class)
	local k = 1
	return r * k, g * k, b * k
end

local function ClassIcon(class)
	if class == "DEATHKNIGHT" then return "Interface\\Icons\\ClassIcon_DeathKnight" end
	if class == "DEMONHUNTER" then return "Interface\\Icons\\ClassIcon_DemonHunter" end
	return "Interface\\Icons\\ClassIcon_" .. class:sub(1, 1) .. class:sub(2):lower()
end

local function ClassName(class)
	return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]) or class
end

local function SpecLabel(key)
	if type(key) == "number" then
		local si = ns.SpecInfo(key)
		if si then return si.name, si.icon end
		return "Spec " .. key, "Interface\\Icons\\INV_Misc_QuestionMark"
	end
	return "Unknown spec", "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function KeyText(e)
	if not e.level or e.level == 0 then return "M0" end
	return "+" .. e.level
end

local function AddEntryTooltip(e, bossName)
	return UI.AddEntryTooltip(e, bossName)
end
function UI.AddEntryTooltip(e, bossName)
	local si = ns.SpecInfo(e.spec)
	local r, g, b = ns.ClassColor(e.class)
	GameTooltip:AddLine(e.name, r, g, b)
	GameTooltip:AddLine((si and si.name or "?") .. " " .. ClassName(e.class), 1, 1, 1)
	GameTooltip:AddLine(" ")
	GameTooltip:AddDoubleLine("DPS", ns.FormatNumber(e.dps), 1, 0.82, 0, 1, 1, 1)
	GameTooltip:AddDoubleLine("Damage total", ns.FormatNumber(e.damage), 1, 0.82, 0, 1, 1, 1)
	GameTooltip:AddDoubleLine("Boss duration", ns.FormatTime(e.duration), 1, 0.82, 0, 1, 1, 1)
	GameTooltip:AddDoubleLine("Key", KeyText(e), 1, 0.82, 0, 1, 1, 1)
	local txt, rr, gg, bb = ns.ResultText(e)
	if e.result == nil and e.level and e.level > 0 then txt = "Not finished / in progress" end
	GameTooltip:AddDoubleLine("Result", txt, 1, 0.82, 0, rr, gg, bb)
	if e.runTime then
		local lim = e.timeLimit and (" / " .. ns.FormatTime(e.timeLimit)) or ""
		GameTooltip:AddDoubleLine("Run time", ns.FormatTime(e.runTime) .. lim, 1, 0.82, 0, 1, 1, 1)
	end
	if e.affixes and #e.affixes > 0 then
		local names = {}
		for i, a in ipairs(e.affixes) do names[i] = ns.AffixName(a) end
		GameTooltip:AddDoubleLine("Affixes", table.concat(names, ", "), 1, 0.82, 0, 1, 1, 1)
	end
	GameTooltip:AddDoubleLine("Week", ns.TFName(ns.RecordTF(e)), 1, 0.82, 0, 1, 1, 1)
	GameTooltip:AddDoubleLine("Date", ns.FormatDate(e.date, true), 1, 0.82, 0, 1, 1, 1)
	if bossName then GameTooltip:AddDoubleLine("Boss", bossName, 1, 0.82, 0, 1, 1, 1) end
	if e.src == "logs" then
		GameTooltip:AddDoubleLine("Source", "old combat logs", 1, 0.82, 0, 0.6, 0.8, 1)
	elseif e.src == "log" then
		GameTooltip:AddDoubleLine("Source", "a player's combat log", 1, 0.82, 0, 0.6, 0.8, 1)
	elseif e.src then
		GameTooltip:AddDoubleLine("Shared by", e.src, 1, 0.82, 0, 0.6, 0.8, 1)
	elseif e.mine then
		GameTooltip:AddDoubleLine("Recorded by", "you", 1, 0.82, 0, 0.6, 0.8, 1)
	end
end

-- ---------------------------------------------------------------------
-- Main window
-- ---------------------------------------------------------------------
function UI:Create()
	if self.frame then return end
	local s = ns.db.settings

	local f = CreateFrame("Frame", "MythicBossRecordsFrame", UIParent, "PortraitFrameTemplate")
	self.frame = f
	f:SetSize(800, 496)
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(frame)
		frame:StopMovingOrSizing()
		local point, _, relPoint, x, y = frame:GetPoint()
		s.pos = { point, relPoint, x, y }
	end)
	if s.pos then
		f:SetPoint(s.pos[1], UIParent, s.pos[2], s.pos[3], s.pos[4])
	else
		f:SetPoint("CENTER")
	end
	f:Hide()
	tinsert(UISpecialFrames, "MythicBossRecordsFrame")

	if f.portrait then SetPortraitToTexture(f.portrait, "Interface\\EncounterJournal\\UI-EJ-PortraitIcon") end
	if f.TitleText then f.TitleText:SetText("Mythic Boss Records") end

	-- navigation bar
	local home = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	home:SetSize(110, 22)
	home:SetPoint("TOPLEFT", 64, -30)
	home:SetText("Dungeons")
	home:SetScript("OnClick", function() UI:ShowGrid() end)
	self.homeBtn = home

	local back = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	back:SetSize(80, 22)
	back:SetPoint("LEFT", home, "RIGHT", 4, 0)
	back:SetText("< Back")
	back:SetScript("OnClick", function() UI:Back() end)
	self.backBtn = back

	local users = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	users:SetSize(90, 22)
	users:SetPoint("TOPRIGHT", -12, -30)
	users:SetText("Users")
	users:SetScript("OnClick", function() if ns.Users then ns.Users:Toggle() end end)
	self.usersBtn = users

	local settingsBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	settingsBtn:SetSize(90, 22)
	settingsBtn:SetPoint("RIGHT", users, "LEFT", -4, 0)
	settingsBtn:SetText("Settings")
	settingsBtn:SetScript("OnClick", function() if ns.Options then ns.Options:Open() end end)
	self.settingsBtn = settingsBtn

	local updateBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	updateBtn:SetSize(70, 18)
	updateBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 4)      -- bottom bar, right
	updateBtn:SetText("Update")
	updateBtn:SetScript("OnClick", function() StaticPopup_Show("MBR_UPDATE", UI.UpdateText()) end)
	updateBtn:SetScript("OnEnter", function(s)
		GameTooltip:SetOwner(s, "ANCHOR_BOTTOM")
		GameTooltip:AddLine("Update the addon", 1, 1, 1)
		if ns.newerVersion then
			GameTooltip:AddLine("V." .. ns.newerVersion .. " is out (you have V." .. ns.VERSION .. ")", 0.1, 1, 0.1)
		else
			GameTooltip:AddLine("You have V." .. ns.VERSION .. " - no newer version seen.", 0.8, 0.8, 0.8)
		end
		GameTooltip:Show()
	end)
	updateBtn:SetScript("OnLeave", GameTooltip_Hide)
	self.updateBtn = updateBtn

	local logBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	logBtn:SetSize(80, 18)
	logBtn:SetPoint("RIGHT", updateBtn, "LEFT", -4, 0)
	logBtn:SetText("Sync logs")
	logBtn:SetScript("OnClick", function() UI:SyncLogs() end)
	logBtn:SetScript("OnEnter", function(s)
		GameTooltip:SetOwner(s, "ANCHOR_BOTTOM")
		GameTooltip:AddLine("Share your combat log", 1, 1, 1)
		local n = #ns.OwnLogRecords()
		if n > 0 then
			GameTooltip:AddLine(n .. " records from your combat log - click to send them to everyone again", 0.1, 1, 0.1, true)
		else
			GameTooltip:AddLine("Your combat log has not been read yet - click to see how.", 1, 0.82, 0, true)
		end
		GameTooltip:Show()
	end)
	logBtn:SetScript("OnLeave", GameTooltip_Hide)
	self.logBtn = logBtn

	local contact = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	contact:SetPoint("RIGHT", logBtn, "LEFT", -10, 0)
	contact:SetText("Contact IGN: |cffffffffIvryr|r")
	contact:SetTextColor(0.85, 0.7, 0.35)
	self.contact = contact

	local crumb = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	crumb:SetPoint("LEFT", back, "RIGHT", 12, 0)
	crumb:SetPoint("RIGHT", settingsBtn, "LEFT", -8, 0)
	crumb:SetJustifyH("LEFT")
	self.crumb = crumb

	local inset = CreateFrame("Frame", "MythicBossRecordsFrameInset", f, "InsetFrameTemplate")
	inset:SetPoint("TOPLEFT", 4, -60)
	inset:SetPoint("BOTTOMRIGHT", -6, 26)
	self.inset = inset

	local footer = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	footer:SetPoint("BOTTOMLEFT", 14, 8)
	self.footer = footer
	local help = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	help:SetPoint("BOTTOMRIGHT", -14, 8)
	help:SetText("")
	self.help = help

	local mark = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	mark:SetPoint("BOTTOM", 0, 13)
	mark:SetText("Made by Ivry")
	mark:SetTextColor(0.85, 0.7, 0.35, 0.8)
	self.watermark = mark
	local ver = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	ver:SetPoint("TOP", mark, "BOTTOM", 0, -1)
	ver:SetText("V." .. ns.VERSION)
	ver:SetTextColor(0.85, 0.7, 0.35, 0.8)
	self.versionText = ver

	self:CreateGrid()
	self:CreateDungeonPage()
	self:CreatePlayerPage()
	self:CreateSearch()
end

-- ---------------------------------------------------------------------
-- 1) Dungeon grid
-- ---------------------------------------------------------------------
local function CreateInstanceButton(parent)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(GRID_W, GRID_H)
	b.bgImage = b:CreateTexture(nil, "BACKGROUND")
	b.bgImage:SetAllPoints()
	SetEJButtonTextures(b, COORD.dungeonUp, COORD.dungeonDown, COORD.dungeonHL)

	b.name = b:CreateFontString(nil, "OVERLAY")
	SetFont(b.name, "QuestTitleFontBlackShadow", "GameFontNormalLarge")
	b.name:SetWidth(150)
	b.name:SetPoint("TOP", 0, -15)

	b.info = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	b.info:SetPoint("BOTTOMLEFT", 9, 8)
	b.info:SetJustifyH("LEFT")

	b:SetScript("OnClick", function(self) UI:ShowDungeon(self.index) end)
	b:SetScript("OnEnter", function(self)
		local d = UI.dungeons[self.index]
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		local tf = ns.TopTF()
		GameTooltip:AddDoubleLine(d.name, ns.TFName(tf) .. " week", 1, 0.82, 0, 0.7, 0.7, 0.7)
		for _, boss in ipairs(d.bosses) do
			local best = ns.BossBest(boss[1], tf)
			if best then
				local r, g, bb = ns.ClassColor(best.class)
				GameTooltip:AddDoubleLine(boss[2], ns.FormatNumber(best.dps) .. "  " .. best.name, 1, 1, 1, r, g, bb)
			else
				GameTooltip:AddDoubleLine(boss[2], "-", 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
			end
		end
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", GameTooltip_Hide)
	return b
end

function UI:CreateGrid()
	local v = CreateFrame("Frame", nil, self.inset)
	v:SetAllPoints()
	self.gridView = v

	local bg = v:CreateTexture(nil, "BACKGROUND")
	bg:SetPoint("TOPLEFT", 3, -3)
	bg:SetPoint("BOTTOMRIGHT", -3, 3)
	bg:SetTexture("Interface\\EncounterJournal\\UI-EJ-Legion")

	local sf = CreateFrame("ScrollFrame", "MythicBossRecordsGridScroll", v, "UIPanelScrollFrameTemplate")
	sf:SetPoint("TOPLEFT", 4, -4)
	sf:SetPoint("BOTTOMRIGHT", -26, 4)
	local child = CreateFrame("Frame", nil, sf)
	child:SetSize(GRID_COLS * (GRID_W + GRID_GAP_X) + 10, 10)
	sf:SetScrollChild(child)
	self.gridChild = child
	self.gridButtons = {}
end

function UI:RefreshGrid()
	local child = self.gridChild
	for i, d in ipairs(self.dungeons) do
		local b = self.gridButtons[i]
		if not b then
			b = CreateInstanceButton(child)
			self.gridButtons[i] = b
			local col, row = (i - 1) % GRID_COLS, floor((i - 1) / GRID_COLS)
			b:SetPoint("TOPLEFT", 14 + col * (GRID_W + GRID_GAP_X), -10 - row * (GRID_H + GRID_GAP_Y))
		end
		b.index = i
		if d.button then
			b.bgImage:SetTexture(ns.DungeonButtonTexture(d))
			b.bgImage:SetTexCoord(0, 0.68359375, 0, 0.7421875)
		else
			b.bgImage:SetColorTexture(0.12, 0.1, 0.08, 1)
		end
		b.name:SetText(d.name)
		local withRec = 0
		for _, boss in ipairs(d.bosses) do
			if ns.db.records[boss[1]] then withRec = withRec + 1 end
		end
		if withRec > 0 then
			b.info:SetText(format("|cff00ff00%d|r/%d bosses with records", withRec, #d.bosses))
		else
			b.info:SetText("|cff9d9d9dno records yet|r")
		end
		b:Show()
	end
	for i = #self.dungeons + 1, #self.gridButtons do self.gridButtons[i]:Hide() end
	local rows = floor((#self.dungeons + GRID_COLS - 1) / GRID_COLS)
	child:SetHeight(rows * (GRID_H + GRID_GAP_Y) + 16)
end

-- ---------------------------------------------------------------------
-- 2) Dungeon page (book: bosses on the left, classes / top on the right)
-- ---------------------------------------------------------------------
local function CreateBossButton(parent)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(325, 55)
	SetEJButtonTextures(b, COORD.bossUp, COORD.bossDown, COORD.bossHL)

	local holder = CreateFrame("Frame", nil, b)
	holder:SetSize(1, 1)
	holder:SetPoint("TOPLEFT", -4, 13)
	holder:SetFrameLevel(b:GetFrameLevel() + 2)
	b.creature = holder:CreateTexture(nil, "OVERLAY")
	b.creature:SetSize(128, 64)
	b.creature:SetPoint("TOPLEFT")

	b.text = b:CreateFontString(nil, "OVERLAY")
	SetFont(b.text, "GameFontNormalMed3", "GameFontNormal")
	b.text:SetTextColor(0.827, 0.659, 0.463)
	b.text:SetJustifyH("LEFT")
	b.text:SetWidth(205)
	b.text:SetPoint("LEFT", 105, 7)

	b.sub = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	b.sub:SetTextColor(0.78, 0.72, 0.6)
	b.sub:SetJustifyH("LEFT")
	b.sub:SetWidth(210)
	b.sub:SetPoint("LEFT", 105, -11)

	b:SetScript("OnClick", function(self) UI:SelectBoss(self.encID) end)
	return b
end

local function CreateClassRow(parent)
	local r = CreateFrame("Button", nil, parent)
	r:SetSize(RIGHT_W, 27)
	local hl = r:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.08)
	local line = r:CreateTexture(nil, "BACKGROUND")
	line:SetHeight(1)
	line:SetPoint("BOTTOMLEFT", 2, 0)
	line:SetPoint("BOTTOMRIGHT", -2, 0)
	line:SetColorTexture(1, 1, 1, 0.07)

	r.icon = r:CreateTexture(nil, "ARTWORK")
	r.icon:SetSize(22, 22)
	r.icon:SetPoint("LEFT", 4, 0)
	r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	r.name = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	r.name:SetPoint("LEFT", r.icon, "RIGHT", 8, 0)

	r.count = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r.count:SetPoint("RIGHT", -6, 0)
	r.count:SetWidth(50)
	r.count:SetJustifyH("RIGHT")
	r.count:SetTextColor(unpack(PAPER_DIM))

	r.best = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	r.best:SetPoint("RIGHT", r.count, "LEFT", -6, 0)
	r.best:SetJustifyH("RIGHT")
	r.best:SetTextColor(unpack(PAPER_TEXT))

	r:SetScript("OnClick", function(self) UI:SelectClass(self.class) end)
	r:SetScript("OnEnter", function(self)
		if not self.bestEntry then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Best " .. ClassName(self.class), 1, 0.82, 0)
		AddEntryTooltip(self.bestEntry, UI.bossName)
		GameTooltip:Show()
	end)
	r:SetScript("OnLeave", GameTooltip_Hide)
	return r
end

-- top table: Tyrannical on the left half, Fortified on the right half
-- columns inside one half (x, width, alignment)
local HALF_W, HALF_GAP = 156, 6
local COLS = {
	rank   = { 0, 12, "RIGHT" },
	name   = { 15, 62, "LEFT" },
	dps    = { 78, 38, "RIGHT" },
	key    = { 118, 22, "CENTER" },
	result = { 140, 16, "CENTER" },
}

local function ShortResult(e)
	if e.level == 0 then return "M0", 0.5, 0.5, 0.5 end
	if e.result == nil then return "?", 0.5, 0.5, 0.5 end
	if e.result == 0 then return "D", 1, 0.25, 0.2 end
	return "+" .. e.result, 0.1, 1, 0.1
end

local function CreateHalf(parent, x)
	local h = CreateFrame("Button", nil, parent)
	h:SetSize(HALF_W, ROW_H)
	h:SetPoint("LEFT", x, 0)
	local hl = h:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.08)
	h.cells = {}
	for k, c in pairs(COLS) do
		local fs = h:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetPoint("LEFT", c[1], 0)
		fs:SetWidth(c[2])
		fs:SetJustifyH(c[3])
		fs:SetTextColor(unpack(PAPER_TEXT))
		fs:SetWordWrap(false)
		h.cells[k] = fs
	end
	h:SetScript("OnEnter", function(self)
		if not self.e then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		AddEntryTooltip(self.e, UI.bossName)
		GameTooltip:Show()
	end)
	h:SetScript("OnLeave", GameTooltip_Hide)
	return h
end

local function FillHalf(h, e, rank)
	h.e = e
	if not e then
		for _, fs in pairs(h.cells) do fs:SetText("") end
		return
	end
	h.cells.rank:SetText(rank .. ".")
	h.cells.name:SetText(e.name)
	h.cells.name:SetTextColor(PaperClassColor(e.class))
	h.cells.dps:SetText(ns.FormatNumber(e.dps))
	h.cells.key:SetText(KeyText(e))
	local txt, rr, gg, bb = ShortResult(e)
	h.cells.result:SetText(txt)
	h.cells.result:SetTextColor(rr, gg, bb)
end

local function CreateTopRow(parent)
	local r = CreateFrame("Frame", nil, parent)
	r:SetSize(HALF_W * 2 + HALF_GAP, ROW_H)

	r.band = r:CreateTexture(nil, "BACKGROUND")
	r.band:SetAllPoints()
	r.band:SetColorTexture(0.5, 0.35, 0.05, 0.35)

	r.icon = r:CreateTexture(nil, "ARTWORK")
	r.icon:SetSize(16, 16)
	r.icon:SetPoint("LEFT", 3, 0)
	r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	r.header = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	r.header:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
	r.header:SetTextColor(unpack(PAPER_HEAD))

	r.empty = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	r.empty:SetPoint("LEFT", 15, 0)
	r.empty:SetText("|cff9d9d9dno records yet|r")

	r.left = CreateHalf(r, 0)
	r.right = CreateHalf(r, HALF_W + HALF_GAP)

	-- thin line between the two halves
	r.sep = r:CreateTexture(nil, "ARTWORK")
	r.sep:SetWidth(1)
	r.sep:SetPoint("TOP", r, "TOPLEFT", HALF_W + HALF_GAP / 2, 0)
	r.sep:SetPoint("BOTTOM", r, "BOTTOMLEFT", HALF_W + HALF_GAP / 2, 0)
	r.sep:SetColorTexture(1, 0.82, 0, 0.25)
	return r
end

function UI:CreateDungeonPage()
	local v = CreateFrame("Frame", nil, self.inset)
	v:SetAllPoints()
	v:Hide()
	self.dungeonView = v

	local bg = v:CreateTexture(nil, "BACKGROUND")
	bg:SetPoint("TOPLEFT", 3, -3)
	bg:SetPoint("BOTTOMRIGHT", -3, 3)
	bg:SetTexture("Interface\\EncounterJournal\\UI-EJ-JournalBG")
	bg:SetTexCoord(0, 0.766601562, 0, 0.830078125)

	-- left page
	local title = v:CreateFontString(nil, "OVERLAY")
	SetFont(title, "QuestTitleFontBlackShadow", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 28, -18)
	title:SetWidth(330)
	title:SetJustifyH("LEFT")
	self.dTitle = title

	self.bossButtons = {}

	-- right page
	local right = CreateFrame("Frame", nil, v)
	right:SetPoint("TOPLEFT", 408, -14)
	right:SetPoint("BOTTOMRIGHT", -16, 10)
	self.right = right

	-- dark panel on the right page so colored text stays readable
	local panel = CreateFrame("Frame", nil, right)
	panel:SetPoint("TOPLEFT", 0, -30)
	panel:SetPoint("BOTTOMRIGHT", 0, 0)
	local pbg = panel:CreateTexture(nil, "BACKGROUND")
	pbg:SetAllPoints()
	pbg:SetColorTexture(0, 0, 0, 0.62)
	for _, side in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" }, { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
		local t = panel:CreateTexture(nil, "BORDER")
		t:SetColorTexture(0.65, 0.5, 0.25, 0.7)
		t:SetPoint(side[1]); t:SetPoint(side[2])
		if side[1] == "TOPLEFT" and side[2] == "BOTTOMLEFT" or side[1] == "TOPRIGHT" then t:SetWidth(1) else t:SetHeight(1) end
	end
	self.panel = panel

	local rTitle = right:CreateFontString(nil, "OVERLAY")
	SetFont(rTitle, "QuestTitleFontBlackShadow", "GameFontNormalLarge")
	rTitle:SetPoint("TOPLEFT", 4, -4)
	rTitle:SetPoint("RIGHT", -4, 0)
	rTitle:SetJustifyH("LEFT")
	self.rTitle = rTitle

	local rSub = right:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	rSub:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -8)
	rSub:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
	rSub:SetJustifyH("LEFT")
	rSub:SetTextColor(unpack(PAPER_DIM))
	self.rSub = rSub

	local rIcon = right:CreateTexture(nil, "ARTWORK")
	rIcon:SetSize(24, 24)
	rIcon:SetPoint("TOPLEFT", 2, -1)
	rIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	rIcon:Hide()
	self.rIcon = rIcon

	local hint = right:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	hint:SetPoint("CENTER", 0, 20)
	hint:SetWidth(300)
	hint:SetTextColor(unpack(PAPER_DIM))
	self.hint = hint

	-- 3) class list
	local classView = CreateFrame("Frame", nil, right)
	classView:SetPoint("TOPLEFT", 2, -56)
	classView:SetPoint("BOTTOMRIGHT")
	self.classView = classView
	self.classRows = {}
	for i, class in ipairs(ns.CLASS_ORDER) do
		local r = CreateClassRow(classView)
		r:SetPoint("TOPLEFT", 0, -(i - 1) * 27)
		r.class = class
		r.icon:SetTexture(ClassIcon(class))
		r.name:SetText(ClassName(class))
		r.name:SetTextColor(PaperClassColor(class))
		self.classRows[i] = r
	end

	-- 4) top of a class
	local topView = CreateFrame("Frame", nil, right)
	topView:SetPoint("TOPLEFT", 4, -54)
	topView:SetPoint("BOTTOMRIGHT")
	self.topView = topView

	-- two half headers: Tyrannical | Fortified, then the column labels
	local head = CreateFrame("Frame", nil, topView)
	head:SetSize(HALF_W * 2 + HALF_GAP, 32)
	head:SetPoint("TOPLEFT", 0, 0)
	self.tfHeads = {}
	for i, tf in ipairs({ ns.TYRANNICAL, ns.FORTIFIED }) do
		local x = (i - 1) * (HALF_W + HALF_GAP)
		local icon = head:CreateTexture(nil, "ARTWORK")
		icon:SetSize(14, 14)
		icon:SetPoint("TOPLEFT", x + 2, 0)
		icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		local _, _, file = C_ChallengeMode and C_ChallengeMode.GetAffixInfo and C_ChallengeMode.GetAffixInfo(tf)
		if file then icon:SetTexture(file) else icon:Hide() end
		local t = head:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		t:SetPoint("LEFT", icon, "RIGHT", 4, 0)
		t:SetText(ns.TFName(tf))
		t:SetTextColor(unpack(PAPER_HEAD))
		self.tfHeads[tf] = t
		local labels = { rank = "#", name = "Player", dps = "DPS", key = "Key", result = "+" }
		for k, c in pairs(COLS) do
			local fs = head:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
			fs:SetPoint("TOPLEFT", x + c[1], -18)
			fs:SetWidth(c[2])
			fs:SetJustifyH(c[3])
			fs:SetTextColor(unpack(PAPER_DIM))
			fs:SetText(labels[k])
		end
	end
	local hline = head:CreateTexture(nil, "ARTWORK")
	hline:SetHeight(1)
	hline:SetPoint("BOTTOMLEFT", 0, -2)
	hline:SetPoint("BOTTOMRIGHT", 0, -2)
	hline:SetColorTexture(1, 0.82, 0, 0.35)

	local sf = CreateFrame("ScrollFrame", "MythicBossRecordsTopScroll", topView, "FauxScrollFrameTemplate")
	sf:SetPoint("TOPLEFT", 0, -36)
	sf:SetPoint("BOTTOMRIGHT", -24, 0)
	sf:SetScript("OnVerticalScroll", function(self, offset)
		FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, function() UI:RefreshTop() end)
	end)
	self.topScroll = sf
	self.topRows = {}
	for i = 1, NUM_ROWS do
		local r = CreateTopRow(topView)
		r:SetPoint("TOPLEFT", 0, -36 - (i - 1) * ROW_H)
		self.topRows[i] = r
	end
end

function UI:RefreshDungeonPage()
	local d = self.dungeons[self.dungeonIndex]
	if not d then return self:ShowGrid() end
	self.dTitle:SetText(d.name)

	for i, boss in ipairs(d.bosses) do
		local b = self.bossButtons[i]
		if not b then
			b = CreateBossButton(self.dungeonView)
			b:SetPoint("TOPLEFT", 30, -62 - (i - 1) * 66)
			self.bossButtons[i] = b
		end
		b.encID = boss[1]
		b.creature:SetTexture(ns.BossPortrait(boss))
		b.text:SetText(boss[2])
		local best = ns.BossBest(boss[1], ns.TopTF())
		if best then
			local n = 0
			for _, list in pairs(ns.db.records[boss[1]]) do n = n + #list end
			b.sub:SetText(format("%s: |cffffffff%s|r %s%s|r  -  %d rec.", ns.TopTF() == ns.FORTIFIED and "Fort." or "Tyr.",
				ns.FormatNumber(best.dps), ns.ClassColorCode(best.class), best.name, n))
		elseif ns.BossBest(boss[1]) then
			b.sub:SetText("|cff8a8070no " .. ns.TFName(ns.TopTF()) .. " record yet|r")
		else
			b.sub:SetText("|cff8a8070no records yet|r")
		end
		if boss[1] == self.encID then b:LockHighlight() else b:UnlockHighlight() end
		b:Show()
	end
	for i = #d.bosses + 1, #self.bossButtons do self.bossButtons[i]:Hide() end

	-- right page
	self.rIcon:Hide()
	self.rTitle:SetTextColor(unpack(PAPER_HEAD))
	self.rTitle:ClearAllPoints()
	self.rTitle:SetPoint("TOPLEFT", 4, -4)
	self.rTitle:SetPoint("RIGHT", -4, 0)
	self.hint:Hide()
	self.classView:Hide()
	self.topView:Hide()

	if not self.encID then
		self.rTitle:SetText(d.name)
		self.rSub:SetText(#d.bosses .. " bosses")
		self.hint:SetText("Pick a boss on the left to see the DPS records by class.")
		self.hint:Show()
	elseif not self.class then
		self.rTitle:SetText(self.bossName)
		self.rSub:SetText("Pick a class - best " .. ns.TFName(ns.TopTF()) .. " DPS of each class (this week):")
		self:RefreshClasses()
		self.classView:Show()
	else
		self.rIcon:SetTexture(ClassIcon(self.class))
		self.rIcon:Show()
		self.rTitle:ClearAllPoints()
		self.rTitle:SetPoint("TOPLEFT", self.rIcon, "TOPRIGHT", 8, -3)
		self.rTitle:SetPoint("RIGHT", -4, 0)
		local r, g, b = PaperClassColor(self.class)
		self.rTitle:SetText(ClassName(self.class))
		self.rTitle:SetTextColor(r, g, b)
		self.rSub:SetText("Top DPS on " .. self.bossName .. " (top " .. ns.db.settings.maxPerSpec .. " per spec)")
		self.topItems = ns.GetClassRows(self.encID, self.class)
		FauxScrollFrame_SetOffset(self.topScroll, 0)
		self.topScroll:SetVerticalScroll(0)
		self:RefreshTop()
		self.topView:Show()
	end
end

function UI:RefreshClasses()
	local sum = ns.GetClassSummary(self.encID, ns.TopTF())
	-- ordered like a top: best DPS first, classes without a record at the end
	local order = {}
	for i, r in ipairs(self.classRows) do order[#order + 1] = { r = r, i = i } end
	table.sort(order, function(a, b)
		local ca, cb = sum[a.r.class], sum[b.r.class]
		local da = ca and ca.best and ca.best.dps or (ca and 0) or -1
		local db = cb and cb.best and cb.best.dps or (cb and 0) or -1
		if da ~= db then return da > db end
		return a.i < b.i
	end)
	for pos, o in ipairs(order) do
		o.r:ClearAllPoints()
		o.r:SetPoint("TOPLEFT", 0, -(pos - 1) * 27)
	end
	for _, r in ipairs(self.classRows) do
		local c = sum[r.class]
		if c and c.best then
			r.best:SetText(format("%s  |cffffd100%s|r", ns.FormatNumber(c.best.dps), KeyText(c.best)))
			r.count:SetText(c.count .. " rec.")
			r.bestEntry = c.best
			r:SetAlpha(1)
		elseif c then
			r.best:SetText("|cff8a8070-|r")
			r.count:SetText(c.count .. " rec.")
			r.bestEntry = c.any
			r:SetAlpha(0.75)
		else
			r.best:SetText("-")
			r.count:SetText("")
			r.bestEntry = nil
			r:SetAlpha(0.5)
		end
	end
end

function UI:RefreshTop()
	local items = self.topItems or {}
	FauxScrollFrame_Update(self.topScroll, #items, NUM_ROWS, ROW_H)
	local offset = FauxScrollFrame_GetOffset(self.topScroll)
	-- this week's half gets a "(this week)" mark
	local cur = ns.CurrentTF()
	for tf, t in pairs(self.tfHeads or {}) do
		t:SetText(ns.TFName(tf) .. (tf == cur and " |cff9d9d9d(this week)|r" or ""))
	end
	for i, r in ipairs(self.topRows) do
		local it = items[i + offset]
		if not it then
			r:Hide()
		else
			r:Show()
			local isHeader = it.header ~= nil
			r.band:SetShown(isHeader); r.icon:SetShown(isHeader); r.header:SetShown(isHeader)
			r.empty:SetShown(it.empty == true)
			r.sep:SetShown(not isHeader)
			if isHeader then
				local name, icon = SpecLabel(it.header)
				r.icon:SetTexture(icon)
				r.header:SetText(name)
				FillHalf(r.left, nil); FillHalf(r.right, nil)
				r.left:Hide(); r.right:Hide()
			elseif it.empty then
				FillHalf(r.left, nil); FillHalf(r.right, nil)
				r.left:Hide(); r.right:Hide()
			else
				r.left:Show(); r.right:Show()
				FillHalf(r.left, it.tyr, it.rank)
				FillHalf(r.right, it.fort, it.rank)
			end
		end
	end
end

-- ---------------------------------------------------------------------
-- Navigation
-- ---------------------------------------------------------------------
-- the Update button turns green when someone with a newer version was seen
function UI:UpdateUpdateButton()
	if not self.updateBtn then return end
	if ns.newerVersion then
		self.updateBtn:SetText("|cff20ff20Update!|r")
	else
		self.updateBtn:SetText("Update")
	end
end

function UI.UpdateText()
	local head = ns.newerVersion
		and ("|cff20ff20Mythic Boss Records V." .. ns.newerVersion .. " is out|r (you have V." .. ns.VERSION .. ").")
		or ("You have Mythic Boss Records V." .. ns.VERSION .. ".")
	return head .. "\n\nWoW addons cannot download files, so the update is done outside the game:\n\n" ..
		"|cffffd100If \"automatic\" is on in MBR Tools.cmd|r: it updates by itself within a minute - just restart WoW.\n\n" ..
		"|cffffd100Otherwise|r: close WoW, open the folder Interface\\AddOns\\MythicBossRecords and double-click |cffffd100MBR Tools.cmd|r, then 3 (Update the addon now)."
end

-- "Sync logs": send the records of your own combat log to everyone again and ask
-- everyone for what you are missing; or explain how the log gets read
function UI:SyncLogs()
	local own = ns.OwnLogRecords()
	if #own == 0 and ns.db.localPackId then
		-- the log was read, but nothing in it is good enough for the tops (or it had no +9 boss kills)
		ns.Sync:Hello()
		StaticPopup_Show("MBR_UPDATE", "|cffffd100Your combat log was read|r, but it has no +9 boss kills good enough for the tops yet.\n\n" ..
			"New keys are added automatically every 15 minutes (MBR Tools). Asking everyone for the records you are missing now.")
		return
	end
	if #own == 0 then
		ns.Sync:Hello()
		local st = ns.TOOLS_STATUS
		if st and st.text then
			StaticPopup_Show("MBR_UPDATE", "|cffffd100MBR Tools last ran " .. date("%d.%m %H:%M", st.time or 0) .. ":|r\n\n" .. st.text ..
				"\n\n|cffffd100/reload|r after it reads new keys.")
			return
		end
		StaticPopup_Show("MBR_UPDATE", "|cffffd100Your combat log has not been read yet|r (MBR Tools has not run on this PC).\n\n" ..
			"WoW addons cannot open files, so a small tool next to the addon reads it:\n\n" ..
			"Close WoW, open Interface\\AddOns\\MythicBossRecords and double-click |cffffd100MBR Tools.cmd|r, " ..
			"then |cffffd1001|r (automatic: your new log is read every 15 minutes from now on).\n\n" ..
			"In game, type |cffffd100/combatlog|r before a key so the game writes the log.")
		return
	end
	if ns.Sync:QueueSize() > 50 then
		ns.Print("Still sending the previous batch - try again in a few minutes.")
		return
	end
	ns.Sync:Share(own)
	ns.Sync:Hello()
	ns.Print(format("Sharing |cff00ff00%d|r records from your combat log with everyone (in the background, a few minutes).", #own))
end

StaticPopupDialogs["MBR_UPDATE"] = {
	text = "%s",
	button1 = OKAY,
	timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

function UI:UpdateNav()
	local parts = { "|cffffd100Dungeons|r" }
	if self.view == "dungeon" then
		local d = self.dungeons[self.dungeonIndex]
		parts[#parts + 1] = d and d.name or "?"
		if self.encID then parts[#parts + 1] = self.bossName end
		if self.class then parts[#parts + 1] = ns.ClassColorCode(self.class) .. ClassName(self.class) .. "|r" end
	elseif self.view == "player" then
		local p = ns.PlayerNames()[(self.player or ""):lower()]
		parts[#parts + 1] = "Player: " .. ns.ClassColorCode(p and p.class) .. (self.player or "?") .. "|r"
	end
	self.crumb:SetText(table.concat(parts, "  |cff808080>|r  "))
	self:UpdateUpdateButton()
	if self.view == "grid" then self.backBtn:Disable() else self.backBtn:Enable() end
	self.footer:SetText(format("Saved records: |cffffffff%d|r      %s", ns.CountRecords(),
		ns.Sync and ns.Sync:StatusText() or ""))
end

function UI:Refresh()
	if not self.frame then return end
	self.dungeons = ns.GetDungeonList()
	self.playerView:SetShown(self.view == "player")
	if self.view == "player" then
		self.gridView:Hide()
		self.dungeonView:Hide()
		self:RefreshPlayer()
	elseif self.view == "dungeon" then
		self.gridView:Hide()
		self.dungeonView:Show()
		self:RefreshDungeonPage()
	else
		self.view = "grid"
		self.dungeonView:Hide()
		self.gridView:Show()
		self:RefreshGrid()
	end
	self:UpdateNav()
end

function UI:ShowGrid()
	self.view, self.dungeonIndex, self.encID, self.class = "grid", nil, nil, nil
	self:Refresh()
end

function UI:ShowDungeon(index)
	self.view, self.dungeonIndex, self.encID, self.class = "dungeon", index, nil, nil
	self:Refresh()
end

function UI:SelectBoss(encID)
	self.encID, self.class = encID, nil
	self.bossName = (ns.ENCOUNTER_INFO[encID] and ns.ENCOUNTER_INFO[encID].name)
		or (ns.db.encounters[encID] and ns.db.encounters[encID].name) or ("Boss " .. encID)
	self:Refresh()
end

function UI:SelectClass(class)
	self.class = class
	self:Refresh()
end

function UI:Back()
	if self.view == "player" then return self:ShowGrid() end
	if self.class then
		self.class = nil
	elseif self.encID then
		self.encID = nil
	else
		return self:ShowGrid()
	end
	self:Refresh()
end

-- On first open inside a dungeon, jump straight to it
function UI:AutoSelectCurrent()
	local inst = GetInstanceInfo()
	if not inst then return end
	for i, d in ipairs(ns.GetDungeonList()) do
		if d.name == inst or d.instance == inst then
			self.view, self.dungeonIndex, self.encID, self.class = "dungeon", i, nil, nil
			return
		end
	end
end

function UI:Toggle()
	self:Create()
	if self.frame:IsShown() then
		self.frame:Hide()
	else
		if not self.view then
			self.view = "grid"
			self:AutoSelectCurrent()
		end
		self:Refresh()
		self.frame:Show()
	end
end

function UI:OnNewData()
	if self.frame and self.frame:IsShown() then self:Refresh() end
end

-- ---------------------------------------------------------------------
-- Minimap button
-- ---------------------------------------------------------------------
function UI:UpdateMinimapButton()
	local mm = ns.db.settings.minimap
	local b = self.minimapButton
	if not b then return end
	if mm.hide then b:Hide(); return end
	local a = math.rad(mm.angle or 215)
	b:ClearAllPoints()
	b:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * 80, math.sin(a) * 80)
	b:Show()
end

function UI:CreateMinimapButton()
	local b = CreateFrame("Button", "MythicBossRecordsMinimapButton", Minimap)
	self.minimapButton = b
	b:SetSize(31, 31)
	b:SetFrameStrata("MEDIUM")
	b:SetFrameLevel(8)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")
	b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local icon = b:CreateTexture(nil, "BACKGROUND")
	icon:SetSize(20, 20)
	icon:SetPoint("TOPLEFT", 7, -5)
	icon:SetTexture("Interface\\Icons\\INV_Relics_Hourglass")
	local border = b:CreateTexture(nil, "OVERLAY")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

	b:SetScript("OnClick", function() UI:Toggle() end)
	b:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local px, py = GetCursorPosition()
			local sc = Minimap:GetEffectiveScale()
			ns.db.settings.minimap.angle = math.deg(math.atan2(py / sc - my, px / sc - mx))
			UI:UpdateMinimapButton()
		end)
	end)
	b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("Mythic Boss Records", 1, 0.82, 0)
		GameTooltip:AddLine("Click: open / close", 1, 1, 1)
		GameTooltip:AddLine("Drag: move the button", 1, 1, 1)
		GameTooltip:AddLine(format("Records: %d", ns.CountRecords()), 0.7, 0.7, 0.7)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", GameTooltip_Hide)
	self:UpdateMinimapButton()
end

function UI:OnLogin()
	self:CreateMinimapButton()
end
