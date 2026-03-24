/// RulesPass — generates TeamSpecs via CandidateConverter's 6-dimension enumeration.
///
/// This is the core heuristic pass (hours). For each candidate team it calls
/// CandidateConverter, which enumerates:
///   1. NP assignment
///   2. OC turn
///   3. selfBatteryToT1
///   4. concentrateSupport
///   5. mcBatteryTurn
///   6. incomingSkillSplit
///
/// Skills are placed by isTimeSensitive (T1 vs T3) and the dependency graph is
/// resolved by topological sort. Double skill use is scheduled automatically
/// when a CD-reduction skill is present.
///
/// See notes/design_decisions.md §"CandidateTeam → TeamSpec".
library;

import '../candidate_to_team_spec/candidate_converter.dart';
import '../simulation/headless_runner.dart';
import 'optimizer_pass.dart';

class RulesPass implements OptimizerPass {
  @override
  String get name => 'Rules';

  @override
  Stream<TeamSpec> generate(PassContext ctx) async* {
    final converter = CandidateConverter(ctx.roster);
    for (final candidate in ctx.candidates) {
      for (final spec in converter.convert(candidate)) {
        yield spec;
      }
    }
  }
}
