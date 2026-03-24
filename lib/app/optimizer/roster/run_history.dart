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

import 'package:chaldea/models/userdata/battle.dart';

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

  RunRecord({
    required this.timestamp,
    required this.questId,
    required this.questPhase,
    required this.totalTurns,
    required this.battleData,
    this.clearsAtMinDamage = false,
  });

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
      };

  factory RunRecord.fromJson(Map<String, dynamic> json) => RunRecord(
        timestamp: DateTime.parse(json['timestamp'] as String),
        questId: json['questId'] as int,
        questPhase: json['questPhase'] as int,
        totalTurns: json['totalTurns'] as int,
        clearsAtMinDamage: json['clearsAtMinDamage'] as bool? ?? false,
        battleData:
            BattleShareData.fromJson(json['battleData'] as Map<String, dynamic>),
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
