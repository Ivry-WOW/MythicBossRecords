local ADDON, ns = ...

-- =====================================================================
--  Mythic Boss Records - Sync
--  Shares records between players who run the addon, like Gatherer:
--   * live: every new / updated record is sent to the guild and to online
--     friends right after the boss kill (and again when the key ends,
--     with the +1/+2/+3 result)
--   * catch-up: on login we say hello, someone answers, and we exchange
--     everything the other side got since our last sync (both directions)
--  Reaches the guild, online friends and - through a hidden server-wide chat
--  channel - everyone else on the server who runs the addon.
--  Blocked players (/mbr block) are always ignored.
--
--  Messages (prefix "MBR1", fields separated by "~"):
--   H~proto~count          hello (guild broadcast / whisper to friends)
--   I~proto~count          "I'm here" answer to a hello (whisper)
--   Q~proto~since          request: send me what you got since <since> (whisper)
--   R~...                  one record
--   D~proto~count          end of a catch-up stream
-- =====================================================================

local Sync = {}
ns.Sync = Sync

local PREFIX = "MBR1"
local PROTO = 1
local SEP = "~"
local CPS, BURST = 700, 2000     -- bytes/second we allow ourselves (server-friendly)
local HELLO_DELAY = 12           -- seconds after login before the first hello
local PEER_TIMEOUT = 30 * 60
local CHANNEL = "MBRSync"        -- hidden server-wide channel for the global sync

local floor, format, tostring, tonumber, pairs, ipairs = math.floor, string.format, tostring, tonumber, pairs, ipairs

local db, settings, state
local playerName
local guildies = {}   -- lower-case short name -> { name, class }
local friends = {}    -- lower-case short name -> online (bool)
local peers = {}      -- lower-case short name -> GetTime() last heard
local stats = { sent = 0, received = 0 }
local helloOpen, helloPeer = false, nil
local streamCount = {} -- sender -> records received in the current stream

local frame = CreateFrame("Frame")
Sync.frame = frame

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
local function Short(name)
	if not name then return nil end
	return (name:match("^([^%-]+)")) or name
end
local function Key(name) return name and Short(name):lower() end

local function Clean(s)
	s = tostring(s or "")
	return (s:gsub(SEP, ""):gsub("|", ""))
end

local function Num(v, dec)
	if v == nil then return "" end
	if dec then return format("%." .. dec .. "f", v) end
	return tostring(floor(v + 0.5))
end

local function RefreshGuild()
	wipe(guildies)
	if IsInGuild() then
		for i = 1, (GetNumGuildMembers()) or 0 do
			local name, _, _, _, _, _, _, _, online, _, classFile = GetGuildRosterInfo(i)
			if name then guildies[Key(name)] = { name = Short(name), class = classFile, online = online } end
		end
	end
end

-- the friend list is only read when friend sync is on (never refreshed / requested by us)
local function RefreshFriends()
	wipe(friends)
	if not (settings and settings.sync.friends) then return end
	for i = 1, (GetNumFriends()) or 0 do
		local name, _, _, _, connected = GetFriendInfo(i)
		if name then friends[Key(name)] = connected and true or false end
	end
end

local function GlobalOn() return settings and settings.sync.global ~= false end

local function Trusted(sender, channel)
	local k = Key(sender)
	if not k or k == playerName then return false end
	if settings.blocked[k] then return false end
	if channel == "GUILD" then return settings.sync.guild end
	if channel == "CHANNEL" then return GlobalOn() end
	if channel == "WHISPER" then
		-- with the global sync on, everyone running the addon may talk to us
		return GlobalOn() or (settings.sync.guild and guildies[k]) or (settings.sync.friends and friends[k] ~= nil) or false
	end
	return false
end

function Sync:Enabled()
	return settings and (settings.sync.guild or settings.sync.friends or GlobalOn())
end

-- ---------------------------------------------------------------------
-- Hidden server-wide channel (joined automatically, never shown in chat)
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
	if not GlobalOn() then return end
	if not ChannelID() then
		local join = JoinTemporaryChannel or JoinChannelByName
		if join then pcall(join, CHANNEL) end
	end
	HideChannel()
end

local function LeaveGlobal()
	if ChannelID() and LeaveChannelByName then pcall(LeaveChannelByName, CHANNEL) end
end

-- no "Joined channel: MBRSync" lines in the chat
if ChatFrame_AddMessageEventFilter then
	local function filter(_, _, _, _, _, _, _, _, _, _, channelName)
		if channelName and tostring(channelName):lower():find(CHANNEL:lower(), 1, true) then return true end
	end
	for _, ev in ipairs({ "CHAT_MSG_CHANNEL_NOTICE", "CHAT_MSG_CHANNEL_NOTICE_USER", "CHAT_MSG_CHANNEL_JOIN", "CHAT_MSG_CHANNEL_LEAVE", "CHAT_MSG_CHANNEL" }) do
		ChatFrame_AddMessageEventFilter(ev, filter)
	end
end

-- ---------------------------------------------------------------------
-- Send queue (throttled, so a big catch-up never floods the server)
-- ---------------------------------------------------------------------
local queue, qhead, qtail = {}, 1, 0
local budget, lastRefill = BURST, 0

local function Enqueue(msg, dist, target)
	qtail = qtail + 1
	queue[qtail] = { msg, dist, target }
end

local function Pump()
	local now = GetTime()
	budget = math.min(BURST, budget + (now - lastRefill) * CPS)
	lastRefill = now
	while qhead <= qtail do
		local q = queue[qhead]
		local cost = #q[1] + #PREFIX + 30
		if cost > budget then return end
		queue[qhead] = nil
		qhead = qhead + 1
		budget = budget - cost
		pcall(SendAddonMessage, PREFIX, q[1], q[2], q[3])
		stats.sent = stats.sent + 1
	end
end
Sync._pump = Pump

function Sync:QueueSize() return qtail - qhead + 1 end

-- to the guild + every online friend who is not already reached through the guild
local function Broadcast(msg)
	local inGuild = settings.sync.guild and IsInGuild()
	if inGuild then Enqueue(msg, "GUILD") end
	if settings.sync.friends then
		for k, online in pairs(friends) do
			if online and not (inGuild and guildies[k]) then Enqueue(msg, "WHISPER", k) end
		end
	end
	-- + the hidden server-wide channel (receivers recognise duplicates)
	if GlobalOn() then
		local id = ChannelID()
		if id then Enqueue(msg, "CHANNEL", tostring(id)) end
	end
end

-- ---------------------------------------------------------------------
-- Record encoding
-- R~encID~name~class~spec~dps~damage~duration~level~result~date~runTime~timeLimit~affixes~bossName~instance~tf
-- (tf = 9 Tyrannical / 10 Fortified week; older clients simply ignore it)
-- ---------------------------------------------------------------------
function Sync.Encode(encID, e)
	local known = ns.ENCOUNTER_INFO[encID]
	local meta = db.encounters[encID] or {}
	local aff = {}
	for i, a in ipairs(e.affixes or {}) do aff[i] = tostring(a) end
	return table.concat({
		"R", tostring(encID), Clean(e.name), Clean(e.class), tostring(e.spec or 0),
		Num(e.dps), Num(e.damage), Num(e.duration, 1), tostring(e.level or 0),
		e.result == nil and "" or tostring(e.result), tostring(e.date or 0),
		Num(e.runTime), Num(e.timeLimit), table.concat(aff, "."),
		known and "" or Clean(meta.name), known and "" or Clean(meta.instance),
		tostring(ns.RecordTF(e) or ""),
		"B", -- boss-only DPS (V.1.2+); records from older versions (all damage) are refused
		e.src == "logs" and "L" or (e.src == "log" and "O" or ""), -- L: built-in data pack, O: a player's own combat log
	}, SEP)
end

local function Split(msg)
	local f = {}
	for part in (msg .. SEP):gmatch("(.-)" .. SEP) do f[#f + 1] = part end
	return f
end

function Sync.Decode(msg)
	local f = Split(msg)
	if f[1] ~= "R" or #f < 14 then return end
	if f[18] ~= "B" then return end -- sent by an old version that also counted adds
	local encID, dps, date = tonumber(f[2]), tonumber(f[6]), tonumber(f[11])
	local level, result = tonumber(f[9]) or 0, tonumber(f[10])
	-- sanity checks: drop anything that cannot be a real record
	if not encID or not dps or not date or f[3] == "" then return end
	if not ns.CLASS_IDS[f[4]] then return end
	if dps <= 0 or dps > 5e7 or level < 0 or level > 40 then return end
	if result and (result < 0 or result > 3) then return end
	if date < 1.4e9 or date > time() + 2 * 86400 then return end
	local aff = {}
	for a in f[14]:gmatch("%d+") do aff[#aff + 1] = tonumber(a) end
	local e = {
		name = f[3], class = f[4], spec = tonumber(f[5]) or 0,
		dps = dps, damage = tonumber(f[7]), duration = tonumber(f[8]),
		level = level, result = result, date = date,
		runTime = tonumber(f[12]), timeLimit = tonumber(f[13]), affixes = aff,
	}
	if f[19] == "L" then e.logs = true elseif f[19] == "O" then e.oldlog = true end
	local tf = tonumber(f[17] or "")
	if tf == 9 or tf == 10 then e.tf = tf end
	return encID, e, f[15], f[16]
end

function Sync:GuildRoster() return guildies end

-- ---------------------------------------------------------------------
-- Outgoing
-- ---------------------------------------------------------------------
-- list = { { encID, entry }, ... } -> live broadcast
function Sync:Share(list)
	if not self:Enabled() or not list or #list == 0 then return end
	for _, it in ipairs(list) do
		if it[2].src ~= "logs" then Broadcast(Sync.Encode(it[1], it[2])) end
	end
end

-- everything we got (recorded or received) since <since>, whispered to <target>
-- withPack: the other side has older combat-log data than us -> send ours too
-- (so when one player gets a new data pack, it spreads to everyone through sync)
local function SendSince(target, since, withPack)
	local n = 0
	since = (since or 0) - 3600 -- margin for clock differences between PCs
	for encID, boss in pairs(db.records) do
		for _, list in pairs(boss) do
			for _, e in ipairs(list) do
				local send
				if e.src == "logs" then send = withPack
				else send = (e.seen or e.date or 0) >= since end
				if send then
					Enqueue(Sync.Encode(encID, e), "WHISPER", target)
					n = n + 1
				end
			end
		end
	end
	Enqueue(format("D%s%d%s%d%s%s", SEP, PROTO, SEP, n, SEP, withPack and ns.PackID() or ""), "WHISPER", target)
	return n
end

local peerPack = {}  -- peer -> the combat-log data pack they hold
local function Older(pack) return pack ~= nil and pack ~= "" and pack < ns.PackID() or (pack == "" and ns.PackID() ~= "") end

function Sync:Hello()
	if not self:Enabled() then return end
	RefreshGuild()
	RefreshFriends()
	helloOpen, helloPeer = true, nil
	Broadcast(format("H%s%d%s%d%s%s", SEP, PROTO, SEP, ns.CountRecords(), SEP, ns.PackID()))
	C_Timer.After(20, function() helloOpen = false end)
end

-- ---------------------------------------------------------------------
-- Incoming
-- ---------------------------------------------------------------------
local refreshPending = false
local function RefreshUISoon()
	if refreshPending then return end
	refreshPending = true
	C_Timer.After(1, function()
		refreshPending = false
		if ns.UI and ns.UI.OnNewData then ns.UI:OnNewData() end
	end)
end

local function OnRecord(msg, sender)
	local encID, e, bossName, inst = Sync.Decode(msg)
	if not encID then return end
	if not ns.ENCOUNTER_INFO[encID] and bossName and bossName ~= "" and not db.encounters[encID] then
		db.encounters[encID] = { name = bossName, instance = inst ~= "" and inst or nil }
	end
	e.src = (e.logs and "logs") or (e.oldlog and "log") or Short(sender)
	e.logs, e.oldlog = nil, nil
	e.seen = time()
	local status = ns.MergeRecord(encID, e)
	if status == "new" or status == "updated" then
		stats.received = stats.received + 1
		local k = Key(sender)
		if streamCount[k] then streamCount[k] = streamCount[k] + 1 end
		RefreshUISoon()
	end
end

function Sync:OnMessage(prefix, msg, channel, sender)
	if prefix ~= PREFIX or not settings then return end
	if not Trusted(sender, channel) then return end
	local k = Key(sender)
	-- anyone talking on the guild channel is a guild member, even if our roster is not refreshed yet
	if channel == "GUILD" and not guildies[k] then guildies[k] = { name = Short(sender) } end
	peers[k] = GetTime()
	local t = msg:sub(1, 1)

	if t == "R" then
		OnRecord(msg, sender)
	elseif t == "H" then
		local f = Split(msg)
		if tonumber(f[2]) ~= PROTO then return end
		peerPack[k] = f[4]
		-- answer after a random delay so 20 guildies don't all answer at once
		C_Timer.After(1 + math.random() * 4, function()
			Enqueue(format("I%s%d%s%d%s%s", SEP, PROTO, SEP, ns.CountRecords(), SEP, ns.PackID()), "WHISPER", sender)
		end)
	elseif t == "I" then
		local f = Split(msg)
		if tonumber(f[2]) ~= PROTO then return end
		peerPack[k] = f[4]
		if helloOpen and not helloPeer then
			-- first answer wins: pull from them, then push what they may be missing
			helloPeer = k
			streamCount[k] = 0
			local since = state.lastSync or 0
			-- whisper the full name: players from other realms need "Name-Realm"
			Enqueue(format("Q%s%d%s%d%s%s", SEP, PROTO, SEP, since, SEP, ns.PackID()), "WHISPER", sender)
			SendSince(sender, since, Older(peerPack[k]))
			state.lastSync = time()
		end
	elseif t == "Q" then
		local f = Split(msg)
		if tonumber(f[2]) ~= PROTO then return end
		streamCount[k] = streamCount[k] or 0
		SendSince(sender, tonumber(f[3]) or 0, Older(f[4]))
	elseif t == "D" then
		local f = Split(msg)
		local n = streamCount[k]
		streamCount[k] = nil
		-- the whole data pack arrived: we now hold (and pass on) that newer pack
		if f[4] and f[4] ~= "" and f[4] > ns.PackID() then
			db.packId = f[4]
			ns.Print(format("Got newer combat-log data from %s.", Short(sender)))
		end
		if n and n > 0 then
			ns.Print(format("Sync with %s done: |cff00ff00%d|r new / updated records.", Short(sender), n))
		end
	end
end

-- ---------------------------------------------------------------------
-- Status / commands
-- ---------------------------------------------------------------------
function Sync:OnlinePeers()
	local n, now = 0, GetTime()
	for _, t in pairs(peers) do
		if now - t < PEER_TIMEOUT then n = n + 1 end
	end
	return n
end

function Sync:StatusText()
	if not settings then return "" end
	local parts = {}
	if settings.sync.guild then parts[#parts + 1] = "Guild" end
	if settings.sync.friends then parts[#parts + 1] = "Friends" end
	if GlobalOn() then parts[#parts + 1] = ChannelID() and "Server" or "Server (joining)" end
	if #parts == 0 then return "Sync: |cffff4040off|r" end
	return format("Sync: |cff00ff00%s|r (%d online)", table.concat(parts, " + "), self:OnlinePeers())
end

local function OnOff(v) return v and "|cff00ff00ON|r" or "|cffff4040OFF|r" end

-- used by the settings panel
function Sync:SetOption(key, value)
	if key == "global" then
		settings.sync.global = value and true or false
		if value then JoinGlobal() else LeaveGlobal() end
	else
		settings.sync[key] = value and true or false
		if key == "friends" then RefreshFriends() end
		if key == "guild" then RefreshGuild() end
	end
	if ns.UI and ns.UI.Refresh then ns.UI:Refresh() end
end

function Sync:GetOption(key)
	if key == "global" then return GlobalOn() end
	return settings and settings.sync[key] and true or false
end

function Sync:Command(cmd, arg)
	local a = (arg or ""):match("^%s*(.-)%s*$")
	if cmd == "sync" then
		local sub = a:lower()
		if sub == "guild" then
			settings.sync.guild = not settings.sync.guild
			ns.Print("Guild sync: " .. OnOff(settings.sync.guild))
		elseif sub == "friends" then
			settings.sync.friends = not settings.sync.friends
			ns.Print("Friend list sync: " .. OnOff(settings.sync.friends))
		elseif sub == "global" or sub == "server" then
			settings.sync.global = not GlobalOn()
			if GlobalOn() then JoinGlobal() else LeaveGlobal() end
			ns.Print("Server-wide sync (everyone with the addon): " .. OnOff(GlobalOn()))
		elseif sub == "now" then
			self:Hello()
			ns.Print("Asking guild / friends / server for missing records...")
		else
			ns.Print(self:StatusText())
			ns.Print(format("Sent: %d messages | Received: %d records | Queue: %d",
				stats.sent, stats.received, self:QueueSize()))
			local b = {}
			for name in pairs(settings.blocked) do b[#b + 1] = name end
			if #b > 0 then ns.Print("Blocked: " .. table.concat(b, ", ")) end
			ns.Print("/mbr sync guild | friends | global | now")
		end
		if ns.UI and ns.UI.Refresh then ns.UI:Refresh() end
	elseif cmd == "block" or cmd == "unblock" then
		if a == "" then ns.Print("Usage: /mbr " .. cmd .. " Name"); return end
		settings.blocked[a:lower()] = (cmd == "block") or nil
		ns.Print((cmd == "block" and "Blocked: " or "Unblocked: ") .. a)
	elseif cmd == "purge" then
		if a == "" then ns.Print("Usage: /mbr purge Name"); return end
		local n = Sync:Purge(a)
		ns.Print(format("Deleted %d records received from %s.", n, a))
		if ns.UI and ns.UI.Refresh then ns.UI:Refresh() end
	end
end

-- delete every record that came from <name> through sync
function Sync:Purge(name)
	local k, n = name:lower(), 0
	for encID, boss in pairs(db.records) do
		for key, list in pairs(boss) do
			for i = #list, 1, -1 do
				if list[i].src and list[i].src:lower() == k then
					table.remove(list, i)
					n = n + 1
				end
			end
			if #list == 0 then boss[key] = nil end
		end
		if not next(boss) then db.records[encID] = nil end
	end
	return n
end

-- ---------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("GUILD_ROSTER_UPDATE")
frame:RegisterEvent("FRIENDLIST_UPDATE")

frame:SetScript("OnEvent", function(self, event, ...)
	if event == "CHAT_MSG_ADDON" then
		Sync:OnMessage(...)
	elseif event == "GUILD_ROSTER_UPDATE" then
		RefreshGuild()
	elseif event == "FRIENDLIST_UPDATE" then
		if settings and settings.sync.friends then RefreshFriends() end
	elseif event == "PLAYER_LOGIN" then
		db = ns.db
		settings = db.settings
		settings.sync = settings.sync or { guild = true, friends = false }
		-- friends are reached through the server channel; whispering them could upset the friend list
		if not settings.sync.friendsOffV13 then settings.sync.friends = false; settings.sync.friendsOffV13 = true end
		settings.blocked = settings.blocked or {}
		db.syncState = db.syncState or { lastSync = 0 }
		state = db.syncState
		playerName = Key(UnitName("player"))
		if RegisterAddonMessagePrefix then RegisterAddonMessagePrefix(PREFIX) end
		lastRefill = GetTime()
		C_Timer.NewTicker(0.2, Pump)
		if IsInGuild() and GuildRoster then GuildRoster() end
		-- the client joins General / Trade first; our channel comes a bit later
		C_Timer.After(HELLO_DELAY - 4, JoinGlobal)
		C_Timer.After(HELLO_DELAY, function() Sync:Hello() end)
		C_Timer.NewTicker(15 * 60, JoinGlobal) -- rejoin if the channel was left
	end
end)
