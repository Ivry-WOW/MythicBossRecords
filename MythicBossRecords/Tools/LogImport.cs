// Mythic Boss Records - combat log importer (C#, compiled on the fly by MBR-Tools.ps1).
// Reads WoWCombatLog.txt (only the part not read before), finds every Mythic+ boss kill
// of a +9 key or higher, measures each group member's DPS on the boss only (pets included,
// no adds), works out the spec from the spells used, the key result and the
// Tyrannical / Fortified week, and writes LocalLogData.lua for the addon.
// Same rules as the importer used for the addon's built-in data.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

public static class MBRLogImport
{
	public const int MIN_LEVEL = 9;
	const int TOP_PER_SPEC = 10;
	const double MIN_DURATION = 5;
	const int HOSTILE = 0x40;
	const int PETMASK = 0x1000 | 0x2000;
	const string HOME_REALM = "evermoon";
	const int TYRANNICAL = 9, FORTIFIED = 10;
	const int KARAZHAN = 1651;
	static readonly HashSet<int> LOWER_KARA = new HashSet<int> { 1957, 1954, 1960, 1961 };
	const int KARA_LOWER = 2340, KARA_UPPER = 2100;

	static readonly Dictionary<string, string[]> EXTRA_BOSS_NAMES = new Dictionary<string, string[]> {
		{ "lord kur'talos ravencrest", new string[] { "kur'talos ravencrest", "latosius", "dantalionax" } },
		{ "dargrul the underking", new string[] { "dargrul" } },
		{ "ilysanna ravencrest", new string[] { "illysanna ravencrest" } },
		{ "saprish", new string[] { "darkfang", "shadewing" } },
		{ "opera hall", new string[] { "toe knee", "mrrgria", "elfyra", "galindre", "wikket", "winnie", "phyllis" } },
		{ "attumen the huntsman", new string[] { "midnight" } },
	};
	static readonly HashSet<string> DAMAGE_EVENTS = new HashSet<string> { "SPELL_DAMAGE", "SPELL_PERIODIC_DAMAGE",
		"SWING_DAMAGE", "RANGE_DAMAGE", "DAMAGE_SHIELD", "SPELL_BUILDING_DAMAGE" };
	static readonly HashSet<string> EVIDENCE_EVENTS = new HashSet<string> { "SPELL_AURA_APPLIED", "SPELL_AURA_REFRESH",
		"SPELL_HEAL", "SPELL_ENERGIZE", "SPELL_PERIODIC_HEAL", "SPELL_CAST_SUCCESS" };

	// signature spells -> spec (generated from spec_spells.py)
	static readonly Dictionary<int, int[]> SPEC_SPELLS = new Dictionary<int, int[]> {
		{53, new int[] {261}},
		{116, new int[] {64}},
		{120, new int[] {64}},
		{133, new int[] {63}},
		{139, new int[] {257}},
		{172, new int[] {265}},
		{348, new int[] {267}},
		{498, new int[] {65}},
		{596, new int[] {257}},
		{603, new int[] {266}},
		{703, new int[] {259}},
		{740, new int[] {105}},
		{772, new int[] {71}},
		{845, new int[] {71}},
		{871, new int[] {73}},
		{980, new int[] {265}},
		{1064, new int[] {264}},
		{1122, new int[] {267}},
		{1160, new int[] {73}},
		{1329, new int[] {259}},
		{1449, new int[] {62}},
		{1680, new int[] {71}},
		{1719, new int[] {72}},
		{1943, new int[] {259}},
		{2050, new int[] {257}},
		{2060, new int[] {257}},
		{2061, new int[] {257}},
		{2098, new int[] {260}},
		{2120, new int[] {63}},
		{2565, new int[] {73}},
		{2948, new int[] {63}},
		{5143, new int[] {62}},
		{5217, new int[] {103}},
		{5308, new int[] {72}},
		{5394, new int[] {264}},
		{5740, new int[] {267}},
		{6343, new int[] {73}},
		{6572, new int[] {73}},
		{6807, new int[] {104}},
		{7384, new int[] {71}},
		{8042, new int[] {262}},
		{8092, new int[] {258}},
		{11366, new int[] {63}},
		{12042, new int[] {62}},
		{12051, new int[] {62}},
		{12294, new int[] {71}},
		{12472, new int[] {64}},
		{12975, new int[] {73}},
		{13750, new int[] {260}},
		{13877, new int[] {260}},
		{15407, new int[] {258}},
		{17364, new int[] {263}},
		{17877, new int[] {267}},
		{17962, new int[] {267}},
		{19434, new int[] {254}},
		{19574, new int[] {253}},
		{20243, new int[] {73}},
		{20473, new int[] {65}},
		{23881, new int[] {72}},
		{23922, new int[] {73}},
		{26573, new int[] {66}},
		{27243, new int[] {265}},
		{29722, new int[] {267}},
		{30108, new int[] {265}},
		{30451, new int[] {62}},
		{30455, new int[] {64}},
		{31687, new int[] {64}},
		{31707, new int[] {64}},
		{31821, new int[] {65}},
		{31850, new int[] {66}},
		{31935, new int[] {66}},
		{32379, new int[] {258}},
		{32645, new int[] {259}},
		{33076, new int[] {257}},
		{33206, new int[] {256}},
		{33763, new int[] {105}},
		{33891, new int[] {105}},
		{34026, new int[] {253}},
		{34861, new int[] {257}},
		{34914, new int[] {258}},
		{42650, new int[] {252}},
		{44425, new int[] {62}},
		{44457, new int[] {63}},
		{44614, new int[] {64}},
		{46924, new int[] {72}},
		{47536, new int[] {256}},
		{47540, new int[] {256}},
		{47541, new int[] {252}},
		{47568, new int[] {251}},
		{47585, new int[] {258}},
		{47788, new int[] {257}},
		{48045, new int[] {258}},
		{48181, new int[] {265}},
		{48438, new int[] {105}},
		{49020, new int[] {251}},
		{49028, new int[] {250}},
		{49143, new int[] {251}},
		{49184, new int[] {251}},
		{49206, new int[] {252}},
		{49998, new int[] {250}},
		{50842, new int[] {250}},
		{51271, new int[] {251}},
		{51533, new int[] {263}},
		{51690, new int[] {260}},
		{51723, new int[] {259}},
		{52610, new int[] {103}},
		{53385, new int[] {70}},
		{53563, new int[] {65}},
		{53600, new int[] {66}},
		{55090, new int[] {252}},
		{55233, new int[] {250}},
		{60103, new int[] {263}},
		{61295, new int[] {264}},
		{61336, new int[] {104}},
		{61882, new int[] {262}},
		{62618, new int[] {256}},
		{63106, new int[] {265}},
		{63560, new int[] {252}},
		{64843, new int[] {257}},
		{73920, new int[] {264}},
		{77472, new int[] {264}},
		{77575, new int[] {252}},
		{78675, new int[] {102}},
		{79140, new int[] {259}},
		{79206, new int[] {264}},
		{80240, new int[] {267}},
		{80313, new int[] {104}},
		{81269, new int[] {105}},
		{82326, new int[] {65}},
		{84714, new int[] {64}},
		{85222, new int[] {65}},
		{85256, new int[] {70}},
		{85288, new int[] {72}},
		{85948, new int[] {252}},
		{86659, new int[] {66}},
		{88625, new int[] {257}},
		{98008, new int[] {264}},
		{100130, new int[] {72}},
		{102342, new int[] {105}},
		{102351, new int[] {105}},
		{102543, new int[] {103}},
		{102558, new int[] {104}},
		{102560, new int[] {102}},
		{104316, new int[] {266}},
		{105174, new int[] {266}},
		{106785, new int[] {103}},
		{106830, new int[] {103}},
		{106951, new int[] {103}},
		{108280, new int[] {264}},
		{108853, new int[] {63}},
		{111898, new int[] {266}},
		{113656, new int[] {269}},
		{114014, new int[] {261}},
		{114050, new int[] {262}},
		{114051, new int[] {263}},
		{114052, new int[] {264}},
		{114165, new int[] {65}},
		{115080, new int[] {269}},
		{115151, new int[] {270}},
		{115175, new int[] {270}},
		{115181, new int[] {268}},
		{115203, new int[] {268}},
		{115308, new int[] {268}},
		{115310, new int[] {270}},
		{116670, new int[] {270}},
		{116847, new int[] {268}},
		{116849, new int[] {270}},
		{116858, new int[] {267}},
		{118000, new int[] {72}},
		{118038, new int[] {71}},
		{119582, new int[] {268}},
		{120360, new int[] {253}},
		{120679, new int[] {253}},
		{121253, new int[] {268}},
		{121471, new int[] {261}},
		{122470, new int[] {269}},
		{123986, new int[] {269}},
		{124081, new int[] {270}},
		{124682, new int[] {270}},
		{129250, new int[] {256}},
		{130736, new int[] {252}},
		{131894, new int[] {253}},
		{132578, new int[] {268}},
		{137619, new int[] {260}},
		{137639, new int[] {269}},
		{145205, new int[] {105}},
		{152108, new int[] {267}},
		{152173, new int[] {269}},
		{152175, new int[] {269}},
		{152277, new int[] {71}},
		{152279, new int[] {251}},
		{153561, new int[] {63}},
		{153626, new int[] {62}},
		{155835, new int[] {104}},
		{156910, new int[] {65}},
		{157153, new int[] {264}},
		{157695, new int[] {266}},
		{157981, new int[] {63}},
		{157997, new int[] {64}},
		{162243, new int[] {577}},
		{162794, new int[] {577}},
		{163201, new int[] {71}},
		{167105, new int[] {71}},
		{178740, new int[] {581}},
		{183998, new int[] {65}},
		{184092, new int[] {66}},
		{184364, new int[] {72}},
		{184367, new int[] {72}},
		{184575, new int[] {70}},
		{184662, new int[] {70}},
		{185313, new int[] {261}},
		{185358, new int[] {254}},
		{185438, new int[] {261}},
		{185763, new int[] {260}},
		{185855, new int[] {255}},
		{185901, new int[] {254}},
		{186270, new int[] {255}},
		{186289, new int[] {255}},
		{186387, new int[] {254}},
		{187708, new int[] {255}},
		{187827, new int[] {581}},
		{187874, new int[] {263}},
		{188196, new int[] {262}},
		{188443, new int[] {262}},
		{188499, new int[] {577}},
		{189110, new int[] {581}},
		{190319, new int[] {63}},
		{190356, new int[] {64}},
		{190411, new int[] {72}},
		{190456, new int[] {73}},
		{190778, new int[] {251}},
		{190928, new int[] {255}},
		{191034, new int[] {102}},
		{191427, new int[] {577}},
		{191433, new int[] {255}},
		{191634, new int[] {262}},
		{191837, new int[] {270}},
		{192222, new int[] {262}},
		{192759, new int[] {259}},
		{193315, new int[] {260}},
		{193316, new int[] {260}},
		{193396, new int[] {266}},
		{193440, new int[] {266}},
		{193455, new int[] {253}},
		{193526, new int[] {254}},
		{193530, new int[] {253}},
		{193786, new int[] {263}},
		{193796, new int[] {263}},
		{194223, new int[] {102}},
		{194407, new int[] {255}},
		{194466, new int[] {63}},
		{194509, new int[] {256}},
		{194679, new int[] {250}},
		{194855, new int[] {255}},
		{194913, new int[] {251}},
		{194918, new int[] {252}},
		{195072, new int[] {577}},
		{195182, new int[] {250}},
		{195292, new int[] {250}},
		{195452, new int[] {261}},
		{195457, new int[] {260}},
		{195676, new int[] {62}},
		{196098, new int[] {265}},
		{196277, new int[] {266}},
		{196447, new int[] {267}},
		{196586, new int[] {267}},
		{196770, new int[] {251}},
		{196819, new int[] {261}},
		{196834, new int[] {263}},
		{197214, new int[] {263}},
		{197721, new int[] {105}},
		{197835, new int[] {261}},
		{197995, new int[] {264}},
		{198013, new int[] {577}},
		{198067, new int[] {262}},
		{198590, new int[] {265}},
		{198670, new int[] {254}},
		{198793, new int[] {577}},
		{198898, new int[] {270}},
		{198929, new int[] {63}},
		{199754, new int[] {260}},
		{199786, new int[] {64}},
		{199804, new int[] {260}},
		{200174, new int[] {258}},
		{200183, new int[] {257}},
		{200652, new int[] {65}},
		{200806, new int[] {259}},
		{200829, new int[] {256}},
		{200851, new int[] {104}},
		{201078, new int[] {255}},
		{201427, new int[] {577}},
		{201467, new int[] {577}},
		{201897, new int[] {263}},
		{202028, new int[] {103}},
		{202060, new int[] {103}},
		{202168, new int[] {73}},
		{202273, new int[] {70}},
		{202347, new int[] {102}},
		{202425, new int[] {102}},
		{202665, new int[] {260}},
		{202767, new int[] {102}},
		{202768, new int[] {102}},
		{202770, new int[] {102}},
		{202771, new int[] {102}},
		{202800, new int[] {255}},
		{203415, new int[] {255}},
		{203524, new int[] {73}},
		{203720, new int[] {581}},
		{203782, new int[] {581}},
		{204018, new int[] {66}},
		{204019, new int[] {66}},
		{204021, new int[] {581}},
		{204066, new int[] {104}},
		{204147, new int[] {254}},
		{204197, new int[] {256}},
		{204596, new int[] {581}},
		{204883, new int[] {257}},
		{204945, new int[] {263}},
		{205021, new int[] {64}},
		{205032, new int[] {62}},
		{205065, new int[] {258}},
		{205145, new int[] {266}},
		{205179, new int[] {265}},
		{205223, new int[] {250}},
		{205273, new int[] {70}},
		{205320, new int[] {269}},
		{205406, new int[] {270}},
		{205448, new int[] {258}},
		{205495, new int[] {262}},
		{205523, new int[] {268}},
		{205545, new int[] {72}},
		{205636, new int[] {102}},
		{206491, new int[] {577}},
		{206817, new int[] {254}},
		{206930, new int[] {250}},
		{207068, new int[] {253}},
		{207230, new int[] {251}},
		{207317, new int[] {252}},
		{207385, new int[] {105}},
		{207407, new int[] {581}},
		{207778, new int[] {264}},
		{207946, new int[] {256}},
		{208065, new int[] {257}},
		{208253, new int[] {105}},
		{209202, new int[] {66}},
		{209577, new int[] {71}},
		{209782, new int[] {261}},
		{209795, new int[] {581}},
		{210152, new int[] {577}},
		{210191, new int[] {70}},
		{210714, new int[] {262}},
		{210722, new int[] {103}},
		{211714, new int[] {266}},
		{211881, new int[] {577}},
		{212084, new int[] {581}},
		{212283, new int[] {261}},
		{212431, new int[] {254}},
		{213652, new int[] {66}},
		{213757, new int[] {70}},
		{213771, new int[] {104}},
		{214202, new int[] {65}},
		{214326, new int[] {268}},
		{214579, new int[] {254}},
		{214621, new int[] {256}},
		{214634, new int[] {64}},
		{215661, new int[] {70}},
		{216698, new int[] {265}},
		{217020, new int[] {70}},
		{217200, new int[] {253}},
		{218164, new int[] {268}},
		{220143, new int[] {252}},
		{221699, new int[] {250}},
		{223306, new int[] {65}},
		{224668, new int[] {70}},
		{224968, new int[] {62}},
		{227847, new int[] {71}},
		{228260, new int[] {258}},
		{228266, new int[] {258}},
		{228477, new int[] {581}},
		{228920, new int[] {73}},
		{231895, new int[] {70}},
		{232698, new int[] {258}},
		{245388, new int[] {259}},
		{246287, new int[] {256}},
		{247454, new int[] {581}},
		{248621, new int[] {71}},
		{261947, new int[] {269}},
		{274837, new int[] {103}},
		{279302, new int[] {251}}
	};
	static readonly Dictionary<int, string> SPEC_CLASS = new Dictionary<int, string> { {62, "MAGE"}, {63, "MAGE"}, {64, "MAGE"}, {65, "PALADIN"}, {66, "PALADIN"}, {70, "PALADIN"}, {71, "WARRIOR"}, {72, "WARRIOR"}, {73, "WARRIOR"}, {102, "DRUID"}, {103, "DRUID"}, {104, "DRUID"}, {105, "DRUID"}, {250, "DEATHKNIGHT"}, {251, "DEATHKNIGHT"}, {252, "DEATHKNIGHT"}, {253, "HUNTER"}, {254, "HUNTER"}, {255, "HUNTER"}, {256, "PRIEST"}, {257, "PRIEST"}, {258, "PRIEST"}, {259, "ROGUE"}, {260, "ROGUE"}, {261, "ROGUE"}, {262, "SHAMAN"}, {263, "SHAMAN"}, {264, "SHAMAN"}, {265, "WARLOCK"}, {266, "WARLOCK"}, {267, "WARLOCK"}, {268, "MONK"}, {269, "MONK"}, {270, "MONK"}, {577, "DEMONHUNTER"}, {581, "DEMONHUNTER"} };
	static readonly HashSet<string> PET_CLASSES = new HashSet<string> { "DEATHKNIGHT", "DRUID", "HUNTER", "MAGE", "MONK", "PRIEST", "SHAMAN", "WARLOCK" };
	// key timers (instance id -> seconds); Karazhan (1651) is handled apart
	static readonly Dictionary<int, int> TIMERS = new Dictionary<int, int> { {1456, 2100}, {1466, 1800}, {1458, 1980}, {1477, 2700}, {1493, 1980}, {1501, 2340}, {1492, 1440}, {1571, 1800}, {1516, 2700} };


	// ------------------------------------------------------------------
	class Seg { public int Id; public double Start; public int Inst; public int Level; public List<int> Affixes = new List<int>();
		public double RunTime; public bool Done; public bool Started; }
	class Fight { public int Enc; public string Name; public double Start, End; public int Seg;
		public Dictionary<string, double> Dmg = new Dictionary<string, double>(), AllDmg = new Dictionary<string, double>(),
			Unowned = new Dictionary<string, double>(), AllUnowned = new Dictionary<string, double>();
		public HashSet<string> Members = new HashSet<string>(); public HashSet<string> BossNames = new HashSet<string>();
		public bool BossHit; }
	public class Rec { public int Enc; public string Name; public string Cls; public int Spec; public double Dps, Damage, Duration;
		public int Level; public int Result = -1; public long Date; public double RunTime = -1; public int Limit = -1;
		public string Affixes = ""; public int Tf = -1; }

	static void Add(Dictionary<string, double> d, string k, double v) { double o; d.TryGetValue(k, out o); d[k] = o + v; }
	static void Count(Dictionary<string, Dictionary<int, int>> d, string k, int id) {
		Dictionary<int, int> c; if (!d.TryGetValue(k, out c)) { c = new Dictionary<int, int>(); d[k] = c; }
		int o; c.TryGetValue(id, out o); c[id] = o + 1;
	}

	// splits "a,"b,c",d" like the Python importer: quoted strings stay whole, empty fields are skipped
	static List<string> Tokens(string s, int from) {
		var t = new List<string>();
		int i = from, n = s.Length;
		while (i < n) {
			if (s[i] == ',') { i++; continue; }
			if (s[i] == '"') {
				int j = s.IndexOf('"', i + 1); if (j < 0) j = n - 1;
				t.Add(s.Substring(i, j - i + 1)); i = j + 1;
			} else {
				int j = s.IndexOf(',', i); if (j < 0) j = n;
				t.Add(s.Substring(i, j - i)); i = j;
			}
		}
		return t;
	}
	static int Hex(string s) { s = s.Trim(); if (s.StartsWith("0x")) s = s.Substring(2); int v; int.TryParse(s, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out v); return v; }
	static int Int(string s) { int v; int.TryParse(s.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out v); return v; }
	static long Long(string s) { long v; long.TryParse(s.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out v); return v; }
	static string Unquote(string s) { return s.Trim().Trim('"'); }

	static string NormName(string raw) {
		raw = Unquote(raw);
		int dash = raw.IndexOf('-');
		if (dash < 0) return raw;
		string n = raw.Substring(0, dash), realm = raw.Substring(dash + 1);
		if (realm.ToLowerInvariant() == HOME_REALM) return n;
		return n + "-" + (realm.Length > 0 ? realm.Substring(0, 1).ToUpperInvariant() + realm.Substring(1) : realm);
	}

	// ------------------------------------------------------------------
	class Parser {
		public int EndYear, EndMonth;
		public List<Fight> Fights = new List<Fight>();
		public List<Seg> Segs = new List<Seg>();
		public Seg Seg; public Fight Fight;
		public Dictionary<string, string> PetOwner = new Dictionary<string, string>();
		public Dictionary<string, Dictionary<int, int>> Casts = new Dictionary<string, Dictionary<int, int>>();    // seg|guid
		public Dictionary<string, Dictionary<int, int>> CastsAll = new Dictionary<string, Dictionary<int, int>>(); // guid
		public Dictionary<string, string> Names = new Dictionary<string, string>();
		public Dictionary<string, Dictionary<string, int>> PetEvidence = new Dictionary<string, Dictionary<string, int>>();
		public long SafePos;   // byte position from where a later run can safely continue

		public double Ts(string d, string t) {
			int slash = d.IndexOf('/');
			int mo = Int(d.Substring(0, slash)), da = Int(d.Substring(slash + 1));
			int year = mo <= EndMonth ? EndYear : EndYear - 1;
			string[] p = t.Split(':');
			double sec = double.Parse(p[2], CultureInfo.InvariantCulture);
			var dt = new DateTime(year, mo, da, Int(p[0]), Int(p[1]), (int)sec, (int)((sec % 1) * 1000), DateTimeKind.Local);
			return (dt.ToUniversalTime() - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
		}

		void NewSeg(double ts, int inst, int level, List<int> aff, bool started) {
			Seg = new Seg { Id = Segs.Count, Start = ts, Inst = inst, Level = level, Started = started };
			if (aff != null) Seg.Affixes = aff;
			Segs.Add(Seg);
		}

		public void Feed(string line, long lineStart, long lineEnd) {
			int sp = line.IndexOf("  ", StringComparison.Ordinal);
			if (sp < 0) return;
			int comma = line.IndexOf(',', sp + 2);
			if (comma < 0) return;
			string ev = line.Substring(sp + 2, comma - sp - 2);
			Fight f = Fight;

			if (DAMAGE_EVENTS.Contains(ev)) {
				if (f == null) return;
				var tok = Tokens(line, comma + 1);
				if (tok.Count < 12) return;
				string src = tok[0];
				int sflags = Hex(tok[2]);
				if ((sflags & 0x7) == 0 || (Hex(tok[6]) & HOSTILE) == 0) return;
				double amount = Long(tok[tok.Count - 9]); double over = Long(tok[tok.Count - 8]);
				if (over > 0) amount -= over;
				if (amount <= 0) return;
				string tname = Unquote(tok[5]).ToLowerInvariant();
				bool boss = f.BossNames.Contains(tname);
				if (boss) f.BossHit = true;
				string owner;
				if (src.StartsWith("Player-")) {
					owner = src;
					if (!Names.ContainsKey(src)) Names[src] = tok[1];
				} else {
					PetOwner.TryGetValue(src, out owner);
					if (owner == null && ev == "SWING_DAMAGE" && tok.Count > 10 && tok[9].StartsWith("Player-")) {
						owner = tok[9]; PetOwner[src] = owner;
					}
					if (owner == null) {
						Add(f.AllUnowned, src, amount);
						if (boss) Add(f.Unowned, src, amount);
						return;
					}
				}
				Add(f.AllDmg, owner, amount);
				if (boss) Add(f.Dmg, owner, amount);
				f.Members.Add(owner);
				return;
			}

			if (EVIDENCE_EVENTS.Contains(ev)) {
				if (Seg == null && f == null) return;
				var tok = Tokens(line, comma + 1);
				if (tok.Count < 9) return;
				string src = tok[0], dst = tok[4];
				if (src.StartsWith("Player-")) {
					if (ev == "SPELL_CAST_SUCCESS" && (Hex(tok[2]) & 0x7) != 0) {
						int sid = Int(tok[8]);
						Count(Casts, (Seg != null ? Seg.Id : -1) + "|" + src, sid);
						Count(CastsAll, src, sid);
						if (!Names.ContainsKey(src)) Names[src] = tok[1];
					} else if (!dst.StartsWith("Player-") && dst != "0000000000000000" && (Hex(tok[6]) & PETMASK) != 0) {
						Dictionary<string, int> c;
						if (!PetEvidence.TryGetValue(dst, out c)) { c = new Dictionary<string, int>(); PetEvidence[dst] = c; }
						int o; c.TryGetValue(src, out o); c[src] = o + 1;
					}
				}
				return;
			}

			if (ev == "SPELL_SUMMON") {
				var tok = Tokens(line, comma + 1);
				if (tok.Count < 5) return;
				string src = tok[0], dst = tok[4];
				string o;
				if (src.StartsWith("Player-")) PetOwner[dst] = src;
				else if (PetOwner.TryGetValue(src, out o)) PetOwner[dst] = o;
				return;
			}

			if (ev == "ENCOUNTER_START" || ev == "ENCOUNTER_END" || ev == "CHALLENGE_MODE_START" || ev == "CHALLENGE_MODE_END") {
				string head = line.Substring(0, sp);
				int blank = head.IndexOf(' ');
				double ts = Ts(head.Substring(0, blank), head.Substring(blank + 1));
				var tok = Tokens(line, comma + 1);
				if (ev == "ENCOUNTER_START") {
					if (tok.Count < 3 || Int(tok[2]) != 8) { Fight = null; return; }
					if (Seg == null || Seg.Done) NewSeg(ts, 0, 0, null, false);   // log started in the middle of a key
					string name = Unquote(tok[1]);
					var nf = new Fight { Enc = Int(tok[0]), Name = name, Start = ts, Seg = Seg.Id };
					nf.BossNames.Add(name.ToLowerInvariant());
					string[] extra;
					if (EXTRA_BOSS_NAMES.TryGetValue(name.ToLowerInvariant(), out extra)) foreach (var x in extra) nf.BossNames.Add(x);
					Fight = nf;
				} else if (ev == "ENCOUNTER_END") {
					if (f != null && tok.Count >= 5 && Int(tok[0]) == f.Enc) {
						if (Int(tok[4]) == 1 && ts - f.Start >= MIN_DURATION) { f.End = ts; Fights.Add(f); }
					}
					Fight = null;
				} else if (ev == "CHALLENGE_MODE_START") {
					// everything before a new key is complete: a later run can start here
					if (Seg == null || Seg.Done) SafePos = lineStart;
					var aff = new List<int>();
					int lb = line.LastIndexOf('[');
					if (lb >= 0) foreach (Match m in Regex.Matches(line.Substring(lb), "\\d+")) aff.Add(Int(m.Value));
					NewSeg(ts, tok.Count > 1 ? Int(tok[1]) : 0, tok.Count > 3 ? Int(tok[3]) : 0, aff, true);
				} else {
					if (tok.Count < 4) return;
					int inst = Int(tok[0]), success = Int(tok[1]), level = Int(tok[2]); long ms = Long(tok[3]);
					var s = Seg;
					if (s != null && !s.Done) {
						if (success == 1 && level > 0 && ms > 0) {
							if (s.Inst == 0) s.Inst = inst;
							if (s.Level == 0) s.Level = level;
							s.RunTime = ms / 1000.0;
							if (!s.Started) s.Start = ts - ms / 1000.0;
						}
						s.Done = true;
					}
					SafePos = lineEnd;
				}
			}
		}
	}

	// ------------------------------------------------------------------
	static int DetectSpec(Dictionary<int, int> counts, out int s1, out int s2) {
		s1 = 0; s2 = 0;
		if (counts == null) return 0;
		var score = new Dictionary<int, int>();
		foreach (var kv in counts) {
			int[] specs;
			if (SPEC_SPELLS.TryGetValue(kv.Key, out specs)) foreach (var sp in specs) { int o; score.TryGetValue(sp, out o); score[sp] = o + kv.Value; }
		}
		int best = 0;
		foreach (var kv in score) {
			if (kv.Value > s1 || (kv.Value == s1 && kv.Key < best)) { s2 = s1; s1 = kv.Value; best = kv.Key; }
			else if (kv.Value > s2) s2 = kv.Value;
		}
		return best;
	}

	static void ResultFor(Seg seg, List<int> encs, out int result, out int limit) {
		result = -1; limit = -1;
		if (!seg.Done || seg.RunTime <= 0) return;
		int lim;
		if (seg.Inst == KARAZHAN) {
			bool lower = false; foreach (var e in encs) if (LOWER_KARA.Contains(e)) lower = true;
			lim = lower ? KARA_LOWER : KARA_UPPER;
		} else if (!TIMERS.TryGetValue(seg.Inst, out lim)) return;
		limit = lim;
		double rt = seg.RunTime;
		result = rt <= lim * 0.6 ? 3 : rt <= lim * 0.8 ? 2 : rt <= lim ? 1 : 0;
	}

	static List<Rec> BuildRecords(Parser p) {
		var outl = new List<Rec>();
		var specCache = new Dictionary<string, int>();
		Func<int, string, int> specOf = (segId, guid) => {
			string k = segId + "|" + guid;
			int sp;
			if (specCache.TryGetValue(k, out sp)) return sp;
			Dictionary<int, int> c; p.Casts.TryGetValue(k, out c);
			int s1, s2; sp = DetectSpec(c, out s1, out s2);
			if (s1 < 3 || s1 < 1.5 * s2) {
				Dictionary<int, int> all; p.CastsAll.TryGetValue(guid, out all);
				int a1, a2; int sp2 = DetectSpec(all, out a1, out a2);
				if (a1 >= 3) sp = sp2; else if (s1 == 0) sp = 0;
			}
			specCache[k] = sp;
			return sp;
		};
		foreach (var f in p.Fights) {
			var seg = p.Segs[f.Seg];
			if (seg.Level < MIN_LEVEL) continue;          // only +9 keys and higher
			double dur = f.End - f.Start;
			if (!f.BossHit) { f.Dmg = f.AllDmg; f.Unowned = f.AllUnowned; }   // boss never recognised: all damage
			foreach (var kv in f.Unowned) {
				// pets without a known owner: the only pet class player of the group (or the best evidence)
				var cands = new List<string>();
				foreach (var g in f.Members) { string cls; if (SPEC_CLASS.TryGetValue(specOf(f.Seg, g), out cls) && PET_CLASSES.Contains(cls)) cands.Add(g); }
				Dictionary<string, int> ev; p.PetEvidence.TryGetValue(kv.Key, out ev);
				string owner = null;
				if (cands.Count == 1) owner = cands[0];
				else if (cands.Count > 1 && ev != null) {
					int best = 0;
					foreach (var g in cands) { int n; ev.TryGetValue(g, out n); if (n > best) { best = n; owner = g; } }
				}
				if (owner != null) Add(f.Dmg, owner, kv.Value);
			}
			var encs = new List<int>();
			foreach (var x in p.Fights) if (x.Seg == f.Seg) encs.Add(x.Enc);
			int result, limit; ResultFor(seg, encs, out result, out limit);
			var aff = new StringBuilder();
			foreach (var a in seg.Affixes) { if (aff.Length > 0) aff.Append('.'); aff.Append(a); }
			foreach (var kv in f.Dmg) {
				int spec = specOf(f.Seg, kv.Key);
				string cls;
				if (!SPEC_CLASS.TryGetValue(spec, out cls)) continue;
				string raw; p.Names.TryGetValue(kv.Key, out raw);
				outl.Add(new Rec { Enc = f.Enc, Name = NormName(raw ?? kv.Key), Cls = cls, Spec = spec, Dps = kv.Value / dur,
					Damage = kv.Value, Duration = dur, Level = seg.Level, Result = result, Date = (long)f.End,
					RunTime = seg.RunTime > 0 ? seg.RunTime : -1, Limit = limit, Affixes = aff.ToString() });
			}
		}
		return outl;
	}

	// ------------------------------------------------------------------
	// store of every record found so far (one line per record), so each run only reads the new part of the log
	static string Line(Rec r) {
		return string.Join("\t", new string[] { r.Enc.ToString(CultureInfo.InvariantCulture), r.Name, r.Cls, r.Spec.ToString(CultureInfo.InvariantCulture),
			r.Dps.ToString("R", CultureInfo.InvariantCulture), r.Damage.ToString("R", CultureInfo.InvariantCulture), r.Duration.ToString("R", CultureInfo.InvariantCulture),
			r.Level.ToString(CultureInfo.InvariantCulture), r.Result.ToString(CultureInfo.InvariantCulture), r.Date.ToString(CultureInfo.InvariantCulture),
			r.RunTime.ToString("R", CultureInfo.InvariantCulture), r.Limit.ToString(CultureInfo.InvariantCulture), r.Affixes });
	}
	static Rec Parse(string l) {
		var p = l.Split('\t');
		if (p.Length < 13) return null;
		var ci = CultureInfo.InvariantCulture;
		return new Rec { Enc = int.Parse(p[0], ci), Name = p[1], Cls = p[2], Spec = int.Parse(p[3], ci), Dps = double.Parse(p[4], ci),
			Damage = double.Parse(p[5], ci), Duration = double.Parse(p[6], ci), Level = int.Parse(p[7], ci), Result = int.Parse(p[8], ci),
			Date = long.Parse(p[9], ci), RunTime = double.Parse(p[10], ci), Limit = int.Parse(p[11], ci), Affixes = p[12] };
	}

	static int FirstAffix(Rec r) { var a = r.Affixes.Split('.'); return a.Length > 0 && a[0] != "" ? Int(a[0]) : -1; }

	static void InferTF(List<Rec> recs) {
		var anchors = new List<Rec>();
		foreach (var r in recs) {
			r.Tf = -1;
			foreach (var a in r.Affixes.Split('.')) { if (a == "9") r.Tf = TYRANNICAL; else if (a == "10") r.Tf = FORTIFIED; }
			if (r.Tf > 0) anchors.Add(r);
		}
		foreach (var r in recs) {
			if (r.Tf > 0) continue;
			int first = FirstAffix(r), tf = -1; long gap = long.MaxValue;
			if (first >= 0) foreach (var a in anchors) {
				long g = Math.Abs(a.Date - r.Date);
				if (FirstAffix(a) == first && g <= 7 * 86400 && g < gap) { gap = g; tf = a.Tf; }
			}
			if (tf < 0) foreach (var a in anchors) {
				long g = Math.Abs(a.Date - r.Date);
				if (g <= 3 * 86400 && g < gap) { gap = g; tf = a.Tf; }
			}
			r.Tf = tf;
		}
	}

	static List<Rec> DedupeAndTrim(List<Rec> recs) {
		recs.Sort((a, b) => { int c = a.Enc.CompareTo(b.Enc); if (c != 0) return c; c = string.CompareOrdinal(a.Name, b.Name); if (c != 0) return c; return a.Date.CompareTo(b.Date); });
		var merged = new List<Rec>();
		foreach (var r in recs) {
			var m = merged.Count > 0 ? merged[merged.Count - 1] : null;
			if (m != null && m.Enc == r.Enc && m.Name == r.Name && Math.Abs(m.Date - r.Date) <= 300) {
				if (r.Dps > m.Dps) {
					if (r.Result < 0) { r.Result = m.Result; r.RunTime = m.RunTime; r.Limit = m.Limit; }
					merged[merged.Count - 1] = r;
				}
				continue;
			}
			merged.Add(r);
		}
		InferTF(merged);
		var by = new Dictionary<string, List<Rec>>();
		foreach (var r in merged) {
			string k = r.Enc + "|" + r.Spec + "|" + r.Tf;
			List<Rec> l; if (!by.TryGetValue(k, out l)) { l = new List<Rec>(); by[k] = l; }
			l.Add(r);
		}
		var final = new List<Rec>();
		foreach (var l in by.Values) {
			l.Sort((a, b) => b.Dps.CompareTo(a.Dps));
			for (int i = 0; i < l.Count && i < TOP_PER_SPEC; i++) final.Add(l[i]);
		}
		return final;
	}

	static string LuaStr(string s) { return "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "").Replace("\r", "") + "\""; }

	static void WriteLua(string path, List<Rec> recs, string packId, string player) {
		var sb = new StringBuilder();
		sb.Append("-- Written by Tools\\MBR-Tools.ps1 from your own WoWCombatLog.txt (boss DPS of +9 keys and higher).\n");
		sb.Append("-- The addon loads it at login and shares it with everyone who has the addon.\n");
		sb.Append("local ADDON, ns = ...\n");
		sb.Append("ns.LOCAL_PACK = {\n\tid = ").Append(LuaStr(packId)).Append(",\n\tby = ").Append(LuaStr(player ?? "")).Append(",\n\trecords = {\n");
		var ci = CultureInfo.InvariantCulture;
		recs.Sort((a, b) => { int c = a.Enc.CompareTo(b.Enc); return c != 0 ? c : b.Dps.CompareTo(a.Dps); });
		foreach (var r in recs) {
			sb.Append("\t\t{").Append(r.Enc.ToString(ci)).Append(',').Append(LuaStr(r.Name)).Append(',').Append(LuaStr(r.Cls)).Append(',')
				.Append(r.Spec.ToString(ci)).Append(',').Append(Math.Round(r.Dps).ToString(ci)).Append(',').Append(Math.Round(r.Damage).ToString(ci)).Append(',')
				.Append(r.Duration.ToString("0.0", ci)).Append(',').Append(r.Level.ToString(ci)).Append(',').Append(r.Result.ToString(ci)).Append(',')
				.Append(r.Date.ToString(ci)).Append(',').Append(r.RunTime > 0 ? Math.Round(r.RunTime).ToString(ci) : "-1").Append(',')
				.Append(r.Limit.ToString(ci)).Append(',').Append(LuaStr(r.Affixes)).Append(',').Append(r.Tf.ToString(ci)).Append("},\n");
		}
		sb.Append("\t},\n}\n");
		string tmp = path + ".tmp";
		File.WriteAllText(tmp, sb.ToString(), new UTF8Encoding(false));
		if (File.Exists(path)) File.Delete(path);
		File.Move(tmp, path);
	}

	// ------------------------------------------------------------------
	// Reads <logPath> from where the last run stopped, adds the new records to the store in
	// <dataDir>, writes <outLua>. Returns a one-line summary (also for the log file).
	public static string Run(string logPath, string dataDir, string outLua, bool fromStart) {
		Directory.CreateDirectory(dataDir);
		string statePath = Path.Combine(dataDir, "logstate.txt");
		string storePath = Path.Combine(dataDir, "records.tsv");
		var info = new FileInfo(logPath);
		if (!info.Exists) return "No combat log found at " + logPath;

		long offset = 0;
		if (!fromStart && File.Exists(statePath)) {
			var st = File.ReadAllText(statePath).Trim().Split('|');
			// same file and not shorter than before: continue where we stopped
			if (st.Length >= 3 && st[0] == logPath && Long(st[1]) <= info.Length) offset = Long(st[2]);
		}
		if (offset > info.Length) offset = 0;

		var p = new Parser();
		var lw = info.LastWriteTime;
		p.EndYear = lw.Year; p.EndMonth = lw.Month;
		p.SafePos = offset;
		long lines = 0;
		using (var fs = new FileStream(logPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 20)) {
			fs.Seek(offset, SeekOrigin.Begin);
			var buf = new byte[1 << 20];
			var acc = new MemoryStream();
			long pos = offset, lineStart = offset;
			int n;
			while ((n = fs.Read(buf, 0, buf.Length)) > 0) {
				int start = 0;
				for (int i = 0; i < n; i++) {
					if (buf[i] != (byte)'\n') continue;
					acc.Write(buf, start, i - start);
					string line = Encoding.UTF8.GetString(acc.GetBuffer(), 0, (int)acc.Length).TrimEnd('\r');
					acc.SetLength(0);
					long lineEnd = pos + i + 1;
					try { p.Feed(line, lineStart, lineEnd); } catch { }
					lines++;
					lineStart = lineEnd;
					start = i + 1;
				}
				acc.Write(buf, start, n - start);
				pos += n;
			}
			// no key open at the end of the log: everything was read
			if (p.Seg == null || p.Seg.Done) p.SafePos = lineStart;
		}

		var found = BuildRecords(p);
		var all = new List<Rec>();
		if (!fromStart && File.Exists(storePath)) foreach (var l in File.ReadAllLines(storePath, Encoding.UTF8)) { var r = Parse(l); if (r != null) all.Add(r); }
		int before = all.Count;
		all.AddRange(found);
		var final = DedupeAndTrim(all);
		var sbStore = new StringBuilder();
		foreach (var r in final) sbStore.Append(Line(r)).Append('\n');
		File.WriteAllText(storePath, sbStore.ToString(), new UTF8Encoding(false));
		File.WriteAllText(statePath, logPath + "|" + info.Length + "|" + p.SafePos, new UTF8Encoding(false));

		string packId = "local-" + DateTime.UtcNow.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);
		WriteLua(outLua, final, packId, null);
		var kills = new HashSet<string>();
		foreach (var r in found) kills.Add(r.Enc + "|" + r.Date);
		return string.Format(CultureInfo.InvariantCulture, "read {0} new lines, {1} boss kills of +{2} keys and higher, {3} records found, {4} kept in LocalLogData.lua",
			lines, kills.Count, MIN_LEVEL, found.Count, final.Count);
	}
}
