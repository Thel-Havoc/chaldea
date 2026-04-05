/// CandidateSource — interface for per-pass candidate generation.
///
/// Each pass that uses candidate-level dispatch owns one [CandidateSource].
/// Candidates are generated eagerly on construction so that [gate1Blocked]
/// and [gate2Blocked] are available before dispatch begins (the engine
/// reports these to the UI via [OptimizerEngine.onGateStats]).
///
/// Different passes can use different servant ordering, CE selection, or
/// pruning strategies by implementing this interface independently.
/// See [RulesPassCandidateSource] and [BruteForcePassCandidateSource].
library;

import 'enumerator.dart';

abstract class CandidateSource {
  /// All candidates that passed pruning, in priority order.
  List<CandidateTeam> get candidates;

  /// Total candidates generated before pruning
  /// (= candidates.length + gate1Blocked + gate2Blocked).
  int get total;

  /// Number of candidates blocked by Gate 1 (NP charge floor check).
  int get gate1Blocked;

  /// Number of candidates blocked by Gate 2 (damage estimate check).
  int get gate2Blocked;
}
