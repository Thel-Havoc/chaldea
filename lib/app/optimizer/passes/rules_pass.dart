/// RulesPass — candidate-level pass using heuristic CE selection.
///
/// Delegates candidate generation to [RulesPassCandidateSource], which
/// currently uses the same [Enumerator] + [Pruner] logic as the old global
/// pre-generation step. CE selection will be upgraded to smart Buster
/// min-charge calculation and Arts multi-tier cascade in a future change
/// without requiring modifications outside of [RulesPassCandidateSource].
///
/// Spec generation (converting a [CandidateTeam] into [TeamSpec]s) is done
/// by the worker pool via [CandidateConverter] — this pass only decides
/// *which* candidates to dispatch, not how to expand them into specs.
///
/// See notes/design_decisions.md §"CandidateTeam → TeamSpec".
library;

import '../search/candidate_source.dart';
import '../search/rules_pass_candidate_source.dart';
import 'optimizer_pass.dart';

class RulesPass extends OptimizerPass {
  @override
  String get name => 'Rules';

  @override
  CandidateSource createCandidateSource(PassContext ctx) =>
      RulesPassCandidateSource(ctx.quest, ctx.roster);
}
