/// HeadlessWorkerPool — N parallel simulation isolates behind a single interface.
///
/// Maintains a pool of [HeadlessWorkerProcess] instances (each backed by its own Dart
/// Isolate). Callers use [run] for single-spec dispatch and [runCandidate] for
/// full-team dispatch; the pool routes each call to whichever worker is idle.
///
/// The pool owns all workers and must be [dispose]d after use.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:ui' show RootIsolateToken;

import 'package:chaldea/models/models.dart';

import '../roster/user_roster.dart';
import '../search/enumerator.dart';
import 'headless_runner.dart' show CandidateResult, SimulationResult, TeamSpec;
import 'headless_worker.dart';

class HeadlessWorkerPool {
  final List<HeadlessWorkerProcess> _workers;
  final Queue<HeadlessWorkerProcess> _idle = Queue();
  final Queue<Completer<HeadlessWorkerProcess>> _waiters = Queue();

  // Stored so replacement workers can be spawned with the same config.
  final QuestPhase _quest;
  final UserRoster? _roster;
  final RootIsolateToken? _rootIsolateToken;

  /// Called each time a worker subprocess dies and a replacement is spawned.
  /// [totalDeaths] is the cumulative count across the run.
  final void Function(int totalDeaths)? onWorkerDied;

  int _workerDeaths = 0;
  int get workerDeaths => _workerDeaths;

  bool _disposed = false;

  /// Creates [size] workers, all targeting the same [quest].
  ///
  /// Pass [roster] so workers can perform candidate-level dispatch via
  /// [runCandidate]. Pass [rootIsolateToken] when constructing from a non-root
  /// isolate so each worker can still load Flutter assets.
  HeadlessWorkerPool({
    required QuestPhase quest,
    required int size,
    UserRoster? roster,
    RootIsolateToken? rootIsolateToken,
    this.onWorkerDied,
  })  : _quest = quest,
        _roster = roster,
        _rootIsolateToken = rootIsolateToken,
        _workers = List.generate(
          size,
          (_) => HeadlessWorkerProcess(
            quest: quest,
            roster: roster,
            overrideToken: rootIsolateToken,
          ),
        );
  // _idle starts EMPTY. Workers are added as they finish loading via warmUp().

  /// Returns an idle worker immediately, or suspends until one is released.
  Future<HeadlessWorkerProcess> _acquire() {
    if (_idle.isNotEmpty) return Future.value(_idle.removeFirst());
    final c = Completer<HeadlessWorkerProcess>();
    _waiters.add(c);
    return c.future;
  }

  /// Returns [worker] to the pool; completes the oldest waiting acquire() if any.
  ///
  /// If [worker] has died (subprocess exited), spawns a replacement instead of
  /// recycling the dead instance. Dead workers that are recycled would hang
  /// forever on the next send because the subprocess stdin pipe is broken.
  void _release(HeadlessWorkerProcess worker) {
    if (_disposed) return;
    if (worker.isDead) {
      _spawnReplacement();
      return;
    }
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(worker);
    } else {
      _idle.add(worker);
    }
  }

  /// Spawns a fresh worker with the same config and adds it to the pool once ready.
  void _spawnReplacement() {
    _workerDeaths++;
    onWorkerDied?.call(_workerDeaths);
    final replacement = HeadlessWorkerProcess(
      quest: _quest,
      roster: _roster,
      overrideToken: _rootIsolateToken,
    );
    _workers.add(replacement); // track for dispose()
    replacement.start().then(
      (_) {
        if (!_disposed) _release(replacement);
      },
      onError: (_) {/* replacement failed to start — pool shrinks by one */},
    );
  }

  /// Kicks off staggered worker startup and returns immediately.
  ///
  /// Workers are added to the idle pool as they come online, so specs/candidates
  /// start flowing as soon as the first worker is ready rather than waiting for
  /// all [size] workers to finish loading.
  void warmUp({int staggerMs = 100}) {
    () async {
      for (int i = 0; i < _workers.length; i++) {
        if (_disposed) return;
        if (i > 0 && staggerMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: staggerMs));
        }
        _workers[i].start().then(
          (_) {
            if (!_disposed) _release(_workers[i]);
          },
          onError: (_) {
            if (!_disposed) _release(_workers[i]);
          },
        );
      }
    }();
  }

  /// Runs a single [spec] on the next available worker.
  ///
  /// Used by PatternPass and direct tests. Suspends until a worker is free.
  Future<SimulationResult> run(TeamSpec spec, {bool pessimistic = false}) async {
    final worker = await _acquire();
    try {
      return await worker.run(spec, pessimistic: pessimistic);
    } finally {
      _release(worker);
    }
  }

  /// Evaluates all specs for [candidate] on the next available worker and
  /// returns the aggregated [CandidateResult].
  ///
  /// The worker generates specs internally (via CandidateConverter), simulates
  /// each one, and returns results in a single round-trip. Suspends until a
  /// worker is free.
  Future<CandidateResult> runCandidate(
    CandidateTeam candidate, {
    bool oneClearPerCandidate = true,
  }) async {
    final worker = await _acquire();
    try {
      return await worker.runCandidate(
        candidate,
        oneClearPerCandidate: oneClearPerCandidate,
      );
    } finally {
      _release(worker);
    }
  }

  /// Shuts down all worker isolates.
  void dispose() {
    _disposed = true;
    for (final w in _workers) {
      w.dispose();
    }
    _idle.clear();
    for (final c in _waiters) {
      c.completeError(StateError('HeadlessWorkerPool disposed'));
    }
    _waiters.clear();
  }
}
