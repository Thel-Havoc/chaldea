/// Enumerator — generates candidate team configurations from a UserRoster.
///
/// Emits [CandidateTeam]s in smart order (most-promising first) so that
/// the pruner and simulator can find good solutions fast and prune the rest.
///
/// The outer loop structure (from the design doc):
///   For each support choice:
///     For each MC choice:
///       For each 5-servant combo from player roster:
///         For each CE assignment:
///           emit → Pruner → Simulator
///
/// This file owns only the generation and ordering logic. It knows nothing
/// about simulation or game mechanics — those live in pruner.dart and
/// headless_runner.dart.
library;

import 'package:chaldea/models/models.dart';

import '../roster/user_roster.dart';

// ---------------------------------------------------------------------------
// Output type
// ---------------------------------------------------------------------------

/// One candidate team, ready to hand to the pruner/simulator.
///
/// CE assignments are parallel to [servantIds]: servantIds[i] wears
/// ceAssignments[i] (null = no CE for that slot).
class CandidateTeam {
  /// Servant IDs for the 5 non-support slots (indices 0-4).
  /// Index 0 is the support slot; indices 1-5 are the player's servants.
  /// Exactly one of indices 0-4 is the borrowed support.
  final int supportSvtId;
  final List<int> playerSvtIds; // 1-5 of the player's own servants

  /// Parallel to [playerSvtIds]. null = no CE for this slot.
  final List<int?> playerCeIds;

  /// null = no CE on the support
  final int? supportCeId;

  /// null = no mystic code
  final int? mysticCodeId;
  final int mysticCodeLevel;

  const CandidateTeam({
    required this.supportSvtId,
    required this.playerSvtIds,
    required this.playerCeIds,
    this.supportCeId,
    this.mysticCodeId,
    this.mysticCodeLevel = 10,
  });

  @override
  String toString() =>
      'CandidateTeam(support=$supportSvtId, svts=$playerSvtIds, ces=$playerCeIds, mc=$mysticCodeId)';
}

// ---------------------------------------------------------------------------
// Meta-support definitions
// ---------------------------------------------------------------------------

/// Atlas Academy servant IDs for servants that are assumed always available
/// as a borrowed support (community standard: everyone has these on their
/// friend list at max stats).
///
/// The optimizer always tries borrowing each of these as the support slot.
const List<int> kMetaSupportIds = [
  504500,  // Altria Caster "Castoria" (collectionNo 339) — Arts
  503900,  // Scathach-Skadi (collectionNo 198) — Quick
  2800100, // Oberon-Vortigern (collectionNo 352) — Buster
  501900,  // Zhuge Liang / Lord El-Melloi II "Waver" (collectionNo 37) — universal charge
  500800,  // Merlin (collectionNo 150) — Buster
  // Add more as the meta evolves
];

// ---------------------------------------------------------------------------
// Enumerator
// ---------------------------------------------------------------------------

class Enumerator {
  final UserRoster roster;
  final QuestPhase quest;

  /// Override which support IDs to consider. Defaults to [kMetaSupportIds].
  final List<int> supportIds;

  /// How many of the player's servants to put in each team.
  /// For standard 6-slot teams: 5 (1 support + 5 player = 6 total).
  final int playerSlotsPerTeam;

  Enumerator({
    required this.roster,
    required this.quest,
    List<int>? supportIds,
    this.playerSlotsPerTeam = 5,
  }) : supportIds = supportIds ?? kMetaSupportIds;

  // -------------------------------------------------------------------------
  // Main entry point
  // -------------------------------------------------------------------------

  /// Generates all candidate teams in priority order.
  ///
  /// This is a synchronous Iterable (lazy generator) so the caller can
  /// consume one candidate at a time and stop early once enough solutions
  /// are found. The caller drives the loop; this just produces candidates.
  ///
  ///   for (final candidate in enumerator.candidates()) {
  ///     if (pruner.passes(candidate)) {
  ///       final result = await runner.run(teamSpecFor(candidate));
  ///       if (result.cleared) solutions.add(result);
  ///     }
  ///   }
  Iterable<CandidateTeam> candidates() sync* {
    final sortedSvtIds = _sortedServantIds();
    final sortedCeIds = _sortedCeIds();
    final mcChoices = _mysticCodeChoices();

    // All combinations of 'playerSlotsPerTeam' servants from roster
    final svtCombos = _combinations(sortedSvtIds, playerSlotsPerTeam);

    for (final supportId in _sortedSupportIds()) {
      for (final mcChoice in mcChoices) {
        for (final svtCombo in svtCombos) {
          // CE assignments: for each servant slot, try CEs in priority order.
          // The null CE (no CE) is always tried last.
          for (final ceAssignment in _ceAssignments(svtCombo, sortedCeIds)) {
            yield CandidateTeam(
              supportSvtId: supportId,
              playerSvtIds: svtCombo,
              playerCeIds: ceAssignment,
              supportCeId: null, // support CE not controlled by us
              mysticCodeId: mcChoice?.key,
              mysticCodeLevel: mcChoice?.value ?? 10,
            );
          }
        }
      }
    }
  }

  // -------------------------------------------------------------------------
  // Ordering helpers
  // -------------------------------------------------------------------------

  /// Sorts the roster's servant IDs: AoE NP servants first, then by level
  /// descending. Within each group, higher NP level comes first.
  ///
  /// Rationale: AoE servants are almost always the attackers in farming;
  /// ST servants rarely clear waves efficiently. Trying high-level servants
  /// first means we find strong solutions quickly, enabling better pruning.
  List<int> _sortedServantIds() {
    final ids = roster.servants.keys.toList();
    ids.sort((a, b) {
      final svtA = db.gameData.servantsById[a];
      final svtB = db.gameData.servantsById[b];
      if (svtA == null || svtB == null) return 0;

      // AoE NP before ST
      final aoeA = _isAoeNp(svtA) ? 0 : 1;
      final aoeB = _isAoeNp(svtB) ? 0 : 1;
      if (aoeA != aoeB) return aoeA - aoeB;

      // Higher level first
      final lvA = roster.servants[a]!.level;
      final lvB = roster.servants[b]!.level;
      if (lvA != lvB) return lvB - lvA;

      // Higher NP level first
      final npA = roster.servants[a]!.npLevel;
      final npB = roster.servants[b]!.npLevel;
      return npB - npA;
    });
    return ids;
  }

  /// Sorts the roster's CE IDs by NP charge value, highest first.
  ///
  /// Rationale: NP charge CEs (Kaleidoscope, Imaginary Element) are almost
  /// always better for farming than pure damage CEs. Trying them first means
  /// we hit the "NP charge gate" pass condition early and spend less time on
  /// dead-end assignments.
  List<int> _sortedCeIds() {
    final ids = roster.craftEssences.keys.toList();
    ids.sort((a, b) {
      final chargeA = _npChargeOf(a);
      final chargeB = _npChargeOf(b);
      return chargeB - chargeA; // highest first
    });
    return ids;
  }

  /// Returns support IDs in priority order.
  /// Filters out supports the player doesn't have in game data.
  List<int> _sortedSupportIds() {
    return supportIds
        .where((id) => db.gameData.servantsById[id] != null)
        .toList();
  }

  /// Returns mystic code choices from the roster, plus null (no MC).
  /// Plug Suit (id 210) is tried first since Order Change is critical.
  List<MapEntry<int, int>?> _mysticCodeChoices() {
    const plugSuitId = 210;
    final entries = roster.mysticCodes.entries.toList()
      ..sort((a, b) {
        if (a.key == plugSuitId) return -1;
        if (b.key == plugSuitId) return 1;
        return 0;
      });
    return [
      ...entries.map((e) => MapEntry(e.key, e.value)),
      null, // no MC
    ];
  }

  // -------------------------------------------------------------------------
  // CE assignment generation
  // -------------------------------------------------------------------------

  /// Generates all CE assignments for a given set of servant IDs.
  ///
  /// Each assignment is a list parallel to [svtIds] — the CE id for each
  /// slot, or null for no CE.
  ///
  /// Rules:
  /// - A CE with copies=1 can only be assigned to one servant at a time.
  /// - A CE with copies=N can be assigned to up to N servants simultaneously.
  /// - The "no CE" option is always included.
  ///
  /// To keep the search tractable, we assign CEs greedily: try the
  /// highest-priority CE on the first servant, the next on the second, etc.
  /// Full combinatorial CE assignment is too expensive and rarely changes
  /// the outcome vs. this greedy approach.
  Iterable<List<int?>> _ceAssignments(
      List<int> svtIds, List<int> sortedCeIds) sync* {
    // Track remaining copies
    final remaining = <int, int>{
      for (final id in sortedCeIds) id: roster.craftEssences[id]!.copies,
    };

    // Greedy: assign best available CE to each slot in turn
    final assignment = <int?>[for (final _ in svtIds) null];

    // Try with best CEs first (greedy assignment).
    // Only assign CEs to servants with a damaging NP — CEs on supports
    // (Castoria, Vitch, Oberon, etc.) don't affect farming output and
    // would otherwise inflate the candidate count with meaningless variants.
    final usedCopies = <int, int>{};
    for (int i = 0; i < svtIds.length; i++) {
      final svt = db.gameData.servantsById[svtIds[i]];
      if (svt == null || !_hasDamageNp(svt)) continue;
      for (final ceId in sortedCeIds) {
        final used = usedCopies[ceId] ?? 0;
        if (used < remaining[ceId]!) {
          assignment[i] = ceId;
          usedCopies[ceId] = used + 1;
          break;
        }
      }
    }
    yield List.of(assignment);

    // Also try the "no CE" variant (some teams don't need one)
    yield List.filled(svtIds.length, null);

    // TODO(phase3): For the full optimizer, generate all valid CE permutations
    // using the copies constraint. For now the greedy approach gets us started.
  }

  // -------------------------------------------------------------------------
  // Combination generation
  // -------------------------------------------------------------------------

  /// Generates all combinations of [r] elements from [items].
  Iterable<List<T>> _combinations<T>(List<T> items, int r) sync* {
    if (r == 0) {
      yield [];
      return;
    }
    if (r > items.length) return;

    for (int i = 0; i <= items.length - r; i++) {
      for (final rest in _combinations(items.sublist(i + 1), r - 1)) {
        yield [items[i], ...rest];
      }
    }
  }

  // -------------------------------------------------------------------------
  // Game data helpers
  // -------------------------------------------------------------------------

  bool _isAoeNp(Servant svt) {
    final np = svt.groupedNoblePhantasms[1]?.firstOrNull;
    if (np == null) return false;
    return np.damageType == TdEffectFlag.attackEnemyAll;
  }

  bool _hasDamageNp(Servant svt) {
    final np = svt.groupedNoblePhantasms[1]?.firstOrNull;
    if (np == null) return false;
    return np.damageType != TdEffectFlag.support;
  }

  /// Returns the NP charge % this CE provides at battle start (0–100).
  /// Looks at the CE's first skill function for a chargeNp effect.
  int _npChargeOf(int ceId) {
    final ownedCe = roster.craftEssences[ceId]!;
    final ce = db.gameData.craftEssencesById[ceId];
    if (ce == null) return 0;

    for (final skill in ce.skills) {
      for (final func in skill.functions) {
        if (func.funcType == FuncType.gainNp) {
          final val = ownedCe.mlb
              ? func.svals2?.firstOrNull?.Value
              : func.svals.firstOrNull?.Value;
          if (val != null) return val ~/ 100; // svals are in 0-10000 range
        }
      }
    }
    return 0;
  }
}
