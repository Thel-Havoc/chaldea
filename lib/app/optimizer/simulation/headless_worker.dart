/// HeadlessWorker — simulation engine running in a background Dart Isolate.
///
/// Supports two dispatch modes:
///
///   run(TeamSpec)           — simulate a single pre-built spec (used by
///                             PatternPass and direct tests).
///
///   runCandidate(candidate) — given a CandidateTeam, generate all specs via
///                             CandidateConverter and simulate them internally,
///                             returning a CandidateResult. This is the primary
///                             mode for RulesPass and BruteForcePass: the entire
///                             team is evaluated in one round-trip, eliminating
///                             per-spec dispatch overhead.
///
/// The worker Isolate loads game data once on startup, then processes jobs via
/// SendPort/ReceivePort. This keeps the main/UI thread completely free for
/// Flutter rendering, Win32 message processing, and user input.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show Locale, RootIsolateToken;

import 'package:flutter/services.dart' show ServicesBinding;

import 'package:chaldea/app/tools/gamedata_loader.dart';
import 'package:chaldea/generated/l10n.dart';
import 'package:chaldea/models/models.dart';

import '../candidate_to_team_spec/candidate_converter.dart';
import '../roster/run_history.dart';
import '../roster/user_roster.dart';
import '../search/enumerator.dart';
import 'headless_runner.dart';
import 'share_data_converter.dart';

// ---------------------------------------------------------------------------
// CandidateTeam serialization
// ---------------------------------------------------------------------------

Map<String, dynamic> _serializeCandidate(CandidateTeam c) => {
      'supportSvtId': c.supportSvtId,
      'playerSvtIds': c.playerSvtIds,
      'playerCeIds': c.playerCeIds,
      'supportCeId': c.supportCeId,
      'mysticCodeId': c.mysticCodeId,
      'mysticCodeLevel': c.mysticCodeLevel,
    };

CandidateTeam _deserializeCandidate(Map m) => CandidateTeam(
      supportSvtId: m['supportSvtId'] as int,
      playerSvtIds: List<int>.from(m['playerSvtIds'] as List),
      playerCeIds: (m['playerCeIds'] as List).map((e) => e as int?).toList(),
      supportCeId: m['supportCeId'] as int?,
      mysticCodeId: m['mysticCodeId'] as int?,
      mysticCodeLevel: m['mysticCodeLevel'] as int,
    );

// ---------------------------------------------------------------------------
// TeamSpec serialization (unchanged from before)
// ---------------------------------------------------------------------------

Map<String, dynamic> _serializeSpec(TeamSpec spec) => {
      'slots': spec.slots
          .map((slot) => slot == null
              ? null
              : {
                  'svtId': slot.svt.id,
                  'level': slot.level,
                  'limitCount': slot.limitCount,
                  'tdLevel': slot.tdLevel,
                  'skillLevels': slot.skillLevels,
                  'appendLevels': slot.appendLevels,
                  'atkFou': slot.atkFou,
                  'hpFou': slot.hpFou,
                  'ceId': slot.ce?.id,
                  'ceMlb': slot.ceMlb,
                  'ceLevel': slot.ceLevel,
                  'isSupport': slot.isSupport,
                })
          .toList(),
      'mysticCodeId': spec.mysticCode?.id,
      'mysticCodeLevel': spec.mysticCodeLevel,
      'turns': spec.turns
          .map((t) => {
                'skills': t.skills
                    .map((s) => {
                          'slotIndex': s.slotIndex,
                          'skillIndex': s.skillIndex,
                          'enemyTarget': s.enemyTarget,
                          'allyTarget': s.allyTarget,
                        })
                    .toList(),
                'npSlots': t.npSlots,
                'orderChange': t.orderChange == null
                    ? null
                    : {
                        'onFieldSlot': t.orderChange!.onFieldSlot,
                        'backlineSlot': t.orderChange!.backlineSlot,
                      },
              })
          .toList(),
    };

/// Reconstructs a [TeamSpec] from a serialized map on the worker side.
TeamSpec _deserializeSpec(Map m) {
  final slots = (m['slots'] as List).map((s) {
    if (s == null) return null;
    final svtId = s['svtId'] as int;
    final svt = db.gameData.servantsById[svtId];
    if (svt == null) return null;
    final ceId = s['ceId'] as int?;
    return SlotSpec(
      svt: svt,
      level: s['level'] as int,
      limitCount: s['limitCount'] as int,
      tdLevel: s['tdLevel'] as int,
      skillLevels: List<int>.from(s['skillLevels'] as List),
      appendLevels: List<int>.from(s['appendLevels'] as List),
      atkFou: s['atkFou'] as int,
      hpFou: s['hpFou'] as int,
      ce: ceId != null ? db.gameData.craftEssencesById[ceId] : null,
      ceMlb: s['ceMlb'] as bool,
      ceLevel: s['ceLevel'] as int,
      isSupport: s['isSupport'] as bool,
    );
  }).toList();

  final mcId = m['mysticCodeId'] as int?;

  final turns = (m['turns'] as List).map((t) {
    final oc = t['orderChange'] as Map?;
    return TurnActions(
      skills: (t['skills'] as List)
          .map((s) => SkillAction(
                slotIndex: s['slotIndex'] as int,
                skillIndex: s['skillIndex'] as int,
                enemyTarget: s['enemyTarget'] as int? ?? 0,
                allyTarget: s['allyTarget'] as int?,
              ))
          .toList(),
      npSlots: List<int>.from(t['npSlots'] as List),
      orderChange: oc == null
          ? null
          : OrderChangeAction(
              onFieldSlot: oc['onFieldSlot'] as int,
              backlineSlot: oc['backlineSlot'] as int,
            ),
    );
  }).toList();

  return TeamSpec(
    slots: slots,
    mysticCode: mcId != null ? db.gameData.mysticCodes[mcId] : null,
    mysticCodeLevel: m['mysticCodeLevel'] as int,
    turns: turns,
  );
}

// ---------------------------------------------------------------------------
// In-worker candidate evaluation
// ---------------------------------------------------------------------------

/// Simulates all specs for [candidate] and returns aggregated results.
///
/// Called inside the worker isolate where db.gameData and the runner are
/// already loaded. Stops after the first clear when [oneClearPerCandidate]
/// is true (the normal mode).
Future<CandidateResult> _evaluateCandidate(
  CandidateTeam candidate,
  HeadlessRunner runner,
  CandidateConverter converter,
  bool oneClearPerCandidate,
) async {
  final specs = converter.convert(candidate);
  final specsGenerated = specs.length;
  int specsChecked = 0;
  int errors = 0;
  final clears = <RunRecord>[];

  if (specs.isEmpty) {
    return const CandidateResult(specsChecked: 0, specsGenerated: 0, clears: []);
  }

  for (final spec in specs) {
    final result = await runner.run(spec);
    specsChecked++;

    if (result.outcome == SimulationOutcome.error) {
      errors++;
    } else if (result.cleared) {
      final minResult = await runner.run(spec, pessimistic: true);
      final shareData = ShareDataConverter.convert(runner.quest, spec);
      clears.add(RunRecord(
        timestamp: DateTime.now(),
        questId: runner.quest.id,
        questPhase: runner.quest.phase,
        totalTurns: result.totalTurns,
        clearsAtMinDamage: minResult.cleared,
        battleData: shareData,
      ));
      if (oneClearPerCandidate) break;
    }
  }

  return CandidateResult(
    specsChecked: specsChecked,
    specsGenerated: specsGenerated,
    simulationErrors: errors,
    clears: clears,
  );
}

// ---------------------------------------------------------------------------
// Worker Isolate entry point
//
// Must be a top-level function (not a closure) for Isolate.spawn().
// Receives: [RootIsolateToken, appPath, mainSendPort]
// ---------------------------------------------------------------------------

Future<void> _workerEntry(List<Object?> args) async {
  // args[0] is the RootIsolateToken (kept in args for potential future use but
  // not activated here — workers use only dart:io and pure-Dart APIs, so
  // BackgroundIsolateBinaryMessenger.ensureInitialized is not needed and would
  // register each worker with the root isolate's platform infrastructure,
  // causing UI-thread overhead that scales with worker count).
  final appPath = args[1] as String;
  final mainPort = args[2] as SendPort;

  await S.load(const Locale('en'));
  await db.initiateForTest(testAppPath: appPath);

  final data = await GameDataLoader.instance.reload(offline: true, silent: true);
  if (data == null) {
    mainPort.send({'type': 'error', 'msg': 'Worker: failed to load game data'});
    return;
  }
  db.gameData = data;

  final port = ReceivePort();
  mainPort.send({'type': 'ready', 'port': port.sendPort});

  // State cached across messages (quest and roster sent only on first job).
  HeadlessRunner? runner;
  CandidateConverter? converter;

  await for (final msg in port) {
    if (msg is! Map) continue;
    switch (msg['type'] as String?) {
      case 'run':
        // Single-spec dispatch (PatternPass / direct tests).
        final replyPort = msg['reply'] as SendPort;
        try {
          final questJson = msg['questJson'] as Map?;
          if (questJson != null) {
            final quest =
                QuestPhase.fromJson(Map<String, dynamic>.from(questJson));
            runner = HeadlessRunner(quest: quest);
          }
          if (runner == null) {
            replyPort.send({'ok': false, 'error': 'No quest set'});
            break;
          }
          final spec = _deserializeSpec(msg['spec'] as Map);
          final pessimistic = msg['pessimistic'] as bool? ?? false;
          final r = await runner.run(spec, pessimistic: pessimistic);
          replyPort.send({
            'ok': true,
            'outcome': r.outcome.index,
            'turns': r.totalTurns,
            'error': r.errorMessage,
          });
        } catch (e, st) {
          replyPort.send({'ok': false, 'error': '$e\n$st'});
        }

      case 'runCandidate':
        // Full-team dispatch (RulesPass / BruteForcePass).
        final replyPort = msg['reply'] as SendPort;
        try {
          final questJson = msg['questJson'] as Map?;
          if (questJson != null) {
            final quest =
                QuestPhase.fromJson(Map<String, dynamic>.from(questJson));
            runner = HeadlessRunner(quest: quest);
          }
          final rosterJson = msg['rosterJson'] as Map?;
          if (rosterJson != null) {
            final roster =
                UserRoster.fromJson(Map<String, dynamic>.from(rosterJson));
            converter = CandidateConverter(roster);
          }
          if (runner == null || converter == null) {
            replyPort.send({'ok': false, 'error': 'No quest or roster set'});
            break;
          }
          final candidate = _deserializeCandidate(msg['candidate'] as Map);
          final oneClear = msg['oneClearPerCandidate'] as bool? ?? true;
          final result =
              await _evaluateCandidate(candidate, runner, converter, oneClear);
          replyPort.send({
            'ok': true,
            'specsChecked': result.specsChecked,
            'specsGenerated': result.specsGenerated,
            'simulationErrors': result.simulationErrors,
            'clears': result.clears.map((r) => r.toJson()).toList(),
          });
        } catch (e, st) {
          replyPort.send({'ok': false, 'error': '$e\n$st'});
        }

      case 'runShareData':
        // SharedPass dispatch — replay a community BattleShareData with
        // player stats already substituted by the engine isolate.
        final replyPort = msg['reply'] as SendPort;
        try {
          final questJson = msg['questJson'] as Map?;
          if (questJson != null) {
            final quest =
                QuestPhase.fromJson(Map<String, dynamic>.from(questJson));
            runner = HeadlessRunner(quest: quest);
          }
          if (runner == null) {
            replyPort.send({'ok': false, 'error': 'No quest set'});
            break;
          }
          final shareDataStr = msg['shareDataStr'] as String;
          final shareData = BattleShareData.parse(shareDataStr);
          if (shareData == null) {
            replyPort.send({'ok': false, 'error': 'Failed to parse share data'});
            break;
          }
          final r = await runner.runFromShareData(shareData);
          replyPort.send({
            'ok': true,
            'outcome': r.outcome.index,
            'turns': r.totalTurns,
            'error': r.errorMessage,
          });
        } catch (e, st) {
          replyPort.send({'ok': false, 'error': '$e\n$st'});
        }

      case 'stop':
        port.close();
        return;
    }
  }
}

// ---------------------------------------------------------------------------
// HeadlessWorker — main-isolate handle to the background worker Isolate
// ---------------------------------------------------------------------------

class HeadlessWorker {
  final QuestPhase quest;

  /// Roster used by [runCandidate] to build [CandidateConverter].
  /// Required for candidate-level dispatch; may be null for spec-only use.
  final UserRoster? roster;

  /// When non-null, used instead of [ServicesBinding.rootIsolateToken].
  final RootIsolateToken? overrideToken;

  Isolate? _isolate;
  SendPort? _workerPort;

  Completer<void>? _startCompleter;

  bool _questSent = false;
  bool _rosterSent = false;

  // Non-null when the isolate cannot be started (test environment fallback).
  HeadlessRunner? _directRunner;

  HeadlessWorker({required this.quest, this.roster, this.overrideToken});

  Future<void> _ensureStarted() async {
    if (_workerPort != null || _directRunner != null) return;
    if (_startCompleter != null) return _startCompleter!.future;

    final token = overrideToken ?? ServicesBinding.rootIsolateToken;
    if (token == null) {
      _directRunner = HeadlessRunner(quest: quest);
      return;
    }

    _startCompleter = Completer();
    final mainPort = ReceivePort();
    final appPath = db.paths.appPath;

    try {
      _isolate = await Isolate.spawn(
        _workerEntry,
        [token, appPath, mainPort.sendPort],
        debugName: 'HeadlessWorker',
      );

      final first = await mainPort.first as Map;
      mainPort.close();

      if (first['type'] == 'ready') {
        _workerPort = first['port'] as SendPort;
        _startCompleter!.complete();
      } else {
        throw Exception(first['msg'] ?? 'Worker init failed');
      }
    } catch (e) {
      _startCompleter!.completeError(e);
      rethrow;
    }
  }

  /// Runs a single [spec]. Used by PatternPass and direct tests.
  Future<SimulationResult> run(TeamSpec spec, {bool pessimistic = false}) async {
    await _ensureStarted();

    if (_directRunner != null) {
      return _directRunner!.run(spec, pessimistic: pessimistic);
    }

    final replyPort = ReceivePort();
    _workerPort!.send({
      'type': 'run',
      'questJson': _questSent ? null : quest.toJson(),
      'spec': _serializeSpec(spec),
      'pessimistic': pessimistic,
      'reply': replyPort.sendPort,
    });
    _questSent = true;

    final reply = await replyPort.first as Map;
    replyPort.close();

    if (reply['ok'] != true) {
      return SimulationResult.error(reply['error'] as String? ?? 'unknown');
    }
    final index = reply['outcome'] as int;
    final turns = reply['turns'] as int;
    final err = reply['error'] as String?;
    return switch (index) {
      0 => SimulationResult.cleared(turns),
      1 => SimulationResult.notCleared(turns),
      _ => SimulationResult.error(err ?? 'unknown'),
    };
  }

  /// Evaluates all specs for [candidate] inside the worker isolate and returns
  /// the aggregated [CandidateResult]. This is the primary dispatch method —
  /// one round-trip covers the entire team, eliminating per-spec overhead.
  Future<CandidateResult> runCandidate(
    CandidateTeam candidate, {
    bool oneClearPerCandidate = true,
  }) async {
    await _ensureStarted();

    // Direct-mode fallback for test environments.
    if (_directRunner != null) {
      if (roster == null) {
        return const CandidateResult(specsChecked: 0, clears: []);
      }
      return _evaluateCandidate(
        candidate,
        _directRunner!,
        CandidateConverter(roster!),
        oneClearPerCandidate,
      );
    }

    final replyPort = ReceivePort();
    _workerPort!.send({
      'type': 'runCandidate',
      'questJson': _questSent ? null : quest.toJson(),
      'rosterJson': _rosterSent ? null : roster?.toJson(),
      'candidate': _serializeCandidate(candidate),
      'oneClearPerCandidate': oneClearPerCandidate,
      'reply': replyPort.sendPort,
    });
    _questSent = true;
    _rosterSent = true;

    final reply = await replyPort.first as Map;
    replyPort.close();

    if (reply['ok'] != true) {
      return CandidateResult(
        specsChecked: 0,
        simulationErrors: 1,
        clears: [],
      );
    }

    return CandidateResult(
      specsChecked: reply['specsChecked'] as int,
      specsGenerated: reply['specsGenerated'] as int? ?? 0,
      simulationErrors: reply['simulationErrors'] as int,
      clears: (reply['clears'] as List)
          .map((m) =>
              RunRecord.fromJson(Map<String, dynamic>.from(m as Map)))
          .toList(),
    );
  }

  /// Replays a community [BattleShareData] (with player stats already
  /// substituted) on this worker. Used by SharedPass.
  Future<SimulationResult> runShareData(BattleShareData shareData) async {
    await _ensureStarted();

    if (_directRunner != null) {
      return _directRunner!.runFromShareData(shareData);
    }

    final replyPort = ReceivePort();
    _workerPort!.send({
      'type': 'runShareData',
      'questJson': _questSent ? null : quest.toJson(),
      'shareDataStr': shareData.toDataV2(),
      'reply': replyPort.sendPort,
    });
    _questSent = true;

    final reply = await replyPort.first as Map;
    replyPort.close();

    if (reply['ok'] != true) {
      return SimulationResult.error(reply['error'] as String? ?? 'unknown');
    }
    final index = reply['outcome'] as int;
    final turns = reply['turns'] as int;
    final err = reply['error'] as String?;
    return switch (index) {
      0 => SimulationResult.cleared(turns),
      1 => SimulationResult.notCleared(turns),
      _ => SimulationResult.error(err ?? 'unknown'),
    };
  }

  /// Starts the background Isolate proactively without running a spec.
  Future<void> start() => _ensureStarted();

  /// Shuts down the background Isolate.
  void dispose() {
    _workerPort?.send({'type': 'stop'});
    _isolate?.kill(priority: Isolate.immediate);
    _workerPort = null;
    _isolate = null;
    _directRunner = null;
  }
}

// ---------------------------------------------------------------------------
// HeadlessWorkerProcess — subprocess-backed worker (independent Dart VM / GC)
// ---------------------------------------------------------------------------

/// A simulation worker backed by a subprocess of the current executable.
///
/// Spawning [chaldea.exe --worker <appPath>] creates a completely separate
/// Dart VM with its own GC heap. Workers' allocation pressure never triggers
/// a stop-the-world pause on the root isolate.
///
/// Falls back to a direct [HeadlessRunner] (same-process, same isolate) when
/// process spawning is unavailable (web, mobile, or spawn failure).
class HeadlessWorkerProcess {
  final QuestPhase quest;
  final UserRoster? roster;
  final RootIsolateToken? overrideToken; // kept for fallback isolate path

  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  Completer<void>? _startCompleter;

  /// One pending request at a time — the pool's acquire/release ensures this.
  Completer<Map<String, dynamic>>? _pending;

  HeadlessRunner? _directRunner; // non-null when running in fallback mode

  bool _dead = false; // true once the subprocess has exited
  bool _stopSent = false; // true once we intentionally sent 'stop' / killed the process
  bool _questSent = false;
  bool _rosterSent = false;

  /// Buffered stderr from the subprocess — included in crash error messages.
  final StringBuffer _stderrBuf = StringBuffer();
  static const int _stderrMaxChars = 4096;

  /// True when the subprocess has exited and this worker is no longer usable.
  /// False for direct-runner fallback workers (they never die).
  bool get isDead => _dead && _directRunner == null;

  HeadlessWorkerProcess({
    required this.quest,
    this.roster,
    this.overrideToken,
  });

  Future<void> start() async {
    if (_process != null || _directRunner != null) return;
    if (_startCompleter != null) return _startCompleter!.future;
    _startCompleter = Completer();

    // Process-based workers only make sense on desktop platforms.
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
      _directRunner = HeadlessRunner(quest: quest);
      _startCompleter!.complete();
      return;
    }

    // In test environments Platform.resolvedExecutable is the Dart test
    // runner (dart.exe / dart_test.exe), not the app binary. Spawning it
    // with --worker would start a process that never sends {"type":"ready"}.
    // Detect this by checking whether the executable is our app binary.
    final exeName = Platform.resolvedExecutable
        .split(Platform.pathSeparator)
        .last
        .toLowerCase();
    if (!exeName.contains('chaldea')) {
      _directRunner = HeadlessRunner(quest: quest);
      _startCompleter!.complete();
      return;
    }

    final exePath = Platform.resolvedExecutable;
    final appPath = db.paths.appPath;

    try {
      _process = await Process.start(exePath, ['--worker', appPath]);
    } catch (e) {
      // Spawn failed — fall back to direct in-process runner.
      _directRunner = HeadlessRunner(quest: quest);
      _startCompleter!.complete();
      return;
    }

    // Buffer stderr for crash diagnostics. A worker crash emits the Dart
    // exception + stack trace on stderr; we include it in the error message
    // so it surfaces in the UI debug report.
    _process!.stderr.transform(utf8.decoder).listen(
      (data) {
        if (_stderrBuf.length < _stderrMaxChars) {
          _stderrBuf.write(data);
        }
      },
      onError: (_) {},
    );

    _stdoutSub = _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) {
        if (line.isEmpty) return;
        Map<String, dynamic> msg;
        try {
          msg = jsonDecode(line) as Map<String, dynamic>;
        } catch (_) {
          return;
        }
        switch (msg['type'] as String?) {
          case 'ready':
            if (!(_startCompleter?.isCompleted ?? true)) {
              _startCompleter!.complete();
            }
          case 'result':
            _pending?.complete(msg);
            _pending = null;
          case 'error':
            if (!(_startCompleter?.isCompleted ?? true)) {
              _startCompleter!
                  .completeError(msg['msg'] as String? ?? 'worker error');
            } else {
              _pending?.completeError(msg['msg'] as String? ?? 'worker error');
              _pending = null;
            }
        }
      },
      onError: (Object e) {
        if (!(_startCompleter?.isCompleted ?? true)) {
          _startCompleter!.completeError(e);
        } else {
          _pending?.completeError(e);
          _pending = null;
        }
      },
      onDone: () {
        _dead = true;
        final stderr = _stderrBuf.toString().trim();
        final crashMsg = _stopSent
            ? 'Worker process exited (requested)'
            : stderr.isNotEmpty
                ? 'Worker process crashed:\n$stderr'
                : 'Worker process exited unexpectedly (no stderr)';
        if (!(_startCompleter?.isCompleted ?? true)) {
          _startCompleter!.completeError(crashMsg);
        }
        _pending?.completeError(crashMsg);
        _pending = null;
      },
    );

    // Wait for the worker to signal readiness. In production this completes
    // within a few seconds; the token-null check above already handles test
    // environments so no timeout fallback is needed here.
    await _startCompleter!.future;
  }

  Future<Map<String, dynamic>> _sendAndReceive(
      Map<String, dynamic> msg) async {
    if (_dead) throw StateError('Worker process has exited');
    assert(_pending == null, 'HeadlessWorkerProcess: overlapping requests');
    _pending = Completer();
    _process!.stdin.writeln(jsonEncode(msg));
    await _process!.stdin.flush();
    return _pending!.future;
  }

  Future<SimulationResult> run(TeamSpec spec,
      {bool pessimistic = false}) async {
    if (_directRunner != null) {
      return _directRunner!.run(spec, pessimistic: pessimistic);
    }
    final reply = await _sendAndReceive({
      'type': 'run',
      'questJson': _questSent ? null : quest.toJson(),
      'spec': _serializeSpec(spec),
      'pessimistic': pessimistic,
    });
    _questSent = true;
    if (reply['ok'] != true) {
      return SimulationResult.error(reply['error'] as String? ?? 'unknown');
    }
    final index = reply['outcome'] as int;
    final turns = reply['turns'] as int;
    final err = reply['error'] as String?;
    return switch (index) {
      0 => SimulationResult.cleared(turns),
      1 => SimulationResult.notCleared(turns),
      _ => SimulationResult.error(err ?? 'unknown'),
    };
  }

  Future<CandidateResult> runCandidate(
    CandidateTeam candidate, {
    bool oneClearPerCandidate = true,
  }) async {
    if (_directRunner != null) {
      if (roster == null) {
        return const CandidateResult(specsChecked: 0, clears: []);
      }
      return _evaluateCandidate(
        candidate,
        _directRunner!,
        CandidateConverter(roster!),
        oneClearPerCandidate,
      );
    }
    final reply = await _sendAndReceive({
      'type': 'runCandidate',
      'questJson': _questSent ? null : quest.toJson(),
      'rosterJson': _rosterSent ? null : roster?.toJson(),
      'candidate': _serializeCandidate(candidate),
      'oneClearPerCandidate': oneClearPerCandidate,
    });
    _questSent = true;
    _rosterSent = true;
    if (reply['ok'] != true) {
      return CandidateResult(
          specsChecked: 0, simulationErrors: 1, clears: []);
    }
    return CandidateResult(
      specsChecked: reply['specsChecked'] as int,
      specsGenerated: reply['specsGenerated'] as int? ?? 0,
      simulationErrors: reply['simulationErrors'] as int,
      clears: (reply['clears'] as List)
          .map((m) =>
              RunRecord.fromJson(Map<String, dynamic>.from(m as Map)))
          .toList(),
    );
  }

  /// Replays a community [BattleShareData] (with player stats already
  /// substituted) on this worker. Used by SharedPass.
  Future<SimulationResult> runShareData(BattleShareData shareData) async {
    if (_directRunner != null) {
      return _directRunner!.runFromShareData(shareData);
    }
    final reply = await _sendAndReceive({
      'type': 'runShareData',
      'questJson': _questSent ? null : quest.toJson(),
      'shareDataStr': shareData.toDataV2(),
    });
    _questSent = true;
    if (reply['ok'] != true) {
      return SimulationResult.error(reply['error'] as String? ?? 'unknown');
    }
    final index = reply['outcome'] as int;
    final turns = reply['turns'] as int;
    final err = reply['error'] as String?;
    return switch (index) {
      0 => SimulationResult.cleared(turns),
      1 => SimulationResult.notCleared(turns),
      _ => SimulationResult.error(err ?? 'unknown'),
    };
  }

  void dispose() {
    _stopSent = true;
    _stdoutSub?.cancel();
    _stdoutSub = null;
    try {
      _process?.stdin.writeln(jsonEncode({'type': 'stop'}));
      _process?.stdin.close();
    } catch (_) {}
    _process?.kill();
    _process = null;
    _directRunner = null;
  }
}

// ---------------------------------------------------------------------------
// runWorkerProcess — headless subprocess entry point
//
// Called from lib/main.dart when the app is spawned with --worker <appPath>.
// Runs the full optimizer worker loop on stdin/stdout JSON without showing
// a window or calling runApp(). Each worker subprocess has its own Dart VM,
// so its GC is completely independent of the root isolate's GC.
// ---------------------------------------------------------------------------

/// Runs the optimizer in headless subprocess mode.
///
/// Called from [main] when `--worker` is detected in the command-line args.
/// Loads game data, signals readiness on stdout, then processes
/// candidate/spec jobs from stdin until stdin is closed or a 'stop' message
/// is received.
Future<void> runWorkerProcess(List<String> args) async {
  // Find appPath: the argument immediately after --worker.
  final workerIdx = args.indexOf('--worker');
  final appPath = (workerIdx >= 0 && workerIdx + 1 < args.length)
      ? args[workerIdx + 1]
      : '';

  await S.load(const Locale('en'));
  await db.initiateForTest(testAppPath: appPath);

  final data =
      await GameDataLoader.instance.reload(offline: true, silent: true);
  if (data == null) {
    stdout.writeln(jsonEncode({
      'type': 'error',
      'msg': 'Worker: failed to load game data',
    }));
    await stdout.flush();
    exit(1);
  }
  db.gameData = data;

  stdout.writeln(jsonEncode({'type': 'ready'}));
  await stdout.flush();

  HeadlessRunner? runner;
  CandidateConverter? converter;

  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) continue;
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      continue;
    }

    switch (msg['type'] as String?) {
      case 'runCandidate':
        try {
          final questJson = msg['questJson'] as Map?;
          if (questJson != null) {
            runner = HeadlessRunner(
                quest: QuestPhase.fromJson(
                    Map<String, dynamic>.from(questJson)));
          }
          final rosterJson = msg['rosterJson'] as Map?;
          if (rosterJson != null) {
            converter = CandidateConverter(
                UserRoster.fromJson(Map<String, dynamic>.from(rosterJson)));
          }
          if (runner == null || converter == null) {
            stdout.writeln(jsonEncode({
              'type': 'result',
              'ok': false,
              'error': 'No quest or roster set',
            }));
          } else {
            final candidate =
                _deserializeCandidate(msg['candidate'] as Map);
            final oneClear = msg['oneClearPerCandidate'] as bool? ?? true;
            final result =
                await _evaluateCandidate(candidate, runner, converter, oneClear);
            stdout.writeln(jsonEncode({
              'type': 'result',
              'ok': true,
              'specsChecked': result.specsChecked,
              'specsGenerated': result.specsGenerated,
              'simulationErrors': result.simulationErrors,
              'clears': result.clears.map((r) => r.toJson()).toList(),
            }));
          }
        } catch (e, st) {
          stdout.writeln(jsonEncode({
            'type': 'result',
            'ok': false,
            'error': '$e\n$st',
          }));
        }
        await stdout.flush();

      case 'run':
        try {
          final questJson = msg['questJson'] as Map?;
          if (questJson != null) {
            runner = HeadlessRunner(
                quest: QuestPhase.fromJson(
                    Map<String, dynamic>.from(questJson)));
          }
          if (runner == null) {
            stdout.writeln(jsonEncode({
              'type': 'result',
              'ok': false,
              'error': 'No quest set',
            }));
          } else {
            final spec = _deserializeSpec(msg['spec'] as Map);
            final pessimistic = msg['pessimistic'] as bool? ?? false;
            final r = await runner.run(spec, pessimistic: pessimistic);
            stdout.writeln(jsonEncode({
              'type': 'result',
              'ok': true,
              'outcome': r.outcome.index,
              'turns': r.totalTurns,
              'error': r.errorMessage,
            }));
          }
        } catch (e, st) {
          stdout.writeln(jsonEncode({
            'type': 'result',
            'ok': false,
            'error': '$e\n$st',
          }));
        }
        await stdout.flush();

      case 'runShareData':
        try {
          final questJson = msg['questJson'] as Map?;
          if (questJson != null) {
            runner = HeadlessRunner(
                quest: QuestPhase.fromJson(
                    Map<String, dynamic>.from(questJson)));
          }
          if (runner == null) {
            stdout.writeln(jsonEncode({
              'type': 'result',
              'ok': false,
              'error': 'No quest set',
            }));
          } else {
            final shareDataStr = msg['shareDataStr'] as String;
            final shareData = BattleShareData.parse(shareDataStr);
            if (shareData == null) {
              stdout.writeln(jsonEncode({
                'type': 'result',
                'ok': false,
                'error': 'Failed to parse share data',
              }));
            } else {
              final r = await runner.runFromShareData(shareData);
              stdout.writeln(jsonEncode({
                'type': 'result',
                'ok': true,
                'outcome': r.outcome.index,
                'turns': r.totalTurns,
                'error': r.errorMessage,
              }));
            }
          }
        } catch (e, st) {
          stdout.writeln(jsonEncode({
            'type': 'result',
            'ok': false,
            'error': '$e\n$st',
          }));
        }
        await stdout.flush();

      case 'stop':
        exit(0);
    }
  }

  // stdin closed — parent process done.
  exit(0);
}
