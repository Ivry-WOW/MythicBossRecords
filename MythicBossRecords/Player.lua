local ADDON, ns = ...

-- =====================================================================
--  Mythic Boss Records - player search
--  A search box in the window's top bar: type a name, pick it from the
--  list and a page opens with that player's best DPS on every boss.
-- =====================================================================

local UI = ns.UI
local format, floor = string.format, math.floor
local ROW_H, NUM_ROWS = 18, 17
local MAX_SUGGEST = 8

-- ---------------------------------------------------------------------
-- Data
-- ---------------------------------------------------------------------
local function Lower(s) return (s or ""):lower() end

-- every player with records: lower name -> { name, class, count }
local nameCache, nameCacheN
function ns.PlayerNames()
	local n = ns.CountRecords()
	if nameCache and nameCacheN == n then return nameCache end
	nameCache, nameCacheN = {}, n
	for _, boss in pairs(ns.db.records) do
		for _, list in pairs(boss) do
			for _, e in ipairs(list) do
				local k = Lower(e.name)
				local p = nameCache[k]
				if not p then p = { name = e.name, class = e.class, count = 0 }; nameCache[k] = p end
				p.count = p.count + 1
			end
		end
	end
	return nameCache
end

-- players whose name contains <text>; names starting with it come first
function ns.SearchPlayers(text)
	text = Lower(text):gsub("^%s+", ""):gsub("%s+$", "")
	local out = {}
	if text == "" then return out end
	for k, p in pairs(ns.PlayerNames()) do
		local at = k:find(text, 1, true)
		if at then out[#out + 1] = { p = p, start = at == 1 } end
	end
	table.sort(out, function(a, b)
		if a.start ~= b.start then return a.start end
		if a.p.count ~= b.p.count then return a.p.count > b.p.count end
		return a.p.name < b.p.name
	end)
	for i, x in ipairs(out) do out[i] = x.p end
	return out
end

-- rank of a record inside its spec list, counting only the same Tyrannical / Fortified
local function RankOf(list, e)
	local tf, r = ns.RecordTF(e), 0
	for _, x in ipairs(list) do
		if ns.RecordTF(x) == tf then
			r = r + 1
			if x == e then return r end
		end
	end
end

-- rows for the player page: dungeon headers + one row per boss (best DPS of the player there)
function ns.GetPlayerRows(name)
	local key = Lower(name)
	local rows, total, bosses = {}, 0, 0
	for di, d in ipairs(ns.GetDungeonList()) do
		local block = {}
		for _, b in ipairs(d.bosses) do
			local encID = b[1]
			local best, bestList
			for _, list in pairs(ns.db.records[encID] or {}) do
				for _, e in ipairs(list) do
					if Lower(e.name) == key and (not best or e.dps > best.dps) then best, bestList = e, list end
				end
			end
			block[#block + 1] = { boss = b[2], encID = encID, dungeon = di, e = best,
				rank = best and RankOf(bestList, best) }
			if best then total = total + 1 end
		end
		local any = false
		for _, r in ipairs(block) do if r.e then any = true end end
		if any then
			rows[#rows + 1] = { header = d.name, dungeon = di }
			for _, r in ipairs(block) do rows[#rows + 1] = r end
			bosses = bosses + #block
		end
	end
	return rows, total, bosses
end

-- ---------------------------------------------------------------------
-- Search box + suggestions (top bar)
-- ---------------------------------------------------------------------
function UI:CreateSearch()
	local f = self.frame
	local box = CreateFrame("EditBox", "MythicBossRecordsSearch", f, "InputBoxTemplate")
	box:SetSize(130, 16)
	box:SetPoint("TOPRIGHT", f, "TOPRIGHT", -34, -3)   -- in the title bar, left of the close button
	box:SetAutoFocus(false)
	box:SetMaxLetters(24)
	self.searchBox = box

	local hint = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("LEFT", 2, 0)
	hint:SetText("Search player...")
	box.hint = hint

	local list = CreateFrame("Frame", nil, f)
	list:SetPoint("TOPLEFT", box, "BOTTOMLEFT", -6, -2)
	list:SetSize(170, 10)
	list:SetFrameStrata("DIALOG")
	local bg = list:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.05, 0.04, 0.02, 0.95)
	local edge = list:CreateTexture(nil, "BORDER")
	edge:SetPoint("TOPLEFT", -1, 1); edge:SetPoint("BOTTOMRIGHT", 1, -1)
	edge:SetColorTexture(0.65, 0.5, 0.25, 0.9)
	list:Hide()
	self.suggest = list
	self.suggestRows = {}
	for i = 1, MAX_SUGGEST do
		local b = CreateFrame("Button", nil, list)
		b:SetSize(166, 18)
		b:SetPoint("TOPLEFT", 2, -2 - (i - 1) * 18)
		local hl = b:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints(); hl:SetColorTexture(1, 0.82, 0, 0.15)
		b.name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		b.name:SetPoint("LEFT", 4, 0)
		b.count = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		b.count:SetPoint("RIGHT", -4, 0)
		b:SetScript("OnClick", function(s) UI:ShowPlayer(s.player.name) end)
		self.suggestRows[i] = b
	end

	box:SetScript("OnTextChanged", function(s)
		local text = s:GetText() or ""
		s.hint:SetShown(text == "" and not s:HasFocus())
		UI:UpdateSuggestions(text)
	end)
	box:SetScript("OnEditFocusGained", function(s) s.hint:Hide(); UI:UpdateSuggestions(s:GetText() or "") end)
	box:SetScript("OnEditFocusLost", function(s)
		s.hint:SetShown((s:GetText() or "") == "")
		C_Timer.After(0.2, function() if not s:HasFocus() then UI.suggest:Hide() end end)
	end)
	box:SetScript("OnEnterPressed", function(s)
		local first = UI.suggestFound and UI.suggestFound[1]
		if first then UI:ShowPlayer(first.name) end
		s:ClearFocus()
	end)
	box:SetScript("OnEscapePressed", function(s) s:SetText(""); s:ClearFocus() end)
end

function UI:UpdateSuggestions(text)
	local found = ns.SearchPlayers(text)
	self.suggestFound = found
	if #found == 0 then self.suggest:Hide(); return end
	local n = math.min(#found, MAX_SUGGEST)
	for i, b in ipairs(self.suggestRows) do
		local p = found[i]
		b.player = p
		if p then
			b.name:SetText(p.name)
			b.name:SetTextColor(ns.ClassColor(p.class))
			b.count:SetText(p.count .. " rec.")
			b:Show()
		else
			b:Hide()
		end
	end
	self.suggest:SetHeight(n * 18 + 4)
	self.suggest:Show()
end

-- ---------------------------------------------------------------------
-- Player page
-- ---------------------------------------------------------------------
local COLS = {
	boss   = { 8, 190, "LEFT" },
	dps    = { 200, 66, "RIGHT" },
	spec   = { 280, 110, "LEFT" },
	key    = { 392, 36, "CENTER" },
	result = { 430, 30, "CENTER" },
	week   = { 466, 76, "LEFT" },
	rank   = { 544, 112, "LEFT" },
	date   = { 660, 74, "RIGHT" },
}

local function ShortResult(e)
	if e.level == 0 then return "M0", 0.5, 0.5, 0.5 end
	if e.result == nil then return "?", 0.5, 0.5, 0.5 end
	if e.result == 0 then return "D", 1, 0.25, 0.2 end
	return "+" .. e.result, 0.1, 1, 0.1
end

function UI:CreatePlayerPage()
	local v = CreateFrame("Frame", nil, self.inset)
	v:SetAllPoints()
	v:Hide()
	self.playerView = v

	local bg = v:CreateTexture(nil, "BACKGROUND")
	bg:SetPoint("TOPLEFT", 3, -3)
	bg:SetPoint("BOTTOMRIGHT", -3, 3)
	bg:SetTexture("Interface\\EncounterJournal\\UI-EJ-JournalBG")
	bg:SetTexCoord(0, 0.766601562, 0, 0.830078125)
	local dark = v:CreateTexture(nil, "BORDER")
	dark:SetPoint("TOPLEFT", 14, -50)
	dark:SetPoint("BOTTOMRIGHT", -14, 10)
	dark:SetColorTexture(0, 0, 0, 0.62)

	local icon = v:CreateTexture(nil, "ARTWORK")
	icon:SetSize(30, 30)
	icon:SetPoint("TOPLEFT", 18, -12)
	icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	self.pIcon = icon
	local title = v:CreateFontString(nil, "OVERLAY")
	if _G.QuestTitleFontBlackShadow then title:SetFontObject(QuestTitleFontBlackShadow) else title:SetFontObject(GameFontNormalLarge) end
	title:SetPoint("LEFT", icon, "RIGHT", 8, 1)
	self.pTitle = title
	local sub = v:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	sub:SetPoint("LEFT", title, "RIGHT", 12, -1)
	sub:SetTextColor(0.75, 0.75, 0.75)
	self.pSub = sub

	local head = CreateFrame("Frame", nil, v)
	head:SetPoint("TOPLEFT", 14, -54)
	head:SetSize(740, 16)
	local labels = { boss = "Boss", dps = "Best DPS", spec = "Spec", key = "Key", result = "+",
		week = "Week", rank = "Rank in spec", date = "Date" }
	for k, c in pairs(COLS) do
		local fs = head:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		fs:SetPoint("LEFT", c[1], 0); fs:SetWidth(c[2]); fs:SetJustifyH(c[3])
		fs:SetText(labels[k])
	end
	local line = head:CreateTexture(nil, "ARTWORK")
	line:SetHeight(1)
	line:SetPoint("BOTTOMLEFT", 0, -2); line:SetPoint("BOTTOMRIGHT", 0, -2)
	line:SetColorTexture(1, 0.82, 0, 0.35)

	local sf = CreateFrame("ScrollFrame", "MythicBossRecordsPlayerScroll", v, "FauxScrollFrameTemplate")
	sf:SetPoint("TOPLEFT", 14, -74)
	sf:SetPoint("BOTTOMRIGHT", -38, 12)
	sf:SetScript("OnVerticalScroll", function(s, offset)
		FauxScrollFrame_OnVerticalScroll(s, offset, ROW_H, function() UI:RefreshPlayer() end)
	end)
	self.playerScroll = sf

	self.playerRows = {}
	for i = 1, NUM_ROWS do
		local r = CreateFrame("Button", nil, v)
		r:SetSize(740, ROW_H)
		r:SetPoint("TOPLEFT", 14, -74 - (i - 1) * ROW_H)
		local hl = r:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.08)
		r.band = r:CreateTexture(nil, "BACKGROUND")
		r.band:SetAllPoints(); r.band:SetColorTexture(0.5, 0.35, 0.05, 0.35)
		r.header = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		r.header:SetPoint("LEFT", 8, 0)
		r.cells = {}
		for k, c in pairs(COLS) do
			local fs = r:CreateFontString(nil, "OVERLAY", k == "dps" and "GameFontHighlight" or "GameFontHighlightSmall")
			fs:SetPoint("LEFT", c[1], 0); fs:SetWidth(c[2]); fs:SetJustifyH(c[3]); fs:SetWordWrap(false)
			r.cells[k] = fs
		end
		r:SetScript("OnEnter", function(s)
			if not s.item or not s.item.e then return end
			GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
			UI.AddEntryTooltip(s.item.e, s.item.boss)
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("Click: open this boss / class", 0.6, 0.8, 1)
			GameTooltip:Show()
		end)
		r:SetScript("OnLeave", GameTooltip_Hide)
		r:SetScript("OnClick", function(s)
			local it = s.item
			if not it or not it.encID then return end
			UI.view, UI.dungeonIndex = "dungeon", it.dungeon
			UI:SelectBoss(it.encID)
			if it.e then UI:SelectClass(it.e.class) end
		end)
		self.playerRows[i] = r
	end

	local none = v:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	none:SetPoint("CENTER", 0, -10)
	none:SetTextColor(0.62, 0.62, 0.62)
	none:SetText("No records for this player.")
	self.pNone = none
end

function UI:ShowPlayer(name)
	self.suggest:Hide()
	self.searchBox:SetText("")
	self.searchBox:ClearFocus()
	self.view, self.player = "player", name
	self.dungeonIndex, self.encID, self.class = nil, nil, nil
	self:Refresh()
end

function UI:RefreshPlayer()
	local p = ns.PlayerNames()[Lower(self.player)] or { name = self.player }
	local rows, have, total = ns.GetPlayerRows(p.name)
	self.playerItems = rows
	local icon = p.class and ("Interface\\Icons\\ClassIcon_" .. (p.class == "DEATHKNIGHT" and "DeathKnight" or p.class == "DEMONHUNTER" and "DemonHunter" or (p.class:sub(1, 1) .. p.class:sub(2):lower())))
	if icon then self.pIcon:SetTexture(icon); self.pIcon:Show() else self.pIcon:Hide() end
	self.pTitle:SetText(p.name)
	self.pTitle:SetTextColor(ns.ClassColor(p.class))
	self.pSub:SetText(format("best DPS on %d boss%s  -  %d records", have, have == 1 and "" or "es", p.count or 0))
	self.pNone:SetShown(#rows == 0)

	FauxScrollFrame_Update(self.playerScroll, #rows, NUM_ROWS, ROW_H)
	local offset = FauxScrollFrame_GetOffset(self.playerScroll)
	for i, r in ipairs(self.playerRows) do
		local it = rows[i + offset]
		r.item = it
		if not it then
			r:Hide()
		else
			r:Show()
			local hdr = it.header ~= nil
			r.band:SetShown(hdr); r.header:SetShown(hdr)
			for _, fs in pairs(r.cells) do fs:SetText(""); fs:SetTextColor(1, 1, 1) end
			if hdr then
				r.header:SetText(it.header)
			else
				r.cells.boss:SetText(it.boss)
				local e = it.e
				if e then
					r.cells.dps:SetText(ns.FormatNumber(e.dps))
					local si = ns.SpecInfo(e.spec)
					r.cells.spec:SetText(si and si.name or "?")
					r.cells.spec:SetTextColor(ns.ClassColor(e.class))
					r.cells.key:SetText(e.level == 0 and "M0" or ("+" .. e.level))
					local txt, rr, gg, bb = ShortResult(e)
					r.cells.result:SetText(txt); r.cells.result:SetTextColor(rr, gg, bb)
					r.cells.week:SetText(ns.TFName(ns.RecordTF(e)))
					if it.rank then
						r.cells.rank:SetText(format("#%d %s", it.rank, si and si.name or ""))
						if it.rank == 1 then r.cells.rank:SetTextColor(1, 0.82, 0) end
					end
					r.cells.date:SetText(ns.FormatDate(e.date))
				else
					r.cells.dps:SetText("|cff9d9d9d-|r")
				end
			end
		end
	end
end

-- other addons (Guild Weekly Best) open a player's page with this
function MythicBossRecords_ShowPlayer(name)
	if not name or not ns.db then return end
	if not UI.frame or not UI.frame:IsShown() then UI:Toggle() end
	UI:ShowPlayer(name)
end
