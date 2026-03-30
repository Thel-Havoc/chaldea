/// User roster data model.
///
/// Intentionally pure data — no game data imports, no simulator imports.
/// Servant IDs and CE IDs are Atlas Academy internal IDs (Servant.id / CraftEssence.id),
/// NOT collection numbers. The UI resolves names from game data; we only store the key.
///
/// Schema versioning rule: never remove or rename a JSON field.
/// Adding a new field is always safe — give it a default in fromJson and it
/// will be populated on any existing file without re-entry.
library;

import 'dart:convert';

// ---------------------------------------------------------------------------
// Schema version — increment ONLY when adding new fields
// ---------------------------------------------------------------------------
const int kRosterSchemaVersion = 2;

// ---------------------------------------------------------------------------
// ServantRole
// ---------------------------------------------------------------------------

/// Whether the player wants this servant used as an attacker, a support, or both.
///
/// attacker — the engine will assign NP-firing turns to this servant.
/// support  — the engine only uses this servant for skill buffs / charge.
///
/// Default for loaded entries with no 'roles' field is {attacker, support}
/// so that existing rosters aren't silently broken — the engine treats them
/// exactly as before until the user explicitly re-tags them.
enum ServantRole { attacker, support }

// ---------------------------------------------------------------------------
// OwnedServant
// ---------------------------------------------------------------------------

class OwnedServant {
  // Defaults used both for new entries and for missing JSON fields on load
  static const int _defLevel = 90;
  static const int _defNpLevel = 1;
  static const List<int> _defSkills = [10, 10, 10];
  static const List<int> _defAppends = [0, 0, 0];
  static const int _defFou = 1000;
  static const int _defLimitCount = 4; // 4 = max ascension (the norm)

  int level; // 1-120
  int npLevel; // 1-5
  List<int> skillLevels; // [s1, s2, s3], each 1-10
  List<int> appendLevels; // [a1, a2, a3], each 0-10; 0 = not unlocked
  int fouAtk; // 0-2000
  int fouHp; // 0-2000
  /// Ascension stage (0-4). Affects servants whose kit changes by ascension
  /// (Melusine, Ptolemy). 4 = max ascension / final form.
  int limitCount;
  /// Attacker/support role tags. The optimizer uses this to decide whether
  /// to assign NP-firing turns to this servant (attacker) or treat it as a
  /// pure buffer (support). Can be both.
  Set<ServantRole> roles;

  OwnedServant({
    this.level = _defLevel,
    this.npLevel = _defNpLevel,
    List<int>? skillLevels,
    List<int>? appendLevels,
    this.fouAtk = _defFou,
    this.fouHp = _defFou,
    this.limitCount = _defLimitCount,
    Set<ServantRole>? roles,
  })  : skillLevels = skillLevels ?? List.of(_defSkills),
        appendLevels = appendLevels ?? List.of(_defAppends),
        roles = roles ?? {ServantRole.attacker, ServantRole.support};

  Map<String, dynamic> toJson() => {
        'level': level,
        'npLevel': npLevel,
        'skillLevels': skillLevels,
        'appendLevels': appendLevels,
        'fouAtk': fouAtk,
        'fouHp': fouHp,
        'limitCount': limitCount,
        'roles': roles.map((r) => r.name).toList(),
      };

  factory OwnedServant.fromJson(Map<String, dynamic> j) => OwnedServant(
        level: j['level'] as int? ?? _defLevel,
        npLevel: j['npLevel'] as int? ?? _defNpLevel,
        skillLevels: _intList(j['skillLevels']) ?? List.of(_defSkills),
        appendLevels: _intList(j['appendLevels']) ?? List.of(_defAppends),
        fouAtk: j['fouAtk'] as int? ?? _defFou,
        fouHp: j['fouHp'] as int? ?? _defFou,
        limitCount: j['limitCount'] as int? ?? _defLimitCount,
        roles: _parseRoles(j['roles']),
      );

  OwnedServant copyWith({
    int? level,
    int? npLevel,
    List<int>? skillLevels,
    List<int>? appendLevels,
    int? fouAtk,
    int? fouHp,
    int? limitCount,
    Set<ServantRole>? roles,
  }) =>
      OwnedServant(
        level: level ?? this.level,
        npLevel: npLevel ?? this.npLevel,
        skillLevels: skillLevels ?? List.of(this.skillLevels),
        appendLevels: appendLevels ?? List.of(this.appendLevels),
        fouAtk: fouAtk ?? this.fouAtk,
        fouHp: fouHp ?? this.fouHp,
        limitCount: limitCount ?? this.limitCount,
        roles: roles ?? Set.of(this.roles),
      );
}

// ---------------------------------------------------------------------------
// OwnedCE
// ---------------------------------------------------------------------------

class OwnedCE {
  int level;
  bool mlb;
  int copies; // how many copies you own — optimizer uses this to know if you
  //             can equip the same CE on multiple servants simultaneously

  OwnedCE({
    this.level = 1,
    this.mlb = false,
    this.copies = 1,
  });

  Map<String, dynamic> toJson() => {
        'level': level,
        'mlb': mlb,
        'copies': copies,
      };

  factory OwnedCE.fromJson(Map<String, dynamic> j) => OwnedCE(
        level: j['level'] as int? ?? 1,
        mlb: j['mlb'] as bool? ?? false,
        copies: j['copies'] as int? ?? 1,
      );

  OwnedCE copyWith({int? level, bool? mlb, int? copies}) => OwnedCE(
        level: level ?? this.level,
        mlb: mlb ?? this.mlb,
        copies: copies ?? this.copies,
      );
}

// ---------------------------------------------------------------------------
// UserRoster  (the root document stored per profile)
// ---------------------------------------------------------------------------

class UserRoster {
  static const int currentSchemaVersion = kRosterSchemaVersion;

  int schemaVersion;
  String profileName;

  /// Key: Atlas Academy Servant.id (NOT collectionNo).
  Map<int, OwnedServant> servants;

  /// Key: Atlas Academy CraftEssence.id.
  Map<int, OwnedCE> craftEssences;

  /// Key: MysticCode.id → level (1-10).
  Map<int, int> mysticCodes;

  UserRoster({
    required this.profileName,
    this.schemaVersion = currentSchemaVersion,
    Map<int, OwnedServant>? servants,
    Map<int, OwnedCE>? craftEssences,
    Map<int, int>? mysticCodes,
  })  : servants = servants ?? {},
        craftEssences = craftEssences ?? {},
        mysticCodes = mysticCodes ?? {};

  // -------------------------------------------------------------------------
  // Convenience helpers
  // -------------------------------------------------------------------------

  bool hasSvt(int svtId) => servants.containsKey(svtId);
  bool hasCE(int ceId) => craftEssences.containsKey(ceId);

  void addServant(int svtId, {OwnedServant? data}) {
    servants[svtId] = data ?? OwnedServant();
  }

  void addCE(int ceId, {OwnedCE? data}) {
    craftEssences[ceId] = data ?? OwnedCE();
  }

  void removeServant(int svtId) => servants.remove(svtId);
  void removeCE(int ceId) => craftEssences.remove(ceId);

  // -------------------------------------------------------------------------
  // JSON serialization
  // -------------------------------------------------------------------------

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'profileName': profileName,
        'servants': {
          for (final e in servants.entries) '${e.key}': e.value.toJson(),
        },
        'craftEssences': {
          for (final e in craftEssences.entries) '${e.key}': e.value.toJson(),
        },
        'mysticCodes': {
          for (final e in mysticCodes.entries) '${e.key}': e.value,
        },
      };

  factory UserRoster.fromJson(Map<String, dynamic> j) => UserRoster(
        schemaVersion: j['schemaVersion'] as int? ?? 1,
        profileName: j['profileName'] as String? ?? 'Unnamed',
        servants: _parseIntKeyMap(
          j['servants'],
          (v) => OwnedServant.fromJson(v as Map<String, dynamic>),
        ),
        craftEssences: _parseIntKeyMap(
          j['craftEssences'],
          (v) => OwnedCE.fromJson(v as Map<String, dynamic>),
        ),
        mysticCodes: _parseIntKeyMap(
          j['mysticCodes'],
          (v) => v as int,
        ),
      );

  String toJsonString() =>
      const JsonEncoder.withIndent('  ').convert(toJson());

  factory UserRoster.fromJsonString(String s) =>
      UserRoster.fromJson(jsonDecode(s) as Map<String, dynamic>);

  // Returns a deep copy with an optionally overridden profile name.
  UserRoster copyWith({String? profileName}) => UserRoster.fromJson(
        toJson()..['profileName'] = profileName ?? this.profileName,
      );
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

Set<ServantRole> _parseRoles(dynamic raw) {
  if (raw == null) return {ServantRole.attacker, ServantRole.support};
  final list = raw as List;
  final result = <ServantRole>{};
  for (final item in list) {
    switch (item as String) {
      case 'attacker':
        result.add(ServantRole.attacker);
      case 'support':
        result.add(ServantRole.support);
    }
  }
  // Default to both if the stored list was empty or contained unknown values.
  return result.isEmpty ? {ServantRole.attacker, ServantRole.support} : result;
}

List<int>? _intList(dynamic raw) {
  if (raw == null) return null;
  return (raw as List).cast<int>();
}

Map<int, V> _parseIntKeyMap<V>(dynamic raw, V Function(dynamic) parse) {
  if (raw == null) return {};
  final map = raw as Map<String, dynamic>;
  return {
    for (final e in map.entries) int.parse(e.key): parse(e.value),
  };
}
