/// RunRecord + RunHistory — persists optimizer run results as JSONL.
///
/// Each time the optimizer finds a clearing spec, it creates a [RunRecord]
/// and appends it to a [RunHistory] JSONL file (one JSON object per line).
///
/// The JSONL file lives alongside the roster JSON files in the optimizer
/// profiles directory (e.g. `optimizer_profiles/history_<questId>.jsonl`).
/// Append-only writes make it crash-safe: a partial write produces a blank or
/// malformed line that [RunHistory.loadAll] silently skips.
///
/// Future use: once the file has enough data, a pattern matcher can front-run
/// the full search by replaying known-good team archetypes.
library;

import 'dart:convert';
import 'dart:io';

import 'package:chaldea/models/models.dart';

// ---------------------------------------------------------------------------
// QuestFingerprint — wave/class/HP summary for cross-quest similarity matching
// ---------------------------------------------------------------------------

/// Compact descriptor of a quest's enemy composition.
///
/// Stored on every [RunRecord] so [PatternPass] can compare historical clears
/// against new quests without needing the original [QuestPhase] on disk.
/// Stages with no enemies (cutscene/transition stages) are excluded.
class QuestFingerprint {
  final int waveCount;

  /// Sorted class IDs of enemies per wave (non-empty stages only).
  final List<List<int>> classIdsPerWave;

  /// Sum of all enemy HP per wave (non-empty stages only).
  final List<int> totalHpPerWave;

  const QuestFingerprint({
    required this.waveCount,
    required this.classIdsPerWave,
    required this.totalHpPerWave,
  });

  factory QuestFingerprint.fromQuestPhase(QuestPhase quest) {
    final classIdsPerWave = <List<int>>[];
    final totalHpPerWave = <int>[];
    for (final stage in quest.stages) {
      if (stage.enemies.isEmpty) continue;
      final classes = stage.enemies.map((e) => e.svt.classId).toList()..sort();
      final totalHp = stage.enemies.fold(0, (sum, e) => sum + e.hp);
      classIdsPerWave.add(classes);
      totalHpPerWave.add(totalHp);
    }
    return QuestFingerprint(
      waveCount: classIdsPerWave.length,
      classIdsPerWave: classIdsPerWave,
      totalHpPerWave: totalHpPerWave,
    );
  }

  /// Returns a similarity score in [0.0, 1.0] between this fingerprint and
  /// [other]. Wave count must match exactly; class and HP distributions are
  /// compared per wave.
  ///
  /// Score = 0.6 × (average per-wave class Jaccard) + 0.4 × (average per-wave HP ratio).
  double similarityTo(QuestFingerprint other) {
    if (waveCount != other.waveCount || waveCount == 0) return 0.0;

    double classScore = 0.0;
    double hpScore = 0.0;

    for (int i = 0; i < waveCount; i++) {
      final a = classIdsPerWave[i].toSet();
      final b = other.classIdsPerWave[i].toSet();
      final intersection = a.intersection(b).length;
      final union = a.union(b).length;
      classScore += union > 0 ? intersection / union : 1.0;

      final hpA = totalHpPerWave[i];
      final hpB = other.totalHpPerWave[i];
      if (hpA > 0 && hpB > 0) {
        hpScore += hpA < hpB ? hpA / hpB : hpB / hpA;
      } else if (hpA == 0 && hpB == 0) {
        hpScore += 1.0;
      }
      // one side is 0 and the other isn't → hpScore += 0
    }

    return 0.6 * (classScore / waveCount) + 0.4 * (hpScore / waveCount);
  }

  Map<String, dynamic> toJson() => {
        'waveCount': waveCount,
        'classIdsPerWave': classIdsPerWave,
        'totalHpPerWave': totalHpPerWave,
      };

  factory QuestFingerprint.fromJson(Map<String, dynamic> json) =>
      QuestFingerprint(
        waveCount: json['waveCount'] as int,
        classIdsPerWave: (json['classIdsPerWave'] as List)
            .map((w) => (w as List).cast<int>())
            .toList(),
        totalHpPerWave: (json['totalHpPerWave'] as List).cast<int>(),
      );
}

/// A single optimizer run result: the spec that cleared, the turn count,
/// which quest it cleared, and when it was found.
class RunRecord {
  final DateTime timestamp;
  final int questId;
  final int questPhase;
  final int totalTurns;
  final BattleShareData battleData;

  /// Whether the spec also clears at minimum damage (no RNG required).
  /// true  → guaranteed clear every attempt.
  /// false → only confirmed at max damage; may fail on bad RNG.
  final bool clearsAtMinDamage;

  /// Quest composition fingerprint — used by PatternPass to match this clear
  /// against future quests with similar enemy structure. Null on old records
  /// written before fingerprinting was introduced (those records are skipped
  /// by PatternPass).
  final QuestFingerprint? questFingerprint;

  /// The optimizer pass that found this clear (e.g. 'Shared', 'Pattern',
  /// 'Rules'). Null on records written before pass attribution was added.
  final String? passName;

  /// For PatternPass clears: the source quest ID from whose history this team
  /// was drawn. Null for all other passes.
  final int? sourceQuestId;

  RunRecord({
    required this.timestamp,
    required this.questId,
    required this.questPhase,
    required this.totalTurns,
    required this.battleData,
    this.clearsAtMinDamage = false,
    this.questFingerprint,
    this.passName,
    this.sourceQuestId,
  });

  /// Returns a copy of this record with [fp] stamped in.
  /// Used by the engine to set the fingerprint on records returned from workers.
  RunRecord withFingerprint(QuestFingerprint fp) => RunRecord(
        timestamp: timestamp,
        questId: questId,
        questPhase: questPhase,
        totalTurns: totalTurns,
        clearsAtMinDamage: clearsAtMinDamage,
        battleData: battleData,
        questFingerprint: fp,
        passName: passName,
        sourceQuestId: sourceQuestId,
      );

  /// Returns a copy of this record with pass attribution stamped in.
  /// [pass] is the name of the optimizer pass (e.g. 'Pattern', 'Rules').
  /// [source] is the source quest ID for PatternPass clears; null for others.
  RunRecord withPassAttribution(String pass, int? source) => RunRecord(
        timestamp: timestamp,
        questId: questId,
        questPhase: questPhase,
        totalTurns: totalTurns,
        clearsAtMinDamage: clearsAtMinDamage,
        battleData: battleData,
        questFingerprint: questFingerprint,
        passName: pass,
        sourceQuestId: source,
      );

  /// Number of skill button presses in the action log.
  /// Used for sorting results by least button presses.
  int get buttonPresses => battleData.actions
      .where((a) => a.type == BattleRecordDataType.skill)
      .length;

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'questId': questId,
        'questPhase': questPhase,
        'totalTurns': totalTurns,
        'clearsAtMinDamage': clearsAtMinDamage,
        'battleData': battleData.toJson(),
        if (questFingerprint != null) 'questFingerprint': questFingerprint!.toJson(),
        if (passName != null) 'passName': passName,
        if (sourceQuestId != null) 'sourceQuestId': sourceQuestId,
      };

  factory RunRecord.fromJson(Map<String, dynamic> json) => RunRecord(
        timestamp: DateTime.parse(json['timestamp'] as String),
        questId: json['questId'] as int,
        questPhase: json['questPhase'] as int,
        totalTurns: json['totalTurns'] as int,
        clearsAtMinDamage: json['clearsAtMinDamage'] as bool? ?? false,
        battleData:
            BattleShareData.fromJson(json['battleData'] as Map<String, dynamic>),
        questFingerprint: json['questFingerprint'] != null
            ? QuestFingerprint.fromJson(
                json['questFingerprint'] as Map<String, dynamic>)
            : null,
        passName: json['passName'] as String?,
        sourceQuestId: json['sourceQuestId'] as int?,
      );
}

/// Append-only JSONL log of optimizer run results.
///
/// Usage:
///   final history = RunHistory('optimizer_profiles/history_94093408.jsonl');
///   history.append(record);
///   final allClears = history.loadAll();
class RunHistory {
  final String filePath;

  RunHistory(this.filePath);

  /// Appends [record] to the history file, creating it if it doesn't exist.
  void append(RunRecord record) {
    final file = File(filePath);
    final line = '${jsonEncode(record.toJson())}\n';
    file.writeAsStringSync(line, mode: FileMode.append, flush: true);
  }

  /// Loads all records from the history file.
  /// Returns an empty list if the file doesn't exist.
  /// Malformed lines are silently skipped (crash-safe).
  List<RunRecord> loadAll() {
    final file = File(filePath);
    if (!file.existsSync()) return [];

    final records = <RunRecord>[];
    for (final line in file.readAsLinesSync()) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final json = jsonDecode(trimmed) as Map<String, dynamic>;
        records.add(RunRecord.fromJson(json));
      } catch (_) {
        // Skip malformed lines — don't let one bad entry corrupt the rest.
      }
    }
    return records;
  }

  /// Loads records for a specific quest, optionally filtered by phase.
  List<RunRecord> loadForQuest(int questId, {int? phase}) {
    return loadAll().where((r) {
      if (r.questId != questId) return false;
      if (phase != null && r.questPhase != phase) return false;
      return true;
    }).toList();
  }
}
