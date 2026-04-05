/// BruteForcePass — exhaustive CE/skill-timing enumeration (FUTURE — NOT YET ACTIVE).
///
/// Delegates candidate generation to [BruteForcePassCandidateSource], which
/// is currently a stub with the same logic as [RulesPassCandidateSource].
/// Cross-pass deduplication means candidates already dispatched by RulesPass
/// are skipped by the engine, so including BruteForce in the active pass list
/// before it has distinct logic produces no duplicate work.
///
/// Planned divergences from RulesPass (to be implemented in
/// [BruteForcePassCandidateSource] without changes here):
///   - Broader CE selection: includes OC-boosting CEs (Duke of Flame, etc.)
///     and unusual combinations excluded by the RulesPass charge heuristic.
///   - Exhaustive skill-timing: enumerates all {T1,T2,T3} assignments for
///     non-battery non-enumerated skills (3^N variants per candidate) to catch
///     teams that only clear when a 1-turn buff lands on a specific turn.
///   - Different servant ordering: may include ST NP servants and other
///     compositions deprioritised by the RulesPass heuristic.
///
/// Current status: stub — NOT included in the default pass list.
library;

import '../search/brute_force_candidate_source.dart';
import '../search/candidate_source.dart';
import 'optimizer_pass.dart';

class BruteForcePass extends OptimizerPass {
  @override
  String get name => 'Brute Force';

  @override
  CandidateSource createCandidateSource(PassContext ctx) =>
      BruteForcePassCandidateSource(ctx.quest, ctx.roster);
}
