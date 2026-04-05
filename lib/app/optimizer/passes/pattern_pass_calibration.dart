/// PatternPassCalibration — self-adjusting threshold for cross-quest matching.
///
/// Tracks how often Pattern Pass teams at each similarity score bucket actually
/// clear the target quest. After enough attempts, buckets with a low success
/// rate are suppressed so the pass stops wasting simulation time on guesses
/// that history has shown don't transfer.
///
/// Score buckets are discretised at 0.05 increments (key = (score × 20).floor()).
/// For example, score 0.67 → key 13 (covers 0.65–0.70).
///
/// Cold-start behaviour: if a bucket has fewer than [minAttemptsForFilter]
/// recorded attempts, [shouldTry] returns true (optimistic exploration).
/// Once data accumulates, only buckets with a success rate ≥ [minSuccessRate]
/// are tried.
///
/// Only genuine simulation outcomes (clear or not-clear) are recorded.
/// Attempts skipped because the player doesn't own a required servant do NOT
/// count — they say nothing about whether the strategy would work.
library;

import 'dart:convert';
import 'dart:io';

class PatternPassCalibration {
  static const int minAttemptsForFilter = 10;
  static const double minSuccessRate = 0.15;

  final Map<int, ({int attempts, int clears})> _buckets;

  PatternPassCalibration._(this._buckets);

  // ---------------------------------------------------------------------------
  // Query
  // ---------------------------------------------------------------------------

  /// Returns true if [score] should be tried based on historical success data.
  ///
  /// Always returns true when there is insufficient data for the bucket
  /// (fewer than [minAttemptsForFilter] attempts).
  bool shouldTry(double score) {
    final bucket = _buckets[_key(score)];
    if (bucket == null || bucket.attempts < minAttemptsForFilter) return true;
    return bucket.clears / bucket.attempts >= minSuccessRate;
  }

  // ---------------------------------------------------------------------------
  // Update
  // ---------------------------------------------------------------------------

  /// Records the outcome of one Pattern Pass simulation attempt.
  ///
  /// [score] is the fingerprint similarity score (0.0–1.0).
  /// [cleared] is true if the simulation succeeded.
  void record(double score, {required bool cleared}) {
    final key = _key(score);
    final existing = _buckets[key] ?? (attempts: 0, clears: 0);
    _buckets[key] = (
      attempts: existing.attempts + 1,
      clears: existing.clears + (cleared ? 1 : 0),
    );
  }

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------

  /// Saves calibration data to [path] as a compact JSON file.
  /// Creates or overwrites the file; safe to call from a background isolate.
  void save(String path) {
    try {
      final data = {
        for (final e in _buckets.entries)
          '${e.key}': {'attempts': e.value.attempts, 'clears': e.value.clears},
      };
      File(path).writeAsStringSync(jsonEncode(data));
    } catch (_) {
      // Non-fatal — calibration data is advisory only.
    }
  }

  /// Loads calibration data from [path].
  /// Returns an empty calibration (all buckets unseen) if the file does not
  /// exist or cannot be parsed.
  static PatternPassCalibration load(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return PatternPassCalibration._({});
      final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final buckets = <int, ({int attempts, int clears})>{};
      for (final e in raw.entries) {
        final key = int.tryParse(e.key);
        if (key == null) continue;
        final v = e.value as Map<String, dynamic>;
        buckets[key] = (
          attempts: v['attempts'] as int? ?? 0,
          clears: v['clears'] as int? ?? 0,
        );
      }
      return PatternPassCalibration._(buckets);
    } catch (_) {
      return PatternPassCalibration._({});
    }
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  static int _key(double score) => (score * 20).floor();
}
