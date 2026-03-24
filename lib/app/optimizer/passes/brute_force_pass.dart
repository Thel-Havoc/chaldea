/// BruteForcePass — exhaustive turn-assignment enumeration for non-battery skills.
///
/// This is the slowest pass (potentially days). Where RulesPass places each
/// non-battery, non-enumerated skill on T1 or T3 based on isTimeSensitive,
/// BruteForcePass tries all combinations of {T1, T2, T3} for those skills
/// (3^N variants per candidate, N = number of non-battery non-enumerated skills).
///
/// This catches teams that only work when a 1-turn damage buff lands on a
/// specific turn that the isTimeSensitive heuristic doesn't predict — e.g.
/// Oberon S3 or Koyanskaya buffs that don't set Turn=1 in their svals.
///
/// Current status: stub — returns an empty stream.
/// The pass wiring is in place; implementation is deferred until the Rules pass
/// has been validated against a wide enough set of nodes to establish which
/// cases it misses.
///
/// Implementation plan:
///   1. For each candidate, gather all non-battery non-enumerated schedulable skills
///   2. Enumerate all len(skills)^3 turn assignments {T1, T2, T3}
///   3. For each assignment, build a TeamSpec (reusing CandidateConverter internals)
///   4. Yield the spec — the engine deduplicates against RulesPass output before
///      simulating, so only genuinely new assignments cost simulation time
library;

import '../simulation/headless_runner.dart';
import 'optimizer_pass.dart';

class BruteForcePass implements OptimizerPass {
  @override
  String get name => 'Brute Force';

  @override
  Stream<TeamSpec> generate(PassContext ctx) async* {
    // Stub — implementation pending.
    // TODO: enumerate {T1,T2,T3} for every non-battery non-enumerated skill.
  }
}
