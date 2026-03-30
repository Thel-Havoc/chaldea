/// BruteForcePass — exhaustive turn-assignment enumeration (FUTURE — NOT YET ACTIVE).
///
/// This pass will use DIFFERENT logic from RulesPass. Where RulesPass places
/// skills via the CandidateConverter heuristic (isTimeSensitive, battery rules,
/// topological sort), BruteForcePass will enumerate all combinations of
/// {T1, T2, T3} for non-battery non-enumerated skills (3^N variants per candidate,
/// N = skills not already covered by RulesPass enumeration).
///
/// This catches teams that only clear when a 1-turn buff lands on a specific
/// turn that the heuristic can't predict — e.g. Oberon S3 or Koyanskaya buffs
/// whose svals don't set Turn=1 but whose effect is still turn-dependent.
///
/// Current status: stub — NOT included in the default pass list.
/// BruteForcePass falls into the same candidate-level dispatch path as RulesPass
/// (any non-PatternPass does), so including it before it has its own spec-generation
/// logic would just re-simulate every candidate a second time.
///
/// Implementation plan (deferred until RulesPass is validated):
///   1. For each candidate, gather non-battery non-enumerated schedulable skills
///   2. Enumerate all len(skills)^3 turn assignments {T1, T2, T3}
///   3. Build TeamSpecs (reusing CandidateConverter internals)
///   4. Simulate only specs not already covered by RulesPass output
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
