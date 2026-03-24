/// OptimizerEngine — wires the full multi-pass search pipeline end-to-end.
///
/// Pipeline:
///   Enumerator → [PassContext]
///     └→ PatternPass    (minutes  — replay prior clears from RunHistory)
///     └→ RulesPass      (hours    — CandidateConverter 6-dimension enumeration)
///     └→ BruteForcePass (days     — {T1,T2,T3} exhaustive turn assignment)
///   Each pass yields TeamSpecs → deduplication → HeadlessRunner
///       └→ (on clear) ShareDataConverter → RunHistory
///
/// Deduplication: every TeamSpec is assigned a canonical hash before simulation.
/// A spec whose hash is already in [_simulated] is skipped — no pass ever
/// simulates the same action sequence twice, even if multiple passes generate it.
///
/// Usage:
///   final engine = OptimizerEngine(
///     quest: questPhase,
///     roster: userRoster,
///     historyFilePath: 'optimizer_profiles/history_94093408.jsonl',
///   );
///   final clears = await engine.run();
///
/// [onProgress] fires after every N specs are simulated, giving the UI a
/// chance to update. [maxClears] stops the search early once enough solutions
/// are found (0 = run to completion).
library;

import 'dart:developer' as dev;

import 'package:chaldea/models/models.dart';

import 'passes/brute_force_pass.dart';
import 'passes/optimizer_pass.dart';
import 'passes/pattern_pass.dart';
import 'passes/rules_pass.dart';
import 'roster/run_history.dart';
import 'roster/user_roster.dart';
import 'search/enumerator.dart';
import 'search/pruner.dart';
import 'simulation/headless_runner.dart' show SimulationOutcome, TeamSpec;
import 'simulation/headless_worker.dart';
import 'simulation/share_data_converter.dart';

class OptimizerEngine {
  final QuestPhase quest;
  final UserRoster roster;

  /// If non-null, every clearing [RunRecord] is appended to this JSONL file.
  final String? historyFilePath;

  /// Called periodically with (specsSimulated, clearsFound) so the UI can
  /// show progress. Defaults to every 50 specs simulated.
  final void Function(int checked, int cleared)? onProgress;
  final int progressInterval;

  /// Called immediately when a clearing spec is found, before [run] returns.
  /// Use this to update a live results list while the engine is still running.
  final void Function(RunRecord record)? onClear;

  /// Called when a spec produces a [SimulationOutcome.error] result.
  /// The first error message is passed so the UI can surface it for debugging.
  final void Function(String errorMessage)? onSimulationError;

  /// Stop after finding this many clears. 0 = run all candidates.
  final int maxClears;

  /// Passes to run, in order. Defaults to [PatternPass, RulesPass, BruteForcePass].
  /// Override to run a subset (e.g. tests that only want RulesPass).
  final List<OptimizerPass>? passes;

  OptimizerEngine({
    required this.quest,
    required this.roster,
    this.historyFilePath,
    this.onProgress,
    this.progressInterval = 50,
    this.onClear,
    this.onSimulationError,
    this.maxClears = 0,
    this.passes,
  });

  /// Runs all passes in order and returns every clearing [RunRecord] found.
  ///
  /// Simulation runs in a background Dart Isolate via [HeadlessWorker], so
  /// the main/UI thread is never blocked regardless of how long individual
  /// specs take. Each `await worker.run(spec)` is a genuine async round-trip
  /// that yields to the event loop between specs.
  Future<List<RunRecord>> run() async {
    final enumerator = Enumerator(roster: roster, quest: quest);
    final worker = HeadlessWorker(quest: quest);
    final history = historyFilePath != null ? RunHistory(historyFilePath!) : null;

    // Pre-generate candidates once and prune impossible teams before passing
    // them to any pass. Both gates are fast (arithmetic + skill scan), so this
    // pays back on every non-trivial roster.
    final pruner = Pruner(quest: quest, roster: roster);
    final candidates =
        enumerator.candidates().where(pruner.passes).toList();

    final ctx = PassContext(
      quest: quest,
      roster: roster,
      candidates: candidates,
      history: history,
    );

    final activePasses = passes ?? [PatternPass(), RulesPass(), BruteForcePass()];

    final clears = <RunRecord>[];
    final simulated = <String>{};
    int checked = 0;
    bool done = false;

    try {
      for (final pass in activePasses) {
        if (done) break;

        await for (final spec in pass.generate(ctx)) {
          final key = _canonicalKey(spec);
          if (simulated.contains(key)) continue;
          simulated.add(key);

          dev.Timeline.startSync('spec.simulate');
          final result = await worker.run(spec);
          dev.Timeline.finishSync();
          checked++;

          if (result.outcome == SimulationOutcome.error) {
            onSimulationError?.call(result.errorMessage ?? 'unknown error');
          }

          if (result.cleared) {
            // Re-run at minimum damage to determine if this is a guaranteed clear.
            final minResult = await worker.run(spec, pessimistic: true);
            final shareData = ShareDataConverter.convert(quest, spec);
            final record = RunRecord(
              timestamp: DateTime.now(),
              questId: quest.id,
              questPhase: quest.phase,
              totalTurns: result.totalTurns,
              clearsAtMinDamage: minResult.cleared,
              battleData: shareData,
            );
            clears.add(record);
            history?.append(record);
            onClear?.call(record);
          }

          if (onProgress != null && checked % progressInterval == 0) {
            onProgress!(checked, clears.length);
          }

          if (maxClears > 0 && clears.length >= maxClears) {
            done = true;
            break;
          }
        }
      }
    } finally {
      worker.dispose();
    }

    // Final progress tick so UI reflects completion.
    onProgress?.call(checked, clears.length);

    return clears;
  }

  // ---------------------------------------------------------------------------
  // Canonical hash for deduplication
  // ---------------------------------------------------------------------------

  /// Builds a deterministic string key that uniquely identifies a [TeamSpec]'s
  /// simulation inputs. Two specs with the same servants, CEs, MC, and identical
  /// per-turn action sequences produce the same key and will not be simulated twice.
  ///
  /// Does NOT include quest data — the [simulated] set is per engine run (i.e.
  /// per quest), so cross-quest pollution is not possible.
  static String _canonicalKey(TeamSpec spec) {
    final buf = StringBuffer();

    // Slots: servant ID + CE ID + core per-servant config that affects simulation.
    for (final slot in spec.slots) {
      if (slot == null) {
        buf.write('_|');
      } else {
        buf
          ..write(slot.svt.id)
          ..write(':')
          ..write(slot.ce?.id ?? 0)
          ..write(':')
          ..write(slot.level)
          ..write(':')
          ..write(slot.tdLevel)
          ..write(':')
          ..write(slot.limitCount)
          ..write(':')
          ..write(slot.skillLevels.join(','))
          ..write(':')
          ..write(slot.appendLevels.join(','))
          ..write('|');
      }
    }

    // Mystic Code.
    buf
      ..write('mc:')
      ..write(spec.mysticCode?.id ?? 0)
      ..write(':')
      ..write(spec.mysticCodeLevel)
      ..write('|');

    // Per-turn action sequence.
    for (int t = 0; t < spec.turns.length; t++) {
      final turn = spec.turns[t];
      buf.write('t$t:[');
      for (final a in turn.skills) {
        buf
          ..write(a.slotIndex)
          ..write('/')
          ..write(a.skillIndex)
          ..write('/')
          ..write(a.allyTarget ?? -1)
          ..write(',');
      }
      buf
        ..write(']:np[')
        ..write(turn.npSlots.join(','))
        ..write(']');
      if (turn.orderChange != null) {
        buf
          ..write(':oc[')
          ..write(turn.orderChange!.onFieldSlot)
          ..write(',')
          ..write(turn.orderChange!.backlineSlot)
          ..write(']');
      }
      buf.write('|');
    }

    return buf.toString();
  }
}
