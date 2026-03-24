/// Converts roster data (OwnedServant, OwnedCE) into the SlotSpec format
/// that HeadlessRunner consumes.
///
/// This is the only place in the codebase that crosses from our data layer
/// into Chaldea's game data. Everything above this line is pure JSON;
/// everything below it uses db.gameData.
library;

import 'package:chaldea/models/models.dart';

import '../simulation/headless_runner.dart';
import 'user_roster.dart';

/// Converts one roster servant + optional CE assignment into a [SlotSpec].
///
/// [svtId]   — Atlas Academy Servant.id (the key used in UserRoster.servants)
/// [owned]   — the player's data for that servant
/// [ceId]    — Atlas Academy CraftEssence.id to equip, or null for no CE
/// [ce]      — the player's data for that CE (needed for level/mlb)
/// [isSupport] — true if this slot is the borrowed support servant
///
/// Returns null if [svtId] or [ceId] are not found in game data (stale ID
/// after a game update). Callers should skip null slots silently.
SlotSpec? slotSpecFromOwned({
  required int svtId,
  required OwnedServant owned,
  int? ceId,
  OwnedCE? ce,
  bool isSupport = false,
}) {
  final svt = db.gameData.servantsById[svtId];
  if (svt == null) return null; // servant not in game data (shouldn't happen)

  CraftEssence? ceObj;
  if (ceId != null) {
    ceObj = db.gameData.craftEssencesById[ceId];
    // Missing CE is non-fatal — just equip nothing
  }

  return SlotSpec(
    svt: svt,
    level: owned.level,
    limitCount: owned.limitCount,
    tdLevel: owned.npLevel,
    skillLevels: List.of(owned.skillLevels),
    appendLevels: List.of(owned.appendLevels),
    atkFou: owned.fouAtk,
    hpFou: owned.fouHp,
    ce: ceObj,
    ceMlb: ce?.mlb ?? false,
    ceLevel: ce?.level ?? 1,
    isSupport: isSupport,
  );
}

/// Convenience: build a SlotSpec for a "generic" support servant — one that
/// the optimizer assumes is always borrowable (Castoria, Skadi, Oberon, etc.)
/// at max stats. The caller supplies the Servant object and a CE if relevant.
///
/// Generic supports are assumed: lv 90, all skills 10/10/10, Fous 1000/1000,
/// NP5. These match the community standard "what a well-built support looks like".
SlotSpec genericSupportSlot({
  required Servant svt,
  int level = 90,
  int npLevel = 5,
  List<int> skillLevels = const [10, 10, 10],
  List<int> appendLevels = const [0, 0, 0],
  CraftEssence? ce,
  bool ceMlb = false,
  int ceLevel = 1,
}) {
  return SlotSpec(
    svt: svt,
    level: level,
    limitCount: 4,
    tdLevel: npLevel,
    skillLevels: List.of(skillLevels),
    appendLevels: List.of(appendLevels),
    atkFou: 1000,
    hpFou: 1000,
    ce: ce,
    ceMlb: ceMlb,
    ceLevel: ceLevel,
    isSupport: true,
  );
}

/// Returns the [MysticCode] object for an MC id, or null if not in game data.
MysticCode? mysticCodeFromId(int mcId) => db.gameData.mysticCodes[mcId];
