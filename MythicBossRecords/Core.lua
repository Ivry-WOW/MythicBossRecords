local ADDON, ns = ...

-- =====================================================================
--  Mythic Boss Records - Core
--  Measures the DPS of every group member between ENCOUNTER_START and
--  ENCOUNTER_END (kills only, Mythic+ keys only) and keeps the
--  top N records on every boss, per spec.
-- =====================================================================

local PREFIX = "|cfff5b937MBR|r: "
-- the version lives here (not only in the .toc: WoW reads the .toc only when the game starts,
-- so after replacing files + /reload it would still report the old one)
ns.VERSION = "1.6.3"
-- only keys of this level and higher count (live, sync, combat-log imports)
ns.MIN_LEVEL = 9
ns.ACCENT = { 0.96, 0.73, 0.22 }

local bit_band, bit_bor = bit.band, bit.bor
local GetTime, time, pairs, ipairs, wipe = GetTime, time, pairs, ipairs, wipe
local tinsert, tremove, format, floor = table.insert, table.remove, string.format, math.floor

local DEFAULTS = {
	maxPerSpec = 5,        -- how many records to keep per spec / boss
	announce = true,       -- chat message when YOU beat a record
	minimap = { angle = 215, hide = false },
}

local DIFF_MYTHIC_KEYSTONE = 8
local DIFF_MYTHIC = 23

local HOSTILE = COMBATLOG_OBJECT_REACTION_HOSTILE or 0x00000040
local MINE    = COMBATLOG_OBJECT_AFFILIATION_MINE or 0x00000001
local PETMASK = bit_bor(COMBATLOG_OBJECT_TYPE_PET or 0x00001000, COMBATLOG_OBJECT_TYPE_GUARDIAN or 0x00002000)

-- 1 = SWING (amount is the first extra arg), 2 = SPELL-like (amount is the 4th)
local DAMAGE_EVENTS = {
	SWING_DAMAGE = 1,
	RANGE_DAMAGE = 2,
	SPELL_DAMAGE = 2,
	SPELL_PERIODIC_DAMAGE = 2,
	SPELL_BUILDING_DAMAGE = 2,
	DAMAGE_SHIELD = 2,
}

local core = CreateFrame("Frame")
ns.core = core

local db
local fight            -- current fight (nil when not recording)
local group = {}       -- guid -> { name, class, unit }
local petOwner = {}    -- pet/guardian guid -> owner guid
local specCache = {}   -- player guid -> specID
local keyInfo = { level = 0, affixes = {} }
local playerGUID

-- ---------------------------------------------------------------------
-- Utilities
-- ---------------------------------------------------------------------
function ns.Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

function ns.FormatNumber(n)
	if not n then return "-" end
	if n >= 1e6 then return format("%.2fM", n / 1e6) end
	if n >= 1e3 then return format("%.1fk", n / 1e3) end
	return format("%d", n)
end

function ns.FormatTime(sec)
	sec = floor((sec or 0) + 0.5)
	return format("%d:%02d", floor(sec / 60), sec % 60)
end

function ns.FormatDate(t, long)
	if not t then return "-" end
	return date(long and "%d.%m.%Y %H:%M" or "%d.%m.%Y", t)
end

local specInfoCache = {}
function ns.SpecInfo(specID)
	if not specID or specID == 0 then return nil end
	local c = specInfoCache[specID]
	if not c then
		local id, name, _, icon, role, class = GetSpecializationInfoByID(specID)
		if not id then return nil end
		c = { name = name, icon = icon, role = role, class = class }
		specInfoCache[specID] = c
	end
	return c
end

function ns.AffixName(id)
	if C_ChallengeMode and C_ChallengeMode.GetAffixInfo then
		local name = C_ChallengeMode.GetAffixInfo(id)
		if name then return name end
	end
	return "Affix " .. tostring(id)
end

function ns.ClassColor(class)
	local c = (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS)[class or ""]
	if c then return c.r, c.g, c.b end
	return 0.8, 0.8, 0.8
end

function ns.ClassColorCode(class)
	local r, g, b = ns.ClassColor(class)
	return format("|cff%02x%02x%02x", floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5))
end

local function SpecKey(e)
	if e.spec and e.spec > 0 then return e.spec end
	return "C:" .. (e.class or "?")
end
ns.SpecKey = SpecKey

-- ---------------------------------------------------------------------
-- Tyrannical / Fortified
-- Every week is either Tyrannical (affix 9) or Fortified (10). Keys +10 and
-- higher carry it in their affixes; for lower keys it is the week's one.
-- ---------------------------------------------------------------------
local TYRANNICAL, FORTIFIED = 9, 10
ns.TYRANNICAL, ns.FORTIFIED = TYRANNICAL, FORTIFIED

local function TFOf(list)
	for _, a in ipairs(list or {}) do
		if a == TYRANNICAL or a == FORTIFIED then return a end
	end
end

function ns.TFName(tf)
	return tf == TYRANNICAL and "Tyrannical" or tf == FORTIFIED and "Fortified" or "unknown"
end

-- records with a known Tyrannical / Fortified: { date, firstAffix, tf }
local anchors
local function BuildAnchors()
	anchors = {}
	for _, boss in pairs(db.records) do
		for _, list in pairs(boss) do
			for _, e in ipairs(list) do
				local tf = e.tf or TFOf(e.affixes)
				if tf then anchors[#anchors + 1] = { e.date or 0, e.affixes and e.affixes[1], tf } end
			end
		end
	end
end

-- a key without +10 affixes: take it from a key of the same week
-- (same +4 affix, closest in time; the +4 affix tells the weeks apart)
function ns.InferTF(date, affixes)
	local tf = TFOf(affixes)
	if tf then return tf end
	if not anchors then BuildAnchors() end
	local first = affixes and affixes[1]
	local best, gap
	if first then
		for _, a in ipairs(anchors) do
			local g = math.abs(a[1] - date)
			if a[2] == first and g <= 7 * 86400 and (not gap or g < gap) then best, gap = a[3], g end
		end
	end
	if not best then
		for _, a in ipairs(anchors) do
			local g = math.abs(a[1] - date)
			if g <= 3 * 86400 and (not gap or g < gap) then best, gap = a[3], g end
		end
	end
	return best
end

function ns.RecordTF(e)
	if not e.tf then
		e.tf = ns.InferTF(e.date or 0, e.affixes)
		if e.tf and anchors then anchors[#anchors + 1] = { e.date or 0, e.affixes and e.affixes[1], e.tf } end
	end
	return e.tf
end

function ns.ResetTFCache() anchors = nil end

-- this week's Tyrannical / Fortified
function ns.CurrentTF()
	local tf = TFOf(keyInfo.affixes)
	if tf then return tf end
	if C_ChallengeMode and C_ChallengeMode.GetCurrentAffixes then
		local ok, list = pcall(C_ChallengeMode.GetCurrentAffixes)
		if ok and type(list) == "table" then
			local ids = {}
			for i, a in ipairs(list) do ids[i] = type(a) == "table" and (a.id or a[1]) or a end
			tf = TFOf(ids)
			if tf then return tf end
		end
	end
	return ns.InferTF(time(), keyInfo.affixes)
end

-- ---------------------------------------------------------------------
-- Database
-- ---------------------------------------------------------------------
-- Fresh start: everything recorded before this moment (06.10.2026 21:20) is
-- dropped once, and older records coming from other players are ignored.
local DATA_EPOCH = 1791312300 -- fresh start (boss-only DPS from V.1.2)
ns.DATA_EPOCH = DATA_EPOCH

local function InitDB()
	MythicBossRecordsDB = MythicBossRecordsDB or {}
	db = MythicBossRecordsDB
	db.version = 1
	if (db.epoch or 0) < DATA_EPOCH then
		db.records, db.encounters, db.importedPacks, db.activeRun = {}, {}, {}, nil
		db.syncState = { lastSync = 0 }
		db.epoch = DATA_EPOCH
		ns.freshStart = true
	end
	db.records = db.records or {}       -- [encounterID][specKey] = { entry, ... } sorted desc
	db.encounters = db.encounters or {} -- [encounterID] = { name, instance } (also for unknown bosses)
	db.settings = db.settings or {}
	for k, v in pairs(DEFAULTS) do
		if db.settings[k] == nil then
			if type(v) == "table" then
				local t = {}
				for kk, vv in pairs(v) do t[kk] = vv end
				db.settings[k] = t
			else
				db.settings[k] = v
			end
		end
	end
	ns.db = db
end

-- Adds a record; returns its position among the records of the same spec and
-- the same Tyrannical / Fortified (1 = best) or nil. Top N is kept for each of them.
function ns.AddRecord(encID, e)
	local boss = db.records[encID]
	if not boss then boss = {}; db.records[encID] = boss end
	local key = SpecKey(e)
	local list = boss[key]
	if not list then list = {}; boss[key] = list end
	local tf = ns.RecordTF(e)
	local max = db.settings.maxPerSpec or 5
	local better = 0
	for _, x in ipairs(list) do
		if ns.RecordTF(x) == tf and x.dps >= e.dps then better = better + 1 end
	end
	if better >= max then return nil end
	local pos = #list + 1
	for i = 1, #list do
		if e.dps > list[i].dps then pos = i; break end
	end
	tinsert(list, pos, e)
	ns.TrimList(list, max)
	return better + 1
end

-- keeps the best <max> of every Tyrannical / Fortified group (list sorted by dps)
function ns.TrimList(list, max)
	local count, i = {}, 1
	while i <= #list do
		local tf = ns.RecordTF(list[i]) or 0
		count[tf] = (count[tf] or 0) + 1
		if count[tf] > max then tremove(list, i) else i = i + 1 end
	end
end

function ns.DeleteRecord(encID, key, idx)
	local boss = db.records[encID]
	local list = boss and boss[key]
	if not list or not list[idx] then return end
	tremove(list, idx)
	if #list == 0 then boss[key] = nil end
	if not next(boss) then db.records[encID] = nil end
end

-- The same kill can reach us several times (our own recording + sync from
-- groupmates who also run the addon). Same boss + same player + kill time
-- within this window = the same kill.
local DUP_WINDOW = 300

function ns.FindDuplicate(encID, e)
	local boss = db.records[encID]
	if not boss then return end
	for key, list in pairs(boss) do
		for i, x in ipairs(list) do
			if x.name == e.name and math.abs((x.date or 0) - (e.date or 0)) <= DUP_WINDOW then
				return key, i, x
			end
		end
	end
end

-- Adds a record, or merges it into an existing copy of the same kill.
-- Returns status ("new" / "updated" / "dup" / nil = not good enough for top N), record
function ns.MergeRecord(encID, e)
	if (e.level or 0) < ns.MIN_LEVEL then return nil end -- only +9 keys and higher
	-- from before the fresh start (the built-in pack from old combat logs is boss-only too, so it stays)
	if e.src ~= "logs" and e.src ~= "log" and (e.date or 0) < DATA_EPOCH then return nil end
	e.seen = e.seen or time()
	local key, idx, x = ns.FindDuplicate(encID, e)
	if not x then
		local pos = ns.AddRecord(encID, e)
		return pos and "new" or nil, e, pos
	end

	-- the incoming copy knows the spec and ours doesn't: replace ours
	if (not x.spec or x.spec == 0) and e.spec and e.spec > 0 then
		ns.DeleteRecord(encID, key, idx)
		if e.result == nil then e.result, e.runTime, e.timeLimit = x.result, x.runTime, x.timeLimit end
		e.mine = e.mine or x.mine
		e.run = e.run or x.run
		e.src = (e.mine and nil) or e.src or x.src
		e.seen = time()
		local pos = ns.AddRecord(encID, e)
		return pos and "updated" or nil, e, pos
	end

	local changed = false
	if x.result == nil and e.result ~= nil then
		x.result, x.runTime, x.timeLimit = e.result, e.runTime, e.timeLimit
		changed = true
	end
	if e.dps > x.dps * 1.001 then
		-- combat log range differs per client; keep the most complete measurement
		x.dps, x.damage, x.duration = e.dps, e.damage, e.duration
		local list = db.records[encID][key]
		table.sort(list, function(a, b) return a.dps > b.dps end)
		changed = true
	end
	if (not x.affixes or #x.affixes == 0) and e.affixes and #e.affixes > 0 then x.affixes = e.affixes end
	if not x.tf and e.tf then x.tf = e.tf end
	if e.mine then x.mine = true; x.src = nil end
	if e.own then x.own = true end -- also in your own combat log
	if e.run and not x.run then x.run = e.run end
	if changed then x.seen = time() end
	return changed and "updated" or "dup", x
end

-- Historical records shipped with the addon (ImportData.lua, made from old
-- combat logs). Merged once per pack, duplicates are skipped.
-- Your own combat log, read on your PC by "MBR Tools.cmd" (LocalLogData.lua).
-- New records are shared with everyone (src "log": passed on by everyone who gets them).
function ns.ApplyLocalPack()
	local pack = ns.LOCAL_PACK
	ns.LOCAL_PACK = nil
	if not pack or not pack.records then return end
	db.importedPacks = db.importedPacks or {}
	-- V.1.6.2: read the pack once more so fights you already had from others count as yours too
	if db.importedPacks[pack.id] and db.ownMarkV162 then return end
	db.ownMarkV162 = true
	local me, now, n, share = UnitName("player"), time(), 0, {}
	local kept = 0
	for _, r in ipairs(pack.records) do
		local aff = {}
		for a in (r[13] or ""):gmatch("%d+") do aff[#aff + 1] = tonumber(a) end
		local e = {
			name = r[2], class = r[3], spec = r[4], dps = r[5], damage = r[6], duration = r[7],
			level = r[8], result = (r[9] >= 0) and r[9] or nil, date = r[10],
			runTime = (r[11] >= 0) and r[11] or nil, timeLimit = (r[12] >= 0) and r[12] or nil,
			affixes = aff, tf = (r[14] and r[14] > 0) and r[14] or nil, src = "log", seen = now,
			mine = (r[2] == me) or nil, own = true,
		}
		local status, rec = ns.MergeRecord(r[1], e)
		if status then kept = kept + 1 end
		if status == "new" or status == "updated" then
			n = n + 1
			share[#share + 1] = { r[1], rec }
		end
	end
	db.importedPacks[pack.id] = now
	db.localPackId = pack.id
	if n > 0 then
		ns.Print(format("Your combat log: |cff00ff00%d|r new records - sharing them with everyone.", n))
		if ns.Sync then C_Timer.After(20, function() ns.Sync:Share(share) end) end
	end
	if n == 0 and kept > 0 then
		ns.Print(format("Your combat log: |cff00ff00%d|r records, all already known. Sync logs sends them again.", kept))
	end
end

-- records that came from your own combat log (to share them again with the Sync logs button)
function ns.OwnLogRecords()
	local list = {}
	for encID, boss in pairs(db.records) do
		for _, l in pairs(boss) do
			for _, e in ipairs(l) do
				if e.own then list[#list + 1] = { encID, e } end
			end
		end
	end
	return list
end

-- newest combat-log data this client holds (shipped with the addon or received through sync)
function ns.PackID() return db and db.packId or "" end

function ns.ApplyImportPack()
	local pack = ns.IMPORT_PACK
	if not pack or not pack.records then return end
	db.importedPacks = db.importedPacks or {}
	-- skipped only if already merged AND the data is still there (e.g. not after a reset)
	if pack.id > (db.packId or "") then db.packId = pack.id end
	if db.importedPacks[pack.id] and ns.CountRecords() > 0 then ns.IMPORT_PACK = nil; return end
	local me = UnitName("player")
	local n = 0
	for _, r in ipairs(pack.records) do
		local aff = {}
		for a in (r[13] or ""):gmatch("%d+") do aff[#aff + 1] = tonumber(a) end
		local e = {
			name = r[2], class = r[3], spec = r[4], dps = r[5], damage = r[6], duration = r[7],
			level = r[8], result = (r[9] >= 0) and r[9] or nil, date = r[10],
			runTime = (r[11] >= 0) and r[11] or nil, timeLimit = (r[12] >= 0) and r[12] or nil,
			affixes = aff, tf = (r[14] and r[14] > 0) and r[14] or nil, src = "logs", seen = r[10],
			mine = (r[2] == me) or nil,
		}
		local status = ns.MergeRecord(r[1], e)
		if status == "new" or status == "updated" then n = n + 1 end
	end
	db.importedPacks[pack.id] = time()
	if pack.id > (db.packId or "") then db.packId = pack.id end
	ns.IMPORT_PACK = nil
	if n > 0 then
		ns.Print(format("Imported |cff00ff00%d|r records from old combat logs.", n))
	end
end

-- records below the minimum key level (saved by older versions) are removed
function ns.DropLowKeys()
	local n = 0
	for encID, boss in pairs(db.records) do
		for key, list in pairs(boss) do
			for i = #list, 1, -1 do
				if (list[i].level or 0) < ns.MIN_LEVEL then tremove(list, i); n = n + 1 end
			end
			if #list == 0 then boss[key] = nil end
		end
		if not next(boss) then db.records[encID] = nil end
	end
	if n > 0 then ns.ResetTFCache() end
	return n
end

function ns.PruneAll()
	local max = db.settings.maxPerSpec or 5
	for _, boss in pairs(db.records) do
		for _, list in pairs(boss) do ns.TrimList(list, max) end
	end
end

function ns.CountRecords()
	local n = 0
	for _, boss in pairs(db.records) do
		for _, list in pairs(boss) do n = n + #list end
	end
	return n
end

-- Highest DPS on a boss (any spec)
-- Highest DPS on a boss; tf = only that week type (Tyrannical / Fortified)
function ns.BossBest(encID, tf)
	local boss = db.records[encID]
	if not boss then return nil end
	local best
	for _, list in pairs(boss) do
		for _, e in ipairs(list) do
			if (not tf or ns.RecordTF(e) == tf) and (not best or e.dps > best.dps) then best = e end
		end
	end
	return best
end

-- the week type the tops follow: this week's (Tyrannical when unknown)
function ns.TopTF() return ns.CurrentTF() or ns.TYRANNICAL end

ns.CLASS_IDS = {
	WARRIOR = 1, PALADIN = 2, HUNTER = 3, ROGUE = 4, PRIEST = 5, DEATHKNIGHT = 6,
	SHAMAN = 7, MAGE = 8, WARLOCK = 9, MONK = 10, DRUID = 11, DEMONHUNTER = 12,
}

-- Per-class summary for a boss: class -> { count, best }
-- per class: count of records, best of the given week type (tf) and best overall
function ns.GetClassSummary(encID, tf)
	local out = {}
	local boss = db.records[encID]
	if not boss then return out end
	for _, list in pairs(boss) do
		for _, e in ipairs(list) do
			local c = out[e.class]
			if not c then c = { count = 0 }; out[e.class] = c end
			c.count = c.count + 1
			if not c.any or e.dps > c.any.dps then c.any = e end
			if (not tf or ns.RecordTF(e) == tf) and (not c.best or e.dps > c.best.dps) then c.best = e end
		end
	end
	return out
end

-- Specs of a class (in game order)
function ns.ClassSpecs(class)
	local specs = {}
	local classID = ns.CLASS_IDS[class]
	if classID and GetNumSpecializationsForClassID then
		for i = 1, GetNumSpecializationsForClassID(classID) do
			local id = GetSpecializationInfoForClassID(classID, i)
			if id then specs[#specs + 1] = id end
		end
	end
	return specs
end

-- Rows shown for a class on a boss:
-- { header = specID/key } followed by
-- { tyr = entry/nil, fort = entry/nil, tyrRank, fortRank } (Tyrannical left, Fortified right)
-- or { empty = true }. Records whose week is unknown are shown with the Tyrannical ones.
function ns.GetClassRows(encID, class)
	local rows = {}
	local boss = db.records[encID] or {}
	local seen = {}
	local function addSpec(key)
		seen[key] = true
		rows[#rows + 1] = { header = key }
		local tyr, fort = {}, {}
		for _, e in ipairs(boss[key] or {}) do
			if ns.RecordTF(e) == FORTIFIED then fort[#fort + 1] = e else tyr[#tyr + 1] = e end
		end
		local n = math.max(#tyr, #fort)
		if n == 0 then
			rows[#rows + 1] = { empty = true }
		end
		for i = 1, n do
			rows[#rows + 1] = { tyr = tyr[i], fort = fort[i], rank = i, key = key }
		end
	end
	for _, specID in ipairs(ns.ClassSpecs(class)) do addSpec(specID) end
	-- records with unknown spec (party member could not be inspected)
	local unk = "C:" .. class
	if boss[unk] then addSpec(unk) end
	-- any other spec of the class not listed above
	for key, list in pairs(boss) do
		if not seen[key] and list[1] and list[1].class == class then addSpec(key) end
	end
	return rows
end

-- Dungeon list for the UI: static ones + unknown instances
function ns.GetDungeonList()
	local list = {}
	for i, d in ipairs(ns.DUNGEONS) do list[i] = d end
	local extra = {}
	for encID, info in pairs(db.encounters) do
		if not ns.ENCOUNTER_INFO[encID] and db.records[encID] then
			local inst = info.instance or "Other"
			local d = extra[inst]
			if not d then
				d = { name = inst, short = inst, bosses = {}, dynamic = true }
				extra[inst] = d
				list[#list + 1] = d
			end
			d.bosses[#d.bosses + 1] = { encID, info.name or ("Boss " .. encID) }
		end
	end
	return list
end


-- ---------------------------------------------------------------------
-- Group, pets, specs
-- ---------------------------------------------------------------------
local function PetUnitFor(unit)
	if unit == "player" then return "pet" end
	local n = unit:match("%d+")
	if unit:find("^party") then return "partypet" .. n end
	return "raidpet" .. n
end

local function UpdatePlayerSpec()
	playerGUID = playerGUID or UnitGUID("player")
	local idx = GetSpecialization()
	if idx then
		local id = GetSpecializationInfo(idx)
		if id and id > 0 then specCache[playerGUID] = id end
	end
end

local function UpdateRoster()
	wipe(group)
	local function add(unit)
		local guid = UnitGUID(unit)
		if not guid or not UnitIsPlayer(unit) then return end
		local _, class = UnitClass(unit)
		group[guid] = { name = GetUnitName(unit, true) or UnitName(unit), class = class, unit = unit }
		local pguid = UnitGUID(PetUnitFor(unit))
		if pguid then petOwner[pguid] = guid end
	end
	if IsInRaid() then
		for i = 1, GetNumGroupMembers() do add("raid" .. i) end
	else
		add("player")
		for i = 1, GetNumSubgroupMembers() do add("party" .. i) end
	end
end

-- Inspect (for party member specs), throttled
local inspectQueue, inspectPending, lastInspect = {}, nil, 0

local function QueueInspects()
	for guid, info in pairs(group) do
		if info.unit ~= "player" and not specCache[guid] then
			inspectQueue[guid] = true
		end
	end
end

local function ProcessInspect()
	if inspectPending and GetTime() - lastInspect < 4 then return end
	inspectPending = nil
	if InspectFrame and InspectFrame:IsShown() then return end
	for guid in pairs(inspectQueue) do
		local info = group[guid]
		if not info or specCache[guid] then
			inspectQueue[guid] = nil
		elseif UnitGUID(info.unit) == guid and UnitIsConnected(info.unit) and UnitIsVisible(info.unit) and CanInspect(info.unit) then
			NotifyInspect(info.unit)
			inspectPending = guid
			lastInspect = GetTime()
			return
		end
	end
end

local function OnInspectReady(guid)
	local info = group[guid]
	if info and UnitGUID(info.unit) == guid then
		local spec = GetInspectSpecialization(info.unit)
		if spec and spec > 0 then
			specCache[guid] = spec
			inspectQueue[guid] = nil
		end
	end
	if guid == inspectPending then
		inspectPending = nil
		if not (InspectFrame and InspectFrame:IsShown()) then ClearInspectPlayer() end
	end
end

-- ---------------------------------------------------------------------
-- Active key
-- ---------------------------------------------------------------------
local function UpdateKeyInfo()
	keyInfo.level, keyInfo.affixes = 0, {}
	if C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo then
		local level, affixes = C_ChallengeMode.GetActiveKeystoneInfo()
		if level and level > 0 then
			keyInfo.level = level
			if type(affixes) == "table" then
				for i, a in ipairs(affixes) do keyInfo.affixes[i] = a end
			end
		end
	end
end

-- ---------------------------------------------------------------------
-- Combat log (7.3.5: arguments are passed straight to the handler)
-- ---------------------------------------------------------------------
-- Encounters whose boss units have other names than the encounter
local EXTRA_BOSS_NAMES = {
	["lord kur'talos ravencrest"] = { "kur'talos ravencrest", "latosius", "dantalionax" },
	["dargrul the underking"] = { "dargrul" },
	["ilysanna ravencrest"] = { "illysanna ravencrest" },
	["saprish"] = { "darkfang", "shadewing" },
	["opera hall"] = { "toe knee", "mrrgria", "elfyra", "galindre", "wikket", "winnie", "phyllis" },
	["attumen the huntsman"] = { "midnight" },
}

-- Only damage done to the boss counts (no adds). A unit is a boss if it is one of
-- the boss1..boss5 units of the encounter, or carries the encounter's name.
local function IsBoss(guid, name)
	local f = fight
	if f.bossGUIDs[guid] then return true end
	if name and f.bossNames[name:lower()] then
		f.bossGUIDs[guid] = true
		return true
	end
	return false
end

local function UpdateBossUnits()
	if not fight then return end
	for i = 1, 5 do
		local u = "boss" .. i
		local guid = UnitGUID(u)
		if guid then
			fight.bossGUIDs[guid] = true
			local n = UnitName(u)
			if n then fight.bossNames[n:lower()] = true end
		end
	end
end

local function OnCombatLog(_, subevent, _, srcGUID, _, srcFlags, _, dstGUID, dstName, dstFlags, _, ...)
	if subevent == "SPELL_SUMMON" then
		if srcGUID and dstGUID then
			if group[srcGUID] then
				petOwner[dstGUID] = srcGUID
			elseif petOwner[srcGUID] then
				petOwner[dstGUID] = petOwner[srcGUID]
			end
		end
		return
	end

	if not fight then return end
	local kind = DAMAGE_EVENTS[subevent]
	if not kind then return end
	if bit_band(dstFlags or 0, HOSTILE) == 0 then return end

	local owner
	if group[srcGUID] then
		owner = srcGUID
	else
		owner = petOwner[srcGUID]
		if not owner and srcFlags and bit_band(srcFlags, PETMASK) ~= 0 and bit_band(srcFlags, MINE) ~= 0 then
			owner = playerGUID
			petOwner[srcGUID] = owner
		end
	end
	if not owner then return end

	local amount, overkill
	if kind == 1 then
		amount, overkill = ...
	else
		local _, _, _, a, o = ...
		amount, overkill = a, o
	end
	if not amount then return end
	if overkill and overkill > 0 then amount = amount - overkill end
	if amount <= 0 then return end

	-- everything is kept as a fallback (server without boss units / unknown names)
	local all = fight.allDamage
	all[owner] = (all[owner] or 0) + amount
	if IsBoss(dstGUID, dstName) then
		local d = fight.damage
		d[owner] = (d[owner] or 0) + amount
		fight.bossHit = true
	end
end

-- ---------------------------------------------------------------------
-- Encounter
-- ---------------------------------------------------------------------
-- Current key run: kills are linked to it, and at the end
-- (CHALLENGE_MODE_COMPLETED) we fill in the result: +1/+2/+3 or depleted.
local function StartRun()
	UpdateKeyInfo()
	if keyInfo.level <= 0 then return end
	local _, _, _, _, _, _, _, instMapID = GetInstanceInfo()
	db.activeRun = { id = time(), level = keyInfo.level, instMapID = instMapID }
end

local function EnsureRun()
	local r = db.activeRun
	local _, _, _, _, _, _, _, instMapID = GetInstanceInfo()
	if not r or r.level ~= keyInfo.level or r.instMapID ~= instMapID or (time() - r.id) > 4 * 3600 then
		StartRun()
	end
	return db.activeRun
end

local function ForEachRunEntry(runID, fn)
	for encID, boss in pairs(db.records) do
		for _, list in pairs(boss) do
			for _, e in ipairs(list) do
				if e.run == runID then fn(e, encID) end
			end
		end
	end
end

local function OnChallengeCompleted()
	if not C_ChallengeMode.GetCompletionInfo then return end
	local mapID, level, timeMs, onTime, upgrades = C_ChallengeMode.GetCompletionInfo()
	local result = onTime and (upgrades or 1) or 0

	local r = db.activeRun
	if not r then return end
	local timeLimit
	if mapID and C_ChallengeMode.GetMapInfo then
		local _, _, tl = C_ChallengeMode.GetMapInfo(mapID)
		timeLimit = tl
	end
	local n, share = 0, {}
	local now = time()
	ForEachRunEntry(r.id, function(e, encID)
		e.result = result
		e.runTime = timeMs and timeMs / 1000 or nil
		e.timeLimit = timeLimit
		e.seen = now
		n = n + 1
		share[#share + 1] = { encID, e }
	end)
	db.activeRun = nil
	if ns.Sync then ns.Sync:Share(share) end
	if n > 0 then
		ns.Print(format("Key completed: %s - %d records updated.",
			result > 0 and ("|cff00ff00+" .. result .. "|r") or "|cffff4040Depleted|r", n))
	end
	if ns.UI and ns.UI.Refresh then ns.UI:Refresh() end
end

-- Text + color for the key result
-- result: nil = in progress / unfinished, 0 = depleted, 1-3 = upgrade
function ns.ResultText(e)
	if e.level == 0 then return "M0", 0.5, 0.5, 0.5 end
	if e.result == nil then return "?", 0.5, 0.5, 0.5 end
	if e.result == 0 then return "Depleted", 1, 0.25, 0.2 end
	return "+" .. e.result, 0.1, 1, 0.1
end

local function OnEncounterStart(encID, encName, difficultyID)
	UpdateKeyInfo()
	UpdateRoster()
	UpdatePlayerSpec()
	QueueInspects()

	local isKey = (difficultyID == DIFF_MYTHIC_KEYSTONE) or keyInfo.level > 0
	if not isKey or keyInfo.level < ns.MIN_LEVEL then fight = nil; return end

	local instName = GetInstanceInfo()
	local members = {}
	for guid, info in pairs(group) do members[guid] = { name = info.name, class = info.class } end
	local affixes = {}
	for i, a in ipairs(keyInfo.affixes) do affixes[i] = a end

	fight = {
		id = encID,
		name = encName,
		instance = instName,
		start = GetTime(),
		level = keyInfo.level,
		affixes = affixes,
		tf = ns.CurrentTF(),
		members = members,
		damage = {},     -- damage to the boss only
		allDamage = {},  -- damage to everything (fallback)
		bossGUIDs = {},
		bossNames = { [(encName or ""):lower()] = true },
	}
	-- the Encounter Journal name too (it can differ from the encounter name)
	local known = ns.ENCOUNTER_INFO[encID]
	if known and known.name then fight.bossNames[known.name:lower()] = true end
	for n in pairs(fight.bossNames) do
		for _, x in ipairs(EXTRA_BOSS_NAMES[n] or {}) do fight.bossNames[x] = true end
	end
	UpdateBossUnits()
	if isKey then
		local r = EnsureRun()
		fight.run = r and r.id
	end
end

local function OnEncounterEnd(encID, encName, difficultyID, groupSize, success)
	local f = fight
	fight = nil
	if not f or f.id ~= encID then return end
	if success ~= 1 then return end

	local duration = GetTime() - f.start
	if duration < 5 then return end
	UpdatePlayerSpec()
	-- no hit on a recognised boss unit at all: fall back to all damage
	if not f.bossHit then f.damage = f.allDamage end

	local meta = db.encounters[encID] or {}
	meta.name = (ns.ENCOUNTER_INFO[encID] and ns.ENCOUNTER_INFO[encID].name) or encName or meta.name
	meta.instance = f.instance or meta.instance
	db.encounters[encID] = meta

	local now = time()
	local newBest, saved, share = {}, 0, {}
	for guid, dmg in pairs(f.damage) do
		local info = f.members[guid] or group[guid]
		if info then
			local e = {
				name = info.name,
				class = info.class,
				spec = specCache[guid] or 0,
				dps = dmg / duration,
				damage = dmg,
				duration = duration,
				level = f.level,
				affixes = f.affixes,
				tf = f.tf,
				date = now,
				run = f.run,
				dungeon = f.instance,
				mine = (guid == playerGUID) or nil,
			}
			local status, rec, pos = ns.MergeRecord(encID, e)
			if status == "new" or status == "updated" then
				saved = saved + 1
				share[#share + 1] = { encID, rec }
				if pos == 1 then newBest[#newBest + 1] = rec end
			end
		end
	end

	if db.settings.announce then
		for _, e in ipairs(newBest) do
			if e.mine then
				local si = ns.SpecInfo(e.spec)
				ns.Print(format("|cff00ff00New record!|r %s%s|r %s on |cffffffff%s|r: |cffffd100%s DPS|r (+%d)",
					ns.ClassColorCode(e.class), si and si.name or e.class, e.name, meta.name or "?",
					ns.FormatNumber(e.dps), e.level))
			end
		end
	end

	if ns.Sync then ns.Sync:Share(share) end
	if ns.UI and ns.UI.OnNewData then ns.UI:OnNewData(encID) end
end

-- ---------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------
core:RegisterEvent("ADDON_LOADED")
core:RegisterEvent("PLAYER_LOGIN")
core:RegisterEvent("PLAYER_ENTERING_WORLD")
core:RegisterEvent("GROUP_ROSTER_UPDATE")
core:RegisterEvent("UNIT_PET")
core:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
core:RegisterEvent("INSPECT_READY")
core:RegisterEvent("ENCOUNTER_START")
core:RegisterEvent("ENCOUNTER_END")
core:RegisterEvent("INSTANCE_ENCOUNTER_ENGAGE_UNIT")
core:RegisterEvent("CHALLENGE_MODE_START")
core:RegisterEvent("CHALLENGE_MODE_COMPLETED")
core:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

core:SetScript("OnEvent", function(self, event, ...)
	if event == "COMBAT_LOG_EVENT_UNFILTERED" then
		OnCombatLog(...)
	elseif event == "ADDON_LOADED" then
		if ... == ADDON then InitDB() end
	elseif event == "PLAYER_LOGIN" then
		playerGUID = UnitGUID("player")
		ns.DropLowKeys()
		ns.ApplyImportPack()
		ns.ApplyLocalPack()
		if ns.freshStart then ns.Print("Fresh start: old records cleared, collecting new ones from now on.") end
		db.runs, db.siteNewest, db.playerClass = nil, nil, nil -- old weekly-panel data (moved to Guild Weekly Best)
		UpdatePlayerSpec()
		UpdateRoster()
		C_Timer.NewTicker(1, ProcessInspect)
		if ns.UI and ns.UI.OnLogin then ns.UI:OnLogin() end
	elseif event == "PLAYER_ENTERING_WORLD" or event == "GROUP_ROSTER_UPDATE" or event == "UNIT_PET" then
		UpdateRoster()
		QueueInspects()
	elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
		local unit = ...
		if unit == "player" or not unit then
			UpdatePlayerSpec()
		else
			local guid = UnitGUID(unit)
			if guid then specCache[guid] = nil; inspectQueue[guid] = true end
		end
	elseif event == "INSPECT_READY" then
		OnInspectReady(...)
	elseif event == "CHALLENGE_MODE_START" then
		StartRun()
		UpdateRoster()
		QueueInspects()
	elseif event == "CHALLENGE_MODE_COMPLETED" then
		OnChallengeCompleted()
	elseif event == "ENCOUNTER_START" then
		OnEncounterStart(...)
	elseif event == "INSTANCE_ENCOUNTER_ENGAGE_UNIT" then
		UpdateBossUnits() -- a new boss unit appeared (second boss, phase 2...)
	elseif event == "ENCOUNTER_END" then
		OnEncounterEnd(...)
	end
end)

-- for tests / debugging
ns._state = function() return fight, group, petOwner, specCache, keyInfo end

-- ---------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------
StaticPopupDialogs["MBR_RESET"] = {
	text = "Delete |cffff4040ALL|r Mythic Boss Records data?",
	button1 = YES, button2 = NO,
	OnAccept = function()
		wipe(db.records); wipe(db.encounters)
		db.importedPacks = {}
		ns.ResetTFCache()
		ns.Print("All records have been deleted. The built-in database (old logs) comes back after /reload.")
		if ns.UI and ns.UI.Refresh then ns.UI:Refresh() end
	end,
	timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

local function OnOff(v) return v and "|cff00ff00ON|r" or "|cffff4040OFF|r" end

SLASH_MYTHICBOSSRECORDS1 = "/mbr"
SLASH_MYTHICBOSSRECORDS2 = "/mythicrecords"
SlashCmdList.MYTHICBOSSRECORDS = function(msg)
	msg = (msg or ""):match("^%s*(.-)%s*$")
	local cmd, arg = msg:match("^(%S*)%s*(.*)$")
	cmd = cmd:lower()
	local s = db.settings
	if cmd == "" or cmd == "show" then
		ns.UI:Toggle()
	elseif cmd == "reset" then
		StaticPopup_Show("MBR_RESET")
	elseif cmd == "minimap" then
		s.minimap.hide = not s.minimap.hide
		ns.UI:UpdateMinimapButton()
		ns.Print("Minimap button: " .. OnOff(not s.minimap.hide))
	elseif cmd == "announce" then
		s.announce = not s.announce
		ns.Print("Announce new records in chat: " .. OnOff(s.announce))
	elseif cmd == "top" then
		local n = tonumber(arg)
		if n and n >= 1 and n <= 25 then
			s.maxPerSpec = floor(n)
			ns.PruneAll()
			ns.Print("Records kept per spec / boss: " .. s.maxPerSpec)
			ns.UI:Refresh()
		else
			ns.Print("Usage: /mbr top 1-25 (current: " .. s.maxPerSpec .. ")")
		end
	elseif cmd == "status" then
		UpdateKeyInfo()
		ns.Print(format("Active key: %s | Recording now: %s",
			keyInfo.level > 0 and ("+" .. keyInfo.level) or "no",
			fight and ("|cff00ff00" .. (fight.name or "?") .. "|r") or "no"))
		ns.Print(format("Boss records: |cff00ff00%d|r | This week: %s | %s", ns.CountRecords(),
			ns.TFName(ns.CurrentTF()), ns.Sync:StatusText()))
	elseif cmd == "reimport" then
		db.importedPacks = {}
		ns.Print("Built-in database will be merged again (no duplicates). Type |cffffd100/reload|r now.")
	elseif cmd == "settings" or cmd == "config" or cmd == "options" then
		ns.Options:Open()
	elseif cmd == "users" then
		ns.Users:Toggle()
	elseif cmd == "sync" or cmd == "block" or cmd == "unblock" or cmd == "purge" then
		ns.Sync:Command(cmd, arg)
	else
		ns.Print("Commands:")
		ns.Print("  /mbr - open / close the window")
		ns.Print("  /mbr top N - records kept per spec (current " .. s.maxPerSpec .. ")")
		ns.Print("  /mbr announce - announce new records (" .. OnOff(s.announce) .. ")")
		ns.Print("  /mbr minimap - show / hide the minimap button")
		ns.Print("  /mbr settings - settings window (sync, chat, minimap...)")
		ns.Print("  /mbr users - who has the addon (name, guild, version, last seen)")
		ns.Print("  /mbr status - active key, recording state and how much data is loaded")
		ns.Print("  /mbr reimport - merge the built-in database again (then /reload)")
		ns.Print("  /mbr sync - sync status | /mbr sync guild | friends | global | now")
		ns.Print("  /mbr block Name / unblock Name - ignore a player's shared data")
		ns.Print("  /mbr purge Name - delete every record received from that player")
		ns.Print("  /mbr reset - delete everything")
	end
end
