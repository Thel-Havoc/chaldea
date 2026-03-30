/// Enumerator — generates candidate team configurations from a UserRoster.
///
/// Emits [CandidateTeam]s in smart order (most-promising first) so that
/// the pruner and simulator can find good solutions fast and prune the rest.
///
/// Team size is determined dynamically:
///   Always:    2 player frontline slots + 1 borrowed support = 3 frontline total
///   +1 backline if the MC has Order Change (the swap-in servant)
///   +1 backline per frontline servant that has a field-departure skill or NP
///              (e.g. Arash self-death, Chen Gong ally sacrifice)
///
/// The outer loop structure:
///   For each support choice:
///     For each MC choice:
///       For each 2-servant frontline combo from player roster:
///         Determine backline size (OC + field-departure count)
///         For each backline combo from remaining roster:
///           For each CE assignment:
///             emit → Pruner → Simulator
///
/// This file owns only the generation and ordering logic. It knows nothing
/// about simulation or game mechanics — those live in pruner.dart and
/// headless_runner.dart.
library;

import 'package:chaldea/models/models.dart';

import '../roster/user_roster.dart' show ServantRole, UserRoster;

// ---------------------------------------------------------------------------
// MC IDs that have Order Change as S3
// ---------------------------------------------------------------------------

/// Mystic Code IDs whose S3 is Order Change.
/// Mirrored from candidate_converter.dart — if you add IDs there, add them here too.
const Set<int> _kOrderChangeMcIds = {20, 210};

// ---------------------------------------------------------------------------
// Output type
// ---------------------------------------------------------------------------

/// One candidate team, ready to hand to the pruner/simulator.
///
/// CE assignments are parallel to [playerSvtIds]: playerSvtIds[i] wears
/// playerCeIds[i] (null = no CE for that slot).
class CandidateTeam {
  /// The borrowed support servant ID (always in frontline slot 2).
  final int supportSvtId;

  /// Player servant IDs in layout order:
  ///   [0]: frontline slot 0
  ///   [1]: frontline slot 1
  ///   [2+]: backline slots (OC target, field-departure replacements)
  /// Length is 2 for plain teams, 3 for OC teams, etc.
  final List<int> playerSvtIds;

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
  604200,  // Koyanskaya of Light "Vitch" (collectionNo 368) — Buster charge
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

  Enumerator({
    required this.roster,
    required this.quest,
    List<int>? supportIds,
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

    // Frontline is always exactly 2 player servants (+ borrowed support = 3 total).
    final frontlineCombos = _combinations(sortedSvtIds, 2);

    for (final supportId in _sortedSupportIds()) {
      for (final mcChoice in mcChoices) {
        final ocSlots = _hasOrderChange(mcChoice?.key) ? 1 : 0;

        for (final frontlineCombo in frontlineCombos) {
          // Extra backline slots needed for servants that depart the field
          // (e.g. Arash NP self-death → replacement needed).
          final departures = _fieldDepartureCount(frontlineCombo);
          final backlineSize = ocSlots + departures;

          // Remaining servants available for backline (not already in frontline).
          final remaining = sortedSvtIds
              .where((id) => !frontlineCombo.contains(id))
              .toList();

          final backlineCombos = backlineSize > 0
              ? _combinations(remaining, backlineSize)
              : [<int>[]];

          for (final backlineCombo in backlineCombos) {
            final allPlayerIds = [...frontlineCombo, ...backlineCombo];
            for (final ceAssignment in _ceAssignments(allPlayerIds, sortedCeIds)) {
              yield CandidateTeam(
                supportSvtId: supportId,
                playerSvtIds: allPlayerIds,
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

      // Attacker-tagged servants before support-only — ensures attacker-tagged
      // servants at the same level land in frontline slots (0-1) rather than
      // being displaced by support servants of equal level.
      final atkA =
          roster.servants[a]!.roles.contains(ServantRole.attacker) ? 0 : 1;
      final atkB =
          roster.servants[b]!.roles.contains(ServantRole.attacker) ? 0 : 1;
      if (atkA != atkB) return atkA - atkB;

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
    // Only assign CEs to attacker-tagged servants — CEs on supports don't
    // affect farming output and would inflate the candidate count.
    final usedCopies = <int, int>{};
    for (int i = 0; i < svtIds.length; i++) {
      final owned = roster.servants[svtIds[i]];
      if (owned == null || !owned.roles.contains(ServantRole.attacker)) continue;
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
  // Backline size helpers
  // -------------------------------------------------------------------------

  /// True if [mcId] is a Mystic Code whose S3 is Order Change.
  bool _hasOrderChange(int? mcId) =>
      mcId != null && _kOrderChangeMcIds.contains(mcId);

  /// Returns the number of extra backline slots needed for servants in
  /// [frontlineSvtIds] that will depart the field during the battle
  /// (e.g. Arash whose NP kills him, Chen Gong who sacrifices an ally).
  ///
  /// Each departing servant needs one replacement in the backline, otherwise
  /// the empty slot wastes a field position for the remainder of the fight.
  ///
  /// TODO: implement departure detection by scanning servant NPs and skills
  /// for self-death, ally-sacrifice, or field-swap functions. For now returns
  /// 0 because no current roster servants have departure mechanics.
  int _fieldDepartureCount(List<int> frontlineSvtIds) => 0;

  // -------------------------------------------------------------------------
  // Game data helpers
  // -------------------------------------------------------------------------

  /// Returns true if the servant has an AoE NP in any of their NP variants.
  /// Checks all variants so form-change servants (e.g. Mélusine, who starts
  /// with an ST NP but unlocks an AoE NP via S3) are sorted as AoE attackers.
  bool _isAoeNp(Servant svt) {
    final nps = svt.groupedNoblePhantasms[1] ?? [];
    return nps.any((np) => np.damageType == TdEffectFlag.attackEnemyAll);
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
