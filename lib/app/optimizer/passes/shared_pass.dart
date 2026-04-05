/// SharedPass — re-simulates community-shared teams using the player's stats.
///
/// This pass runs before PatternPass and RulesPass so the optimizer surfaces
/// community-proven team compositions immediately, even for nodes where the
/// full RulesPass would take hours.
///
/// Data source: Chaldea simulator API (ChaldeaWorkerApi.teamsByQuest).
/// Community teams are pre-fetched in the root isolate (by RunNotifier before
/// starting the engine) and passed here as encoded strings.
///
/// Simulation strategy: for each community team, the player-owned servants and
/// CEs are identified by ID match. If the player owns all non-support servants,
/// a [CandidateTeam] is built with those CE IDs (using player's own copy stats)
/// and dispatched via [HeadlessWorkerPool.runCandidate] so all skill-timing
/// spec variants are simulated. Support slots are kept at community (max) stats.
///
/// A community team is skipped if the player doesn't own any required
/// non-support servant. If the player doesn't own a CE from the community
/// team, that CE slot is left empty (null) — the team may still clear without it.
library;

import 'package:chaldea/models/models.dart';

import '../roster/user_roster.dart';
import '../search/enumerator.dart';
import 'optimizer_pass.dart';

class SharedPass extends OptimizerPass {
  /// Encoded community teams (BattleShareData.toDataV2() strings).
  /// Pre-fetched in the root isolate and passed here at construction time.
  final List<String> encodedTeams;

  const SharedPass({required this.encodedTeams});

  @override
  String get name => 'Shared';

  // ---------------------------------------------------------------------------
  // CandidateTeam construction
  // ---------------------------------------------------------------------------

  /// Builds a [CandidateTeam] from a community [shareData] using the player's
  /// own copies of servants and CEs.
  ///
  /// Returns `null` when the player doesn't own a required non-support servant.
  ///
  /// CE substitution: the community CE id is used if the player owns that CE
  /// (at their current MLB/level); otherwise the slot has no CE.
  /// Support slots keep their community (max) stats via [CandidateTeam.supportSvtId].
  static CandidateTeam? toCandidateTeam(
    BattleShareData shareData,
    UserRoster roster,
  ) {
    final playerSvtIds = <int>[];
    final playerCeIds = <int?>[];
    int? supportSvtId;

    for (final slot in shareData.formation.svts) {
      if (slot == null || (slot.svtId ?? 0) == 0) continue;
      final svtId = slot.svtId!;

      if (slot.supportType.isSupport) {
        supportSvtId = svtId;
        // Support CE is not player-controlled; CandidateConverter handles it.
      } else {
        if (!roster.servants.containsKey(svtId)) return null;
        playerSvtIds.add(svtId);
        final ceId = slot.equip1.id;
        playerCeIds.add(
          (ceId != null && roster.craftEssences.containsKey(ceId)) ? ceId : null,
        );
      }
    }

    if (supportSvtId == null || playerSvtIds.isEmpty) return null;

    final mcId = shareData.formation.mysticCode.mysticCodeId;
    if (mcId != null && !roster.mysticCodes.containsKey(mcId)) return null;
    final mcLevel = mcId != null ? roster.mysticCodes[mcId]! : 10;

    return CandidateTeam(
      supportSvtId: supportSvtId,
      playerSvtIds: playerSvtIds,
      playerCeIds: playerCeIds,
      mysticCodeId: mcId,
      mysticCodeLevel: mcLevel,
    );
  }
}
