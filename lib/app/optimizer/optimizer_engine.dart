/// OptimizerEngine — wires the full multi-pass search pipeline end-to-end.
///
/// Pipeline:
///   Enumerator → pruning → [per-pass dispatch]
///     └→ PatternPass    (serial, tiny — history replay, <100 specs)
///     └→ RulesPass      (parallel, candidate-level — each worker owns one team)
///     └→ BruteForcePass (parallel, candidate-level — same dispatch model)
///
/// Dispatch model:
///   The dispatch unit is a [CandidateTeam], not a [TeamSpec]. Each worker
///   receives one candidate, generates all specs for it internally via
///   CandidateConverter, simulates them, and returns a [CandidateResult].
///   This eliminates the per-spec round-trip overhead that previously made the
///   engine isolate the throughput ceiling.
///
/// Cancellation:
///   [isCancelled] is polled between candidate dispatches. The engine runner
///   wires this to a control port so the UI can send a stop signal that takes
///   effect as soon as the current in-flight candidates complete.
///
/// Concurrency: [workerCount] Dart Isolates run candidates in parallel. A
/// semaphore limits in-flight dispatches to [workerCount] at a time.
///
/// Usage:
///   final engine = OptimizerEngine(
///     quest: questPhase,
///     roster: userRoster,
///     historyFilePath: 'optimizer_profiles/history_94093408.jsonl',
///   );
///   final clears = await engine.run();
library;

import 'dart:async';
import 'dart:collection';
import 'dart:ui' show RootIsolateToken;

import 'package:chaldea/models/models.dart';

import 'passes/optimizer_pass.dart';
import 'passes/pattern_pass.dart';
import 'passes/rules_pass.dart';
import 'roster/run_history.dart';
import 'roster/user_roster.dart';
import 'search/enumerator.dart';
import 'search/pruner.dart';
import 'simulation/headless_runner.dart'
    show CandidateResult, SimulationOutcome;
import 'simulation/headless_worker_pool.dart';
import 'simulation/share_data_converter.dart';

class OptimizerEngine {
  final QuestPhase quest;
  final UserRoster roster;

  /// If non-null, every clearing [RunRecord] is appended to this JSONL file.
  final String? historyFilePath;

  /// Called periodically with (specsSimulated, clearsFound).
  /// With candidate-level dispatch this fires once per completed team, so the
  /// spec count advances in larger jumps than before.
  final void Function(int checked, int cleared, int engineMs)? onProgress;
  final int progressInterval;

  /// Called immediately when a clearing spec is found.
  final void Function(RunRecord record)? onClear;

  /// Called when a spec produces a [SimulationOutcome.error] result.
  final void Function(String errorMessage)? onSimulationError;

  /// Called each time a worker subprocess dies. [totalDeaths] is cumulative.
  final void Function(int totalDeaths)? onWorkerDied;

  /// Called once after pruning, before simulation begins.
  final void Function(int candidatesTotal, int gate1Blocked, int gate2Blocked)?
      onGateStats;

  /// Called once at the end of [run] with per-servant simulation stats.
  final void Function(
    Map<int, int> specsPerSvt,
    Map<int, int> clearsPerSvt,
  )? onServantStats;

  /// Called each time a candidate is dispatched to a worker.
  /// [processed] is 1-based; [total] is the number of candidates that passed pruning.
  final void Function(int processed, int total)? onCandidateProcessed;

  /// Called once at the end of [run] with summary stats for MC type breakdown.
  /// [specsGenerated] = total specs from converter (post-dedup, pre-early-exit).
  /// [plugSuitCandidates] = number of candidates that used Plug Suit MC.
  /// [plugSuitSpecsGenerated] = total specs generated for Plug Suit candidates.
  /// [plugSuitSpecsChecked] = total specs simulated for Plug Suit candidates.
  final void Function(
    int specsGenerated,
    int plugSuitCandidates,
    int plugSuitSpecsGenerated,
    int plugSuitSpecsChecked,
  )? onRunStats;

  /// Stop after finding this many clears. 0 = run all candidates.
  final int maxClears;

  /// When true (default), each worker stops after the first clearing spec for
  /// its assigned team. Set to false to collect all clearing variants.
  final bool oneClearPerCandidate;

  /// Passes to run, in order. Defaults to [PatternPass, RulesPass, BruteForcePass].
  final List<OptimizerPass>? passes;

  /// Number of parallel worker Isolates. Defaults to 1.
  final int workerCount;

  /// Token from the root Flutter isolate — passed through to the worker pool.
  final RootIsolateToken? rootIsolateToken;

  /// Polled between candidate dispatches. When it returns true the engine
  /// finishes any in-flight candidates and exits cleanly. Wired to the
  /// engine runner's control port in normal operation.
  final bool Function()? isCancelled;

  OptimizerEngine({
    required this.quest,
    required this.roster,
    this.historyFilePath,
    this.onProgress,
    this.progressInterval = 50,
    this.onClear,
    this.onSimulationError,
    this.onWorkerDied,
    this.onGateStats,
    this.onServantStats,
    this.onCandidateProcessed,
    this.onRunStats,
    this.maxClears = 0,
    this.oneClearPerCandidate = true,
    this.passes,
    this.workerCount = 1,
    this.rootIsolateToken,
    this.isCancelled,
  });

  Future<List<RunRecord>> run() async {
    final pool = HeadlessWorkerPool(
      quest: quest,
      roster: roster,
      size: workerCount,
      rootIsolateToken: rootIsolateToken,
      onWorkerDied: onWorkerDied,
    );
    final history = historyFilePath != null ? RunHistory(historyFilePath!) : null;

    pool.warmUp();

    // Pre-generate and prune candidates once, shared across all passes.
    final enumerator = Enumerator(roster: roster, quest: quest);
    final pruner = Pruner(quest: quest, roster: roster);
    final candidates =
        enumerator.candidates().where(pruner.passes).toList();

    onGateStats?.call(
      candidates.length + pruner.gate1Blocked + pruner.gate2Blocked,
      pruner.gate1Blocked,
      pruner.gate2Blocked,
    );

    final ctx = PassContext(
      quest: quest,
      roster: roster,
      candidates: candidates,
      history: history,
    );

    // RulesPass is excluded from the default list until it is implemented with
    // PatternPass uses spec-level dispatch (generate()). RulesPass uses the
    // candidate-level dispatch below (the non-PatternPass branch). BruteForcePass
    // is excluded until implemented — it also falls into the candidate-level
    // branch and would double-dispatch every candidate if included as a stub.
    final activePasses = passes ?? [PatternPass(), RulesPass()];

    final clears = <RunRecord>[];
    final svtSpecCounts = <int, int>{};
    final svtClearCounts = <int, int>{};
    int checked = 0;
    bool done = false;
    int specsGenerated = 0;
    int plugSuitCandidates = 0;
    int plugSuitSpecsGenerated = 0;
    int plugSuitSpecsChecked = 0;

    // ---------------------------------------------------------------------------
    // Helper: accumulate per-servant stats from a completed candidate result.
    // ---------------------------------------------------------------------------
    void accumulateStats(CandidateTeam candidate, CandidateResult result) {
      final svtIds = [
        ...candidate.playerSvtIds,
        candidate.supportSvtId,
      ];
      for (final id in svtIds) {
        svtSpecCounts[id] = (svtSpecCounts[id] ?? 0) + result.specsChecked;
        if (result.clears.isNotEmpty) {
          svtClearCounts[id] =
              (svtClearCounts[id] ?? 0) + result.clears.length;
        }
      }
    }

    try {
      for (final pass in activePasses) {
        if (done || (isCancelled?.call() ?? false)) break;

        if (pass is PatternPass) {
          // ---------------------------------------------------------------------------
          // PatternPass: serial inline dispatch (tiny — history replay, <100 specs).
          // Run individual specs through the pool so workers are reused once ready.
          // ---------------------------------------------------------------------------
          await for (final spec in pass.generate(ctx)) {
            if (done || (isCancelled?.call() ?? false)) break;
            try {
              final result = await pool.run(spec);
              checked++;
              if (result.outcome == SimulationOutcome.error) {
                onSimulationError
                    ?.call(result.errorMessage ?? 'unknown error');
              }
              if (result.cleared) {
                final minResult =
                    await pool.run(spec, pessimistic: true);
                final shareData =
                    ShareDataConverter.convert(quest, spec);
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
                if (maxClears > 0 && clears.length >= maxClears) {
                  done = true;
                }
              }
            } catch (e, st) {
              onSimulationError?.call('Pattern spec error: $e\n$st');
            }
          }
          onProgress?.call(checked, clears.length, DateTime.now().millisecondsSinceEpoch);
          continue;
        }

        // ---------------------------------------------------------------------------
        // Candidate-level passes (RulesPass, BruteForcePass, and future passes).
        // Each worker owns one full team for the duration of its dispatch.
        // ---------------------------------------------------------------------------
        final semaphore = _Semaphore(workerCount);
        final inFlight = <Future<void>>[];
        int candidatesDispatched = 0;

        for (final candidate in ctx.candidates) {
          if (done || (isCancelled?.call() ?? false)) break;

          candidatesDispatched++;
          onCandidateProcessed?.call(candidatesDispatched, candidates.length);

          await semaphore.acquire();
          if (done || (isCancelled?.call() ?? false)) {
            semaphore.release();
            break;
          }

          // Capture for the closure.
          final cap = candidate;
          inFlight.add(() async {
            try {
              final result = await pool.runCandidate(
                cap,
                oneClearPerCandidate: oneClearPerCandidate,
              );

              checked += result.specsChecked;

              if (result.simulationErrors > 0) {
                onSimulationError
                    ?.call('${result.simulationErrors} error(s) in team');
              }

              accumulateStats(cap, result);

              specsGenerated += result.specsGenerated;
              final isPlugSuit =
                  cap.mysticCodeId == 20 || cap.mysticCodeId == 210;
              if (isPlugSuit) {
                plugSuitCandidates++;
                plugSuitSpecsGenerated += result.specsGenerated;
                plugSuitSpecsChecked += result.specsChecked;
              }

              for (final record in result.clears) {
                clears.add(record);
                history?.append(record);
                onClear?.call(record);
                if (maxClears > 0 && clears.length >= maxClears) {
                  done = true;
                  break;
                }
              }

              onProgress?.call(checked, clears.length, DateTime.now().millisecondsSinceEpoch);
            } catch (e, st) {
              onSimulationError?.call('Candidate dispatch error: $e\n$st');
            } finally {
              semaphore.release();
            }
          }());
        }

        if (inFlight.isNotEmpty) await Future.wait(inFlight);
      }
    } finally {
      pool.dispose();
    }

    onProgress?.call(checked, clears.length, DateTime.now().millisecondsSinceEpoch);
    onServantStats?.call(svtSpecCounts, svtClearCounts);
    onRunStats?.call(
      specsGenerated,
      plugSuitCandidates,
      plugSuitSpecsGenerated,
      plugSuitSpecsChecked,
    );

    return clears;
  }

}

// ---------------------------------------------------------------------------
// _Semaphore — limits the number of concurrently in-flight async tasks
// ---------------------------------------------------------------------------

class _Semaphore {
  _Semaphore(this._count);

  int _count;
  final _waiters = Queue<Completer<void>>();

  Future<void> acquire() {
    if (_count > 0) {
      _count--;
      return Future.value();
    }
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    } else {
      _count++;
    }
  }
}
