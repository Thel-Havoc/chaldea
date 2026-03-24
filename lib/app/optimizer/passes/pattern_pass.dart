/// PatternPass — replays prior clearing runs from RunHistory.
///
/// This is the fastest pass (minutes). It loads TeamSpecs from prior successful
/// runs recorded in the RunHistory JSONL file, then replays them on the current
/// quest. If the same team structure clears a similar node, it likely clears
/// this one too — and we find out almost immediately.
///
/// Current status: stub — returns an empty stream.
/// The pass wiring is in place; pattern replay will be implemented once enough
/// clearing runs have accumulated in the history file to make matching useful.
///
/// Future implementation plan:
///   1. Load all RunRecords from ctx.history (or just those for similar quests)
///   2. For each record, reconstruct the TeamSpec from BattleShareData
///   3. Verify servants in the record are available in ctx.roster
///   4. Yield the spec — the engine will simulate it and record a new clear if
///      it succeeds on the current quest
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
