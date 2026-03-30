/// PatternPass — history replay pass (FUTURE — NOT YET ACTIVE).
///
/// This pass will use DIFFERENT logic from RulesPass. Rather than enumerating
/// all candidate teams from scratch, it will replay known-clearing TeamSpecs
/// from prior runs stored in RunHistory. It is dispatch-compatible with the
/// engine's spec-level path (generate() yields TeamSpec directly), so it runs
/// before candidate enumeration — if a prior clearing spec still works on the
/// current node, the run ends in seconds rather than hours.
///
/// Current status: stub — returns an empty stream.
/// Implementation is deferred until enough clearing runs have accumulated in
/// the history file for matching to be reliable.
///
/// Implementation plan (deferred):
///   1. Load RunRecords from ctx.history for quests similar to ctx.quest
///   2. For each record, reconstruct the TeamSpec from BattleShareData
///   3. Verify each servant in the record is available in ctx.roster
///   4. Yield the spec — engine simulates it via the spec-level path and
///      records a new clear if it succeeds on the current quest
library;

import '../simulation/headless_runner.dart';
import 'optimizer_pass.dart';

class PatternPass implements OptimizerPass {
  @override
  String get name => 'Pattern';

  @override
  Stream<TeamSpec> generate(PassContext ctx) async* {
    // No patterns yet — returns immediately.
    // ignore: dead_code
    if (ctx.history == null) return;
    // TODO: implement pattern replay when RunHistory has sufficient data.
  }
}
