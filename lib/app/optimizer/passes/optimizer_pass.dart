/// OptimizerPass — interface and context for multi-pass team simulation.
///
/// The optimizer runs team simulation in ordered passes. Earlier passes are
/// fast (minutes) and find obvious solutions; later passes expand the search
/// space progressively (hours, then days). Cross-pass deduplication by
/// CE-inclusive team signature ensures each unique team is simulated at
/// most once across all passes.
///
/// Pass ordering (fastest to slowest):
///   1. SharedPass      — community-proven teams from the Chaldea API
///   2. PatternPass     — replay prior clearing runs from RunHistory
///   3. RulesPass       — heuristic CE selection; smart servant ordering
///   4. BruteForcePass  — broader CE scope; exhaustive skill-timing enumeration
///
/// Passes that use candidate-level dispatch (RulesPass, BruteForcePass)
/// implement [createCandidateSource] to provide their own [CandidateSource].
/// Passes that handle their own dispatch (SharedPass, PatternPass) are
/// handled inline by the engine and return null from [createCandidateSource].
///
/// See notes/design_decisions.md §"Multi-Pass Optimizer Architecture".
library;

import 'package:chaldea/models/models.dart';

import '../roster/run_history.dart';
import '../roster/user_roster.dart';
import '../search/candidate_source.dart';

// ---------------------------------------------------------------------------
// PassContext
// ---------------------------------------------------------------------------

/// Shared inputs available to every pass.
///
/// Passes should only read from this context — they do not modify it.
class PassContext {
  /// The quest being optimised for.
  final QuestPhase quest;

  /// The player's roster (servants, CEs, MCs).
  final UserRoster roster;

  /// Prior clearing runs recorded to disk, or null if no history file exists yet.
  /// Used by PatternPass to replay known-good teams on the current quest.
  final RunHistory? history;

  const PassContext({
    required this.quest,
    required this.roster,
    this.history,
  });
}

// ---------------------------------------------------------------------------
// OptimizerPass
// ---------------------------------------------------------------------------

/// Abstract base for a single optimizer pass.
abstract class OptimizerPass {
  const OptimizerPass();

  /// Human-readable name shown in progress/logging output.
  String get name;

  /// Returns a [CandidateSource] for this pass.
  ///
  /// Passes that enumerate candidates (RulesPass, BruteForcePass) override
  /// this to return their own source with pass-specific servant ordering and
  /// CE selection logic.
  ///
  /// Passes that handle their own dispatch (SharedPass, PatternPass) return
  /// null — the engine handles them via inline [is PassType] checks.
  CandidateSource? createCandidateSource(PassContext ctx) => null;
}
