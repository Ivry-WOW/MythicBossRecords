local ADDON, ns = ...

-- Legion Mythic+ dungeons and their bosses (encounterID from ENCOUNTER_START).
-- Boss order = order in the dungeon. 3rd field = Encounter Journal portrait.
-- If the server sends an encounterID that is not listed here, the addon still saves it
-- and shows it under a separate category (the instance name), so nothing is lost.
ns.DUNGEONS = {
	{ name = "Eye of Azshara", cm = 197, button = "EyeofAzshara", short = "EoA", bosses = {
		{ 1810, "Warlord Parjesh", "Warlord Parjesh" },
		{ 1811, "Lady Hatecoil", "Lady Hatecoil" },
		{ 1812, "King Deepbeard", "King Deepbeard" },
		{ 1813, "Serpentrix", "Serpentrix" },
		{ 1814, "Wrath of Azshara", "Wrath of Azshara" },
	} },
	{ name = "Darkheart Thicket", cm = 198, button = "DarkheartThicket", short = "DHT", bosses = {
		{ 1836, "Archdruid Glaidalis", "Arch-Druid Glaidalis" },
		{ 1837, "Oakheart", "Oakheart" },
		{ 1838, "Dresaron", "Dresaron" },
		{ 1839, "Shade of Xavius", "Shade of Xavius" },
	} },
	{ name = "Neltharion's Lair", cm = 206, button = "NeltharionsLair", short = "NL", bosses = {
		{ 1790, "Rokmora", "Rokmora" },
		{ 1791, "Ularogg Cragshaper", "Ularogg Cragshaper" },
		{ 1792, "Naraxas", "Naraxas" },
		{ 1793, "Dargrul the Underking", "Dargrul the Underking" },
	} },
	{ name = "Halls of Valor", cm = 200, button = "HallsofValor", short = "HoV", bosses = {
		{ 1805, "Hymdall", "Hymdall" },
		{ 1806, "Hyrja", "Hyrja" },
		{ 1807, "Fenryr", "Fenryr" },
		{ 1808, "God-King Skovald", "God-King Skovald" },
		{ 1809, "Odyn", "Odyn" },
	} },
	{ name = "Vault of the Wardens", cm = 207, button = "VaultoftheWardens", short = "VotW", bosses = {
		{ 1815, "Tirathon Saltheril", "Tirathon Saltheril" },
		{ 1850, "Inquisitor Tormentorum", "Inquisitor Tormentorum" },
		{ 1816, "Ash'golm", "Ashgolm" },
		{ 1817, "Glazer", "Glazer" },
		{ 1818, "Cordana Felsong", "Cordana" },
	} },
	{ name = "Black Rook Hold", cm = 199, button = "BlackRookHold", short = "BRH", bosses = {
		{ 1832, "Amalgam of Souls", "The Amalgam of Souls" },
		{ 1833, "Illysanna Ravencrest", "Illysanna Ravencrest" },
		{ 1834, "Smashspite the Hateful", "Smashspite the Hateful" },
		{ 1835, "Lord Kur'talos Ravencrest", "Lord Kurtalos Ravencrest" },
	} },
	{ name = "Maw of Souls", cm = 208, button = "MawofSouls", short = "MoS", bosses = {
		{ 1822, "Ymiron, the Fallen King", "Ymiron the Fallen King" },
		{ 1823, "Harbaron", "Harbaron" },
		{ 1824, "Helya", "Helya" },
	} },
	{ name = "Court of Stars", cm = 210, button = "CourtofStars", short = "CoS", bosses = {
		{ 1868, "Patrol Captain Gerdo", "Patrol Captain Gerdo" },
		{ 1869, "Talixae Flamewreath", "Talixae Flamewreath" },
		{ 1870, "Advisor Melandrus", "Advisor Melandrus" },
	} },
	{ name = "The Arcway", cm = 209, button = "TheArcway", short = "Arc", bosses = {
		{ 1827, "Ivanyr", "Ivanyr" },
		{ 1825, "Corstilax", "Corstilax" },
		{ 1828, "General Xakal", "General Xakal" },
		{ 1826, "Nal'tira", "Naltira" },
		{ 1829, "Advisor Vandros", "Advisor Vandros" },
	} },
	{ name = "Lower Karazhan", cm = 227, button = "ReturntoKarazhan", short = "LKara", instance = "Return to Karazhan", bosses = {
		{ 1957, "Opera Hall", "Opera" },
		{ 1954, "Maiden of Virtue", "Maiden of Virtue" },
		{ 1960, "Attumen the Huntsman", "Attumen the Huntsman Legion" },
		{ 1961, "Moroes", "Moroes" },
	} },
	{ name = "Upper Karazhan", cm = 234, button = "ReturntoKarazhan", short = "UKara", instance = "Return to Karazhan", bosses = {
		{ 1964, "The Curator", "The Curator" },
		{ 1965, "Shade of Medivh", "Shade of Medivh" },
		{ 1959, "Mana Devourer", "Mana Devourer" },
		{ 2017, "Viz'aduum the Watcher", "Vizaduum the Watcher" },
	} },
	{ name = "Cathedral of Eternal Night", cm = 233, button = "CathedralOfEternalNight", short = "CoEN", bosses = {
		{ 2055, "Agronox", "Agronox" },
		{ 2057, "Thrashbite the Scornful", "ThrashbitetheScornful" },
		{ 2053, "Domatrax", "Default" },
		{ 2039, "Mephistroth", "Mephistroth" },
	} },
	{ name = "Seat of the Triumvirate", cm = 239, button = "SeatoftheTriumvirate", short = "Seat", bosses = {
		{ 2065, "Zuraal the Ascended", "ZuraaltheAscended" },
		{ 2066, "Saprish", "Saprish" },
		{ 2067, "Viceroy Nezhar", "ViceroyNezhar" },
		{ 2068, "L'ura", "Lura" },
	} },
}

ns.TEX_PATH = "Interface\\EncounterJournal\\"
function ns.DungeonButtonTexture(d)
	return ns.TEX_PATH .. "UI-EJ-DUNGEONBUTTON-" .. (d.button or "Default")
end
function ns.BossPortrait(b)
	return ns.TEX_PATH .. "UI-EJ-BOSS-" .. (b and b[3] or "Default")
end

-- challenge map ID (C_ChallengeMode) -> dungeon
ns.CM_INFO = {}
for _, d in ipairs(ns.DUNGEONS) do ns.CM_INFO[d.cm] = d end

-- encounterID -> dungeon, boss name
ns.ENCOUNTER_INFO = {}
for di, d in ipairs(ns.DUNGEONS) do
	for _, b in ipairs(d.bosses) do
		ns.ENCOUNTER_INFO[b[1]] = { dungeon = di, name = b[2] }
	end
end

ns.CLASS_ORDER = {
	"WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT",
	"SHAMAN", "MAGE", "WARLOCK", "MONK", "DRUID", "DEMONHUNTER",
}
