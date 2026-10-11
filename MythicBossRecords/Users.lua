local ADDON, ns = ...

-- =====================================================================
--  Mythic Boss Records - addon users tracker
--  Every client says "I have the addon (version, class)" on:
--   * the guild channel, online friends (whisper), your party / raid
--   * a hidden server-wide chat channel, so players from anywhere are seen
--  The list only stores names / versions; it never trusts these players
--  with key data (that stays guild + friends only, see Sync.lua).
--  Purpose: the addon is meant for the guild only - this shows who else has it.
--  Message (prefix "GWBU"):  U~version~class~reply~guild   (reply = 1: please answer)
-- =====================================================================

local Users = {}
ns.Users = Users

local PREFIX = "MBRU"
local SEP = "~"
local CHANNEL = "MBRSync" -- same hidden channel as the record sync
local HEARTBEAT = 15 * 60       -- re-announce every 15 min
local ONLINE_WINDOW = 20 * 60   -- seen in the last 20 min = online
local KEEP_DAYS = 30
local ROW_H, NUM_ROWS = 18, 18

local format, floor, time = string.format, math.floor, time
local db, myVersion, myClass, myKey
local lastAnswer = {}           -- distribution -> time() of our last answer
local lastGroupHello = 0

local function Short(name) return name and ((name:match("^([^%-]+)")) or name) end
local function Key(name) return name and Short(name):lower() end

local function VersionNum(v)
	local a, b, c = tostring(v or ""):match("(%d+)%.?(%d*)%.?(%d*)")
	return (tonumber(a) or 0) * 10000 + (tonumber(b) or 0) * 100 + (tonumber(c) or 0)
end

-- ---------------------------------------------------------------------
-- Hidden server-wide channel
-- ---------------------------------------------------------------------
local function ChannelID()
	if not GetChannelName then return nil end
	local id = GetChannelName(CHANNEL)
	if id and id > 0 then return id end
end

local function HideChannel()
	if not ChatFrame_RemoveChannel then return end
	for i = 1, (NUM_CHAT_WINDOWS or 10) do
		local cf = _G["ChatFrame" .. i]
		if cf then pcall(ChatFrame_RemoveChannel, cf, CHANNEL) end
	end
end

local function JoinGlobal()
	if (db.settings.sync and db.settings.sync.global == false) or not JoinTemporaryChannel and not JoinChannelByName then return end
	if not ChannelID() then
		local join = JoinTemporaryChannel or JoinChannelByName
		pcall(join, CHANNEL)
	end
	HideChannel()
end

-- no "Joined channel: MBRSync" spam in the chat
if ChatFrame_AddMessageEventFilter then
	local function filter(_, _, _, _, _, _, _, _, _, _, channelName)
		if channelName and tostring(channelName):lower():find(CHANNEL:lower(), 1, true) then return true end
	end
	ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_NOTICE", filter)
	ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_NOTICE_USER", filter)
	ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_JOIN", filter)
	ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_LEAVE", filter)
end

-- ---------------------------------------------------------------------
-- Sending
-- ---------------------------------------------------------------------
local function MyGuild()
	local g = GetGuildInfo and GetGuildInfo("player")
	return g and g:gsub(SEP, "") or ""
end
local function Msg(reply)
	return format("U%s%s%s%s%s%d%s%s", SEP, myVersion, SEP, myClass or "", SEP, reply and 1 or 0, SEP, MyGuild())
end

-- outside = not in your guild (by the guild name they send, or by your roster)
function Users:IsOutsider(u)
	local mine = GetGuildInfo and GetGuildInfo("player")
	if u.guild and u.guild ~= "" then return u.guild ~= mine end
	local roster = ns.Sync and ns.Sync:GuildRoster() or {}
	return not roster[Key(u.name)]
end

local function Send(msg, dist, target)
	pcall(SendAddonMessage, PREFIX, msg, dist, target)
end

local function GroupDist()
	if IsInGroup and LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
	if IsInRaid and IsInRaid() then return "RAID" end
	if (IsInGroup and IsInGroup()) or (GetNumSubgroupMembers and GetNumSubgroupMembers() > 0) then return "PARTY" end
end

function Users:Announce(reply)
	local msg = Msg(reply)
	if IsInGuild() then Send(msg, "GUILD") end
	local g = GroupDist()
	if g then Send(msg, g) end
	local id = ChannelID()
	if id then Send(msg, "CHANNEL", tostring(id)) end
end

-- ---------------------------------------------------------------------
-- Receiving
-- ---------------------------------------------------------------------
local VIA_ORDER = { guild = 1, friend = 2, group = 3, server = 4 }

local function OnMessage(prefix, msg, dist, sender)
	if prefix ~= PREFIX or not db then return end
	local k = Key(sender)
	if not k or k == myKey then return end
	local f = {}
	for part in (msg .. SEP):gmatch("(.-)" .. SEP) do f[#f + 1] = part end
	if f[1] ~= "U" or not f[2] or #f[2] > 12 then return end
	local via = (dist == "GUILD" and "guild") or (dist == "WHISPER" and "friend")
		or ((dist == "PARTY" or dist == "RAID" or dist == "INSTANCE_CHAT") and "group") or "server"
	local u = db.users[k]
	if not u then u = {}; db.users[k] = u end
	-- "Name-Evermoon" -> "Name" when it is our own realm (realm shows as "[EN] Evermoon")
	local short, realm = sender:match("^([^%-]+)%-(.+)$")
	local mine = (GetRealmName and GetRealmName() or ""):gsub("[^%w]", ""):lower()
	if short and realm and mine:sub(-#realm) == realm:gsub("[^%w]", ""):lower() then
		u.name = short
	else
		u.name = sender
	end
	u.version = f[2]
	if f[3] and f[3] ~= "" and RAID_CLASS_COLORS and RAID_CLASS_COLORS[f[3]] then u.class = f[3] end
	u.seen = time()
	if dist == "GUILD" then u.guild = GetGuildInfo and GetGuildInfo("player") or u.guild
	elseif f[5] then u.guild = f[5] end

	if not u.via or (VIA_ORDER[via] or 9) < (VIA_ORDER[u.via] or 9) then u.via = via end
	if VersionNum(f[2]) > VersionNum(ns.newerVersion or myVersion) then
		local first = not ns.newerVersion
		ns.newerVersion = f[2]
		if first then
			ns.Print(format("A newer version (|cff00ff00V.%s|r) is out. Click |cffffd100Update|r in the window to see how to get it.", f[2]))
		end
		if ns.UI and ns.UI.UpdateUpdateButton then ns.UI:UpdateUpdateButton() end
	end
	-- they asked for an answer: one answer per channel per minute, after a random delay
	if f[4] == "1" then
		local key = (dist == "WHISPER") and ("W" .. k) or dist
		if time() - (lastAnswer[key] or 0) >= 60 then
			lastAnswer[key] = time()
			C_Timer.After(1 + math.random() * 5, function()
				if dist == "WHISPER" then Send(Msg(false), "WHISPER", sender)
				elseif dist == "CHANNEL" then local id = ChannelID(); if id then Send(Msg(false), "CHANNEL", tostring(id)) end
				else Send(Msg(false), dist) end
			end)
		end
	end
	if Users.frame and Users.frame:IsShown() then Users:Update() end
end

function Users:Get(name) return db and db.users[Key(name) or ""] end

function Users:IsOnline(u) return u and (time() - (u.seen or 0)) < ONLINE_WINDOW end

function Users:Count()
	local n, on = 0, 0
	for _, u in pairs(db and db.users or {}) do
		n = n + 1
		if self:IsOnline(u) then on = on + 1 end
	end
	return n, on
end

-- ---------------------------------------------------------------------
-- Window: /gwb users
-- ---------------------------------------------------------------------
local function Ago(t)
	local d = time() - (t or 0)
	if d < ONLINE_WINDOW then return "|cff00ff00online|r" end
	if d < 3600 then return floor(d / 60) .. " min ago" end
	if d < 86400 then return floor(d / 3600) .. " h ago" end
	return floor(d / 86400) .. " days ago"
end

function Users:Create()
	if self.frame then return end
	local f = CreateFrame("Frame", "MythicBossRecordsUsers", UIParent, "BasicFrameTemplateWithInset")
	self.frame = f
	f:SetSize(330, 120 + NUM_ROWS * ROW_H - 40)
	f:SetPoint("CENTER")
	f:SetFrameStrata("HIGH")
	f:EnableMouse(true)
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:Hide()
	tinsert(UISpecialFrames, "MythicBossRecordsUsers")

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOP", 0, -5)
	title:SetText("Who has Mythic Boss Records")

	self.count = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	self.count:SetPoint("TOPLEFT", 14, -32)

	local heads = { { "Player", 12, 92, "LEFT" }, { "Guild", 106, 104, "LEFT" }, { "Ver.", 212, 34, "CENTER" }, { "Seen", 248, 54, "RIGHT" } }
	for _, h in ipairs(heads) do
		local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		fs:SetPoint("TOPLEFT", h[2], -52)
		fs:SetWidth(h[3]); fs:SetJustifyH(h[4]); fs:SetText(h[1])
	end
	local line = f:CreateTexture(nil, "ARTWORK")
	line:SetHeight(1)
	line:SetPoint("TOPLEFT", 10, -66)
	line:SetPoint("TOPRIGHT", -10, -66)
	line:SetColorTexture(1, 0.82, 0, 0.35)

	local sf = CreateFrame("ScrollFrame", "MythicBossRecordsUsersScroll", f, "FauxScrollFrameTemplate")
	sf:SetPoint("TOPLEFT", 8, -70)
	sf:SetPoint("BOTTOMRIGHT", -30, 10)
	sf:SetScript("OnVerticalScroll", function(s, offset)
		FauxScrollFrame_OnVerticalScroll(s, offset, ROW_H, function() Users:Update() end)
	end)
	self.scroll = sf

	self.rows = {}
	for i = 1, NUM_ROWS do
		local r = CreateFrame("Frame", nil, f)
		r:SetSize(290, ROW_H)
		r:SetPoint("TOPLEFT", 10, -70 - (i - 1) * ROW_H)
		local function fs(x, w, j)
			local t = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			t:SetPoint("LEFT", x, 0); t:SetWidth(w); t:SetJustifyH(j); t:SetWordWrap(false)
			return t
		end
		r.name, r.via, r.ver, r.seen = fs(2, 92, "LEFT"), fs(96, 104, "LEFT"), fs(202, 34, "CENTER"), fs(238, 54, "RIGHT")
		self.rows[i] = r
	end
end

function Users:Update()
	if not self.frame then return end
	local list = {}
	for _, u in pairs(db.users) do list[#list + 1] = u end
	table.sort(list, function(a, b)
		local oa, ob = self:IsOnline(a), self:IsOnline(b)
		if oa ~= ob then return oa end
		if (a.seen or 0) ~= (b.seen or 0) then return (a.seen or 0) > (b.seen or 0) end
		return (a.name or "") < (b.name or "")
	end)
	local n, on = self:Count()
	local mine = 0
	for _, u in ipairs(list) do if not self:IsOutsider(u) then mine = mine + 1 end end
	self.count:SetText(format("%d players, |cff00ff00%d online|r, %d from your guild", n, on, mine))
	FauxScrollFrame_Update(self.scroll, #list, NUM_ROWS, ROW_H)
	local offset = FauxScrollFrame_GetOffset(self.scroll)
	local mine = VersionNum(myVersion)
	for i, r in ipairs(self.rows) do
		local u = list[i + offset]
		if u then
			r.name:SetText(u.name or "?")
			r.name:SetTextColor(ns.ClassColor(u.class))
			local old = VersionNum(u.version) < mine
			r.ver:SetText((old and "|cffff6060" or "") .. (u.version or "?") .. (old and "|r" or ""))
			local outside = self:IsOutsider(u)
			r.via:SetText((u.guild and u.guild ~= "") and u.guild or "-")
			if outside then r.via:SetTextColor(0.85, 0.85, 0.85) else r.via:SetTextColor(0.25, 1, 0.25) end
			r.seen:SetText(Ago(u.seen))
			r:Show()
		else
			r:Hide()
		end
	end
end

function Users:Toggle()
	self:Create()
	if self.frame:IsShown() then self.frame:Hide(); return end
	self.frame:Show()
	self:Update()
	self:Announce(true) -- refresh: everyone online answers
end

-- ---------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------
local ev = CreateFrame("Frame")
Users.ev = ev
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
ev:SetScript("OnEvent", function(_, event, ...)
	if event == "CHAT_MSG_ADDON" then
		OnMessage(...)
	elseif event == "GROUP_ROSTER_UPDATE" then
		if not db or time() - lastGroupHello < 20 then return end
		lastGroupHello = time()
		C_Timer.After(2, function()
			local g = GroupDist()
			if g then Send(Msg(true), g) end
		end)
	elseif event == "PLAYER_LOGIN" then
		db = ns.db
		db.users = db.users or {}
		local cutoff = time() - KEEP_DAYS * 86400
		for k, u in pairs(db.users) do if (u.seen or 0) < cutoff then db.users[k] = nil end end
		myVersion = ns.VERSION
		myClass = select(2, UnitClass("player"))
		myKey = Key(UnitName("player"))
		if RegisterAddonMessagePrefix then RegisterAddonMessagePrefix(PREFIX) end
		-- the server-wide channel is joined a bit later (the client joins General / Trade first)
		C_Timer.After(10, JoinGlobal)
		C_Timer.After(15, function() Users:Announce(true) end)
		C_Timer.NewTicker(HEARTBEAT, function() JoinGlobal(); Users:Announce(false) end)
	end
end)
