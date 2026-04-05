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

import 'passes/brute_force_pass.dart';
import 'passes/optimizer_pass.dart';
import 'passes/pattern_pass.dart';
import 'passes/rules_pass.dart';
import 'passes/shared_pass.dart';
import 'roster/run_history.dart';
import 'roster/user_roster.dart';
import 'search/enumerator.dart';
import 'simulation/headless_runner.dart' show CandidateResult;
import 'simulation/headless_worker_pool.dart';

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

  /// Called once after the BruteForce pass completes (or dry-run finishes).
  /// [report] keys: 'total', 'gate1Blocked', 'gate2Blocked',
  /// 'dedupSigHits' (skipped by full-team sig), 'dedupSvtHits' (skipped by
  /// servant-set already cleared), 'dispatched', 'clears', 'isDryRun'.
  final void Function(Map<String, dynamic> report)? onBruteForceReport;

  /// When true, the BruteForce pass enumerates and counts dedup hits but does
  /// not dispatch any candidates to workers. Implies [enableBruteForce] = true.
  final bool dryRunBruteForce;

  /// Called once after the SharedPass completes (or is skipped).
  /// [fetched] = community teams returned by the API.
  /// [skipped] = teams the player can't field (missing servant or MC).
  /// [teams]   = teams that were actually dispatched, each with 'supportId',
  ///             'playerIds', optionally 'mcId', and 'cleared'.
  final void Function(int fetched, int skipped, List<Map<String, dynamic>> teams)? onSharedPassReport;

  /// Called once after the PatternPass completes (or is skipped).
  /// [matches] is a list of source-quest groups: each entry has
  /// 'sourceQuestId' (int), 'score' (double), and 'teams' (List of maps
  /// with 'supportId', 'playerIds', and optionally 'mcId').
  final void Function(List<Map<String, dynamic>> matches)? onPatternPassReport;

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
    this.onSharedPassReport,
    this.onPatternPassReport,
    this.onBruteForceReport,
    this.dryRunBruteForce = false,
    this.maxClears = 0,
    this.oneClearPerCandidate = true,
    this.passes,
    this.workerCount = 1,
    this.rootIsolateToken,
    this.isCancelled,
  });

  Future<List<RunRecord>> run() async {
    // Compute once; stamped onto every RunRecord written during this run so
    // PatternPass can match these clears against future quests.
    final questFingerprint = QuestFingerprint.fromQuestPhase(quest);

    final pool = HeadlessWorkerPool(
      quest: quest,
      roster: roster,
      size: workerCount,
      rootIsolateToken: rootIsolateToken,
      onWorkerDied: onWorkerDied,
    );
    final history = historyFilePath != null ? RunHistory(historyFilePath!) : null;

    // Full-team signatures (servants + CEs + MC) dispatched during this run.
    // Any candidate whose sig is already here is skipped unconditionally.
    final seenSigs = <String>{};

    // Servant-set keys (sorted player IDs + support ID, no CEs/MC) that have
    // already produced at least one clear. Once a servant composition clears,
    // all further candidates with the same servants are skipped.
    final clearedSvtSets = <String>{};


    pool.warmUp();

    final ctx = PassContext(
      quest: quest,
      roster: roster,
      history: history,
    );

    final activePasses = passes ?? [RulesPass()];

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

        if (pass is SharedPass) {
          // ---------------------------------------------------------------------------
          // SharedPass: dispatch community teams via runCandidate() so all spec
          // variants are tested. Teams are built from the community CE selection
          // using the player's owned copies. Deduped against seenSigs.
          // Serial dispatch (small — typically < 200 community teams per quest).
          // ---------------------------------------------------------------------------
          int sharedDispatched = 0;
          int sharedSkipped = 0;
          final sharedReport = <Map<String, dynamic>>[];
          for (final encoded in pass.encodedTeams) {
            if (done || (isCancelled?.call() ?? false)) break;
            try {
              final community = BattleShareData.parse(encoded);
              if (community == null) continue;
              final candidate = SharedPass.toCandidateTeam(community, roster);
              if (candidate == null) { sharedSkipped++; continue; } // player doesn't own a required servant/MC

              final sig = _candidateSig(candidate);
              if (seenSigs.contains(sig)) continue;
              if (clearedSvtSets.contains(_svtSetKey(candidate))) continue;
              seenSigs.add(sig);

              sharedDispatched++;
              onCandidateProcessed?.call(sharedDispatched, pass.encodedTeams.length);

              final result = await pool.runCandidate(
                candidate,
                oneClearPerCandidate: oneClearPerCandidate,
              );
              checked += result.specsChecked;

              if (result.simulationErrors > 0) {
                onSimulationError?.call('${result.simulationErrors} error(s) in SharedPass team');
              }

              accumulateStats(candidate, result);
              specsGenerated += result.specsGenerated;

              final cleared = result.clears.isNotEmpty;
              sharedReport.add({
                'supportId': candidate.supportSvtId,
                'playerIds': candidate.playerSvtIds,
                if (candidate.mysticCodeId != null) 'mcId': candidate.mysticCodeId,
                'cleared': cleared,
              });

              if (cleared) clearedSvtSets.add(_svtSetKey(candidate));
              for (final rawRecord in result.clears) {
                final record = rawRecord
                    .withFingerprint(questFingerprint)
                    .withPassAttribution(pass.name, null);
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
              onSimulationError?.call('SharedPass error: $e\n$st');
            }
          }
          onSharedPassReport?.call(pass.encodedTeams.length, sharedSkipped, sharedReport);
          onProgress?.call(checked, clears.length, DateTime.now().millisecondsSinceEpoch);
          continue;
        }

        if (pass is PatternPass) {
          // ---------------------------------------------------------------------------
          // PatternPass: dispatch historically-proven teams (servants + CEs + MC)
          // via runCandidate() so all spec variants are tested. Teams were already
          // validated against the player's roster in PatternPass.prepare().
          // Their CE-inclusive sigs are added to seenSigs for cross-pass dedup.
          // ---------------------------------------------------------------------------
          int patternDispatched = 0;
          try {
            for (final entry in pass.historicalCandidates) {
              if (done || (isCancelled?.call() ?? false)) break;

              final patSig = _candidateSig(entry.team);
              if (seenSigs.contains(patSig)) continue;
              if (clearedSvtSets.contains(_svtSetKey(entry.team))) continue;
              seenSigs.add(patSig);

              patternDispatched++;
              onCandidateProcessed?.call(patternDispatched, pass.historicalCandidates.length);

              try {
                final result = await pool.runCandidate(
                  entry.team,
                  oneClearPerCandidate: oneClearPerCandidate,
                );

                checked += result.specsChecked;
                pass.calibration.record(entry.score, cleared: result.clears.isNotEmpty);

                if (result.simulationErrors > 0) {
                  onSimulationError?.call('${result.simulationErrors} error(s) in PatternPass team');
                }

                accumulateStats(entry.team, result);
                specsGenerated += result.specsGenerated;

                if (result.clears.isNotEmpty) clearedSvtSets.add(_svtSetKey(entry.team));
                for (final rawRecord in result.clears) {
                  final record = rawRecord
                      .withFingerprint(questFingerprint)
                      .withPassAttribution('Pattern', entry.sourceQuestId);
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
                onSimulationError?.call('PatternPass error: $e\n$st');
              }
            }
          } finally {
            pass.calibration.save(pass.calibrationFilePath);
          }
          // Emit Pattern Pass summary for the debug UI.
          _emitPatternPassReport(pass.historicalCandidates, onPatternPassReport);
          onProgress?.call(checked, clears.length, DateTime.now().millisecondsSinceEpoch);
          continue;
        }

        // ---------------------------------------------------------------------------
        // BruteForcePass: candidate-level dispatch with dedup-hit tracking.
        // Handled here (not in the generic loop below) so we can emit a
        // separate per-pass report and support dry-run mode.
        // ---------------------------------------------------------------------------
        if (pass is BruteForcePass) {
          final source = pass.createCandidateSource(ctx);

          int dedupSigHits = 0;
          int dedupSvtHits = 0;
          int bruteForceDispatched = 0;
          int bruteForceClears = 0;

          if (dryRunBruteForce) {
            // Dry run: count what would survive dedup without simulating.
            for (final candidate in source.candidates) {
              if (done || (isCancelled?.call() ?? false)) break;
              if (seenSigs.contains(_candidateSig(candidate))) { dedupSigHits++; continue; }
              if (clearedSvtSets.contains(_svtSetKey(candidate))) { dedupSvtHits++; continue; }
              bruteForceDispatched++;
            }
            onBruteForceReport?.call({
              'total': source.total,
              'gate1Blocked': source.gate1Blocked,
              'gate2Blocked': source.gate2Blocked,
              'dedupSigHits': dedupSigHits,
              'dedupSvtHits': dedupSvtHits,
              'dispatched': bruteForceDispatched,
              'clears': 0,
              'isDryRun': true,
            });
            onProgress?.call(checked, clears.length, DateTime.now().millisecondsSinceEpoch);
            continue;
          }

          // Normal dispatch — same semaphore pattern as the generic loop,
          // with dedup-hit tracking and a dedicated report at the end.
          final semaphore = _Semaphore(workerCount);
          final inFlight = <Future<void>>[];

          for (final candidate in source.candidates) {
            if (done || (isCancelled?.call() ?? false)) break;
            if (seenSigs.contains(_candidateSig(candidate))) { dedupSigHits++; continue; }
            if (clearedSvtSets.contains(_svtSetKey(candidate))) { dedupSvtHits++; continue; }
            seenSigs.add(_candidateSig(candidate));

            bruteForceDispatched++;
            onCandidateProcessed?.call(bruteForceDispatched, source.candidates.length);

            await semaphore.acquire();
            if (done || (isCancelled?.call() ?? false)) { semaphore.release(); break; }

            final cap = candidate;
            inFlight.add(() async {
              try {
                final result = await pool.runCandidate(cap, oneClearPerCandidate: oneClearPerCandidate);
                checked += result.specsChecked;
                if (result.simulationErrors > 0) {
                  onSimulationError?.call('${result.simulationErrors} error(s) in BruteForce team');
                }
                accumulateStats(cap, result);
                specsGenerated += result.specsGenerated;

                if (result.clears.isNotEmpty) {
                  clearedSvtSets.add(_svtSetKey(cap));
                  bruteForceClears += result.clears.length;
                }
                for (final rawRecord in result.clears) {
                  final record = rawRecord
                      .withFingerprint(questFingerprint)
                      .withPassAttribution(pass.name, null);
                  clears.add(record);
                  history?.append(record);
                  onClear?.call(record);
                  if (maxClears > 0 && clears.length >= maxClears) { done = true; break; }
                }
                onProgress?.call(checked, clears.length, DateTime.now().millisecondsSinceEpoch);
              } catch (e, st) {
                onSimulationError?.call('BruteForce error: $e\n$st');
              } finally {
                semaphore.release();
              }
            }());
          }

          if (inFlight.isNotEmpty) await Future.wait(inFlight);
          onBruteForceReport?.call({
            'total': source.total,
            'gate1Blocked': source.gate1Blocked,
            'gate2Blocked': source.gate2Blocked,
            'dedupSigHits': dedupSigHits,
            'dedupSvtHits': dedupSvtHits,
            'dispatched': bruteForceDispatched,
            'clears': bruteForceClears,
            'isDryRun': false,
          });
          onProgress?.call(checked, clears.length, DateTime.now().millisecondsSinceEpoch);
          continue;
        }

        // ---------------------------------------------------------------------------
        // Generic candidate-level passes (RulesPass and future passes).
        // Each pass generates its own candidates via createCandidateSource().
        // Each worker owns one full team for the duration of its dispatch.
        // ---------------------------------------------------------------------------
        final source = pass.createCandidateSource(ctx);
        if (source == null) continue;

        onGateStats?.call(source.total, source.gate1Blocked, source.gate2Blocked);

        final semaphore = _Semaphore(workerCount);
        final inFlight = <Future<void>>[];
        int candidatesDispatched = 0;
        final currentPassName = pass.name;

        for (final candidate in source.candidates) {
          if (done || (isCancelled?.call() ?? false)) break;
          if (seenSigs.contains(_candidateSig(candidate))) continue;
          if (clearedSvtSets.contains(_svtSetKey(candidate))) continue;
          seenSigs.add(_candidateSig(candidate));

          candidatesDispatched++;
          onCandidateProcessed?.call(candidatesDispatched, source.candidates.length);

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

              if (result.clears.isNotEmpty) clearedSvtSets.add(_svtSetKey(cap));
              for (final rawRecord in result.clears) {
                // Records from workers lack the fingerprint — stamp it now.
                final record = rawRecord
                    .withFingerprint(questFingerprint)
                    .withPassAttribution(currentPassName, null);
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
// Cross-pass deduplication helpers
// ---------------------------------------------------------------------------

/// CE-inclusive canonical signature for a [CandidateTeam].
///
/// Format: `"svtId1:ceId1,svtId2:ceId2_supportId:supportCeId_mcId"` where
/// (svtId, ceId) pairs are sorted by svtId so the key is order-independent.
/// CE 0 means no CE assigned to that slot.
///
/// Used for full-team deduplication: a candidate with the same servants,
/// CEs, and MC is never dispatched twice across any passes in a run.
String _candidateSig(CandidateTeam c) {
  final pairs = List.generate(
    c.playerSvtIds.length,
    (i) => (c.playerSvtIds[i], c.playerCeIds[i] ?? 0),
  )..sort((a, b) => a.$1.compareTo(b.$1));
  final svtCePart = pairs.map((p) => '${p.$1}:${p.$2}').join(',');
  return '${svtCePart}_${c.supportSvtId}:${c.supportCeId ?? 0}_${c.mysticCodeId ?? 0}';
}

/// Groups [candidates] by source quest and calls [callback] with the result.
///
/// Each element of the emitted list has:
///   'sourceQuestId' (int), 'score' (double),
///   'teams': List of {'supportId', 'playerIds', 'mcId'?}
void _emitPatternPassReport(
  List<({CandidateTeam team, double score, int sourceQuestId})> candidates,
  void Function(List<Map<String, dynamic>>)? callback,
) {
  if (callback == null || candidates.isEmpty) return;
  final byQuest = <int, ({double score, List<Map<String, dynamic>> teams})>{};
  for (final entry in candidates) {
    final qId = entry.sourceQuestId;
    final teamMap = <String, dynamic>{
      'supportId': entry.team.supportSvtId,
      'playerIds': entry.team.playerSvtIds,
      if (entry.team.mysticCodeId != null) 'mcId': entry.team.mysticCodeId,
    };
    if (byQuest.containsKey(qId)) {
      byQuest[qId]!.teams.add(teamMap);
    } else {
      byQuest[qId] = (score: entry.score, teams: [teamMap]);
    }
  }
  callback([
    for (final e in byQuest.entries)
      {'sourceQuestId': e.key, 'score': e.value.score, 'teams': e.value.teams},
  ]);
}

/// Servant-set key for a [CandidateTeam]: sorted player servant IDs plus the
/// support servant ID, with no CEs or MC.
///
/// Used for the servant-set short-circuit: once any candidate with this
/// servant composition produces a clear, all further candidates with the
/// same servants are skipped regardless of CE or MC differences.
String _svtSetKey(CandidateTeam c) {
  final sorted = List.of(c.playerSvtIds)..sort();
  return '${sorted.join(',')}_${c.supportSvtId}';
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
