/// PatternPass — cross-quest history replay pass.
///
/// Scans all locally saved optimizer history files, scores each prior clear
/// against the current quest using [QuestFingerprint] similarity, and tries
/// the most promising servant compositions before the full RulesPass search.
///
/// Each unique team (servants + CEs + MC) is tried at most once. The engine
/// dispatches each matched [CandidateTeam] via [HeadlessWorkerPool.runCandidate],
/// so CandidateConverter generates all spec variants for that team — the same
/// path as RulesPass but targeted at historically-proven compositions only.
///
/// Team reconstruction: the historical BattleShareData is used to identify
/// which servants, CEs, and MC the original clear used. These are then
/// validated against the player's current roster — if the player no longer
/// owns a required servant or CE, that historical team is skipped entirely.
/// CEs from history are used with the player's current MLB/level stats.
///
/// After PatternPass completes, the engine adds every dispatched team's
/// CE-inclusive signature to the seen-sigs set, so later passes skip those
/// exact team+CE combinations.
///
/// Learning: [PatternPassCalibration] tracks per-bucket success rates and
/// suppresses score ranges that have historically been low-value.
library;

import 'dart:io';

import 'package:chaldea/models/models.dart';

import '../roster/run_history.dart';
import '../roster/user_roster.dart';
import '../search/enumerator.dart';
import 'optimizer_pass.dart';
import 'pattern_pass_calibration.dart';

class PatternPass extends OptimizerPass {
  /// Maximum number of unique teams to dispatch per run.
  static const int maxCandidates = 20;

  /// Minimum fingerprint similarity score to consider a historical clear.
  static const double minScore = 0.50;

  /// Historical teams to try, sorted by descending similarity score.
  /// Each entry is a fully-constructed [CandidateTeam] (servants + CEs + MC)
  /// verified against the player's current roster, the best score seen across
  /// all matching history records for that team, and the ID of the source quest
  /// from whose history the team was drawn.
  ///
  /// Capped at [maxCandidates] entries.
  final List<({CandidateTeam team, double score, int sourceQuestId})> historicalCandidates;

  final PatternPassCalibration calibration;
  final String calibrationFilePath;

  PatternPass._({
    required this.historicalCandidates,
    required this.calibration,
    required this.calibrationFilePath,
  });

  @override
  String get name => 'Pattern';

  // ---------------------------------------------------------------------------
  // Factory
  // ---------------------------------------------------------------------------

  /// Scans all optimizer history files under [appPath], scores each prior
  /// clear against [quest]'s fingerprint, validates teams against [roster],
  /// deduplicates by full team identity (servants + CEs + MC), and returns
  /// a [PatternPass] ready for use.
  ///
  /// Runs synchronously inside the engine isolate.
  static PatternPass prepare({
    required QuestPhase quest,
    required UserRoster roster,
    required String appPath,
  }) {
    final calibrationFile = '$appPath/pattern_pass_calibration.json';
    final calibration = PatternPassCalibration.load(calibrationFile);
    final fingerprint = QuestFingerprint.fromQuestPhase(quest);

    // Load all optimizer_history_*.jsonl files.
    final records = <RunRecord>[];
    try {
      final dir = Directory(appPath);
      if (dir.existsSync()) {
        for (final entity in dir.listSync()) {
          if (entity is! File) continue;
          final name = entity.uri.pathSegments.last;
          if (!name.startsWith('optimizer_history_') ||
              !name.endsWith('.jsonl')) { continue; }
          records.addAll(RunHistory(entity.path).loadAll());
        }
      }
    } catch (_) {}

    // Score each record; keep the best-scoring team per CE-inclusive sig.
    final bestPerSig = <String, ({double score, CandidateTeam team, int questId})>{};
    for (final record in records) {
      final fp = record.questFingerprint;
      if (fp == null) continue; // old record without fingerprint — skip

      final score = fingerprint.similarityTo(fp);
      if (score < minScore) continue;
      if (!calibration.shouldTry(score)) continue;

      final candidate = _buildCandidate(record.battleData, roster);
      if (candidate == null) continue; // player doesn't own required servants/CEs

      final sig = _teamSig(candidate);
      final existing = bestPerSig[sig];
      if (existing == null || score > existing.score) {
        bestPerSig[sig] = (score: score, team: candidate, questId: record.questId);
      }
    }

    // Sort by score descending, take top N.
    final sorted = bestPerSig.values.toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    final top = sorted
        .take(maxCandidates)
        .map((e) => (team: e.team, score: e.score, sourceQuestId: e.questId))
        .toList();

    return PatternPass._(
      historicalCandidates: top,
      calibration: calibration,
      calibrationFilePath: calibrationFile,
    );
  }

  // ---------------------------------------------------------------------------
  // Team construction from historical data
  // ---------------------------------------------------------------------------

  /// Builds a [CandidateTeam] from a historical [BattleShareData] using the
  /// player's current copies of servants and CEs.
  ///
  /// Returns null if the player doesn't own any required non-support servant.
  /// If the player doesn't own a CE from the historical record, that CE slot
  /// is left empty — the team may still clear without it.
  static CandidateTeam? _buildCandidate(BattleShareData data, UserRoster roster) {
    final playerSvtIds = <int>[];
    final playerCeIds = <int?>[];
    int? supportSvtId;

    for (final slot in data.formation.svts) {
      if (slot == null || (slot.svtId ?? 0) == 0) continue;
      final svtId = slot.svtId!;
      final ceId = slot.equip1.id;

      if (slot.supportType.isSupport) {
        supportSvtId = svtId;
        // Support CE is not player-controlled; CandidateConverter handles it.
      } else {
        if (!roster.servants.containsKey(svtId)) return null;
        playerSvtIds.add(svtId);
        playerCeIds.add(
          (ceId != null && roster.craftEssences.containsKey(ceId)) ? ceId : null,
        );
      }
    }

    if (supportSvtId == null || playerSvtIds.isEmpty) return null;

    final mcId = data.formation.mysticCode.mysticCodeId;
    final mcLevel = mcId != null
        ? (roster.mysticCodes[mcId] ?? data.formation.mysticCode.level)
        : 10;

    return CandidateTeam(
      supportSvtId: supportSvtId,
      playerSvtIds: playerSvtIds,
      playerCeIds: playerCeIds,
      mysticCodeId: mcId,
      mysticCodeLevel: mcLevel,
    );
  }

  // ---------------------------------------------------------------------------
  // CE-inclusive team signature (for within-PatternPass dedup)
  // ---------------------------------------------------------------------------

  /// Canonical CE-inclusive signature for a [CandidateTeam].
  ///
  /// Format: `"svtId1:ceId1,svtId2:ceId2_supportId:0_mcId"` where pairs are
  /// sorted by svtId so the key is order-independent. CE 0 means no CE.
  static String _teamSig(CandidateTeam c) {
    final pairs = List.generate(
      c.playerSvtIds.length,
      (i) => (c.playerSvtIds[i], c.playerCeIds[i] ?? 0),
    )..sort((a, b) => a.$1.compareTo(b.$1));
    final svtCePart = pairs.map((p) => '${p.$1}:${p.$2}').join(',');
    return '${svtCePart}_${c.supportSvtId}:${c.supportCeId ?? 0}_${c.mysticCodeId ?? 0}';
  }
}
