/// EngineRunner — runs the optimizer engine in a dedicated background Isolate.
///
/// The Flutter UI (root) isolate is responsible for rendering frames and
/// handling input. When [OptimizerEngine.run()] runs directly on the root
/// isolate, its event loop floods with Future continuations from concurrent
/// worker results, making the UI sluggish and unresponsive.
///
/// [EngineRunner] moves the engine loop to its own Dart Isolate. Only
/// lightweight callback messages (progress ticks, clear records) cross back
/// to the root isolate, and they arrive as ordinary event-queue tasks that
/// Flutter can interleave with frame callbacks and input processing.
///
/// Cancellation:
///   Call [stop()] to send a graceful stop signal to the engine isolate.
///   The engine finishes any in-flight candidate evaluations, then exits
///   cleanly — workers are disposed of and the engine reports 'done'.
///
/// Token propagation:
///   root isolate  →  engine isolate  →  N worker isolates
/// Each hop passes the same [RootIsolateToken] so every worker can call
/// [BackgroundIsolateBinaryMessenger] to load Flutter assets.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

import 'package:chaldea/app/tools/gamedata_loader.dart';
import 'package:chaldea/generated/l10n.dart';
import 'package:chaldea/models/models.dart';

import 'optimizer_engine.dart';
import 'passes/brute_force_pass.dart';
import 'passes/pattern_pass.dart';
import 'passes/rules_pass.dart';
import 'passes/shared_pass.dart';
import 'roster/run_history.dart';
import 'roster/user_roster.dart';

// ---------------------------------------------------------------------------
// Engine Isolate entry point
// ---------------------------------------------------------------------------

Future<void> _engineEntry(List<Object?> args) async {
  final token = args[0] as RootIsolateToken;
  final mainPort = args[1] as SendPort;
  final params = Map<String, dynamic>.from(args[2] as Map);

  // BackgroundIsolateBinaryMessenger.ensureInitialized is intentionally omitted.
  // The engine isolate uses only dart:io and pure-Dart APIs, so platform-channel
  // routing is not needed. Calling ensureInitialized() would register this isolate
  // with the root isolate's platform infrastructure, adding root-isolate overhead
  // proportional to the number of active background isolates.
  await S.load(const Locale('en'));

  await db.initiateForTest(testAppPath: params['appPath'] as String);
  final data =
      await GameDataLoader.instance.reload(offline: true, silent: true);
  if (data == null) {
    mainPort.send({
      'type': 'engineError',
      'msg': 'Engine isolate: failed to load game data',
    });
    return;
  }
  db.gameData = data;

  // Open a control port and tell the root isolate how to reach us.
  // The root isolate stores this SendPort and uses it to send stop signals.
  final controlPort = ReceivePort();
  mainPort.send({'type': 'ready', 'controlPort': controlPort.sendPort});

  // Listen for control messages in the background.
  // Because engine.run() is async (it awaits worker results), the event loop
  // is live during the run and this listener fires between await points.
  bool cancelled = false;
  controlPort.listen((msg) {
    if (msg is Map && msg['type'] == 'stop') cancelled = true;
  });

  final quest = QuestPhase.fromJson(
      Map<String, dynamic>.from(params['questJson'] as Map));
  final roster = UserRoster.fromJson(
      Map<String, dynamic>.from(params['rosterJson'] as Map));

  // Build the pass list. SharedPass is included when community teams were
  // fetched in the root isolate before spawning the engine.
  final communityTeams =
      List<String>.from((params['communityTeams'] as List?) ?? []);
  final enableShared      = params['enableSharedPass']      as bool? ?? true;
  final enablePattern     = params['enablePatternPass']     as bool? ?? true;
  final enableRules       = params['enableRulesPass']       as bool? ?? true;
  final enableBruteForce  = params['enableBruteForcePass']  as bool? ?? false;
  final dryRunBruteForce  = params['dryRunBruteForce']      as bool? ?? false;
  final activePasses = [
    if (enableShared && communityTeams.isNotEmpty) SharedPass(encodedTeams: communityTeams),
    if (enablePattern) PatternPass.prepare(quest: quest, roster: roster, appPath: params['appPath'] as String),
    if (enableRules) RulesPass(),
    if (enableBruteForce) BruteForcePass(),
  ];

  final engine = OptimizerEngine(
    quest: quest,
    roster: roster,
    passes: activePasses,
    workerCount: params['workerCount'] as int,
    historyFilePath: params['historyFile'] as String?,
    rootIsolateToken: token,
    isCancelled: () => cancelled,
    onProgress: (checked, cleared, engineMs) =>
        mainPort.send({'type': 'progress', 'checked': checked, 'cleared': cleared, 'engineMs': engineMs}),
    onClear: (record) =>
        mainPort.send({'type': 'clear', 'record': record.toJson()}),
    onGateStats: (total, g1, g2) =>
        mainPort.send({'type': 'gate', 'total': total, 'g1': g1, 'g2': g2}),
    onCandidateProcessed: (processed, total) =>
        mainPort.send({'type': 'candidate', 'processed': processed, 'total': total}),
    onServantStats: (specs, clears) => mainPort.send({
      'type': 'svtStats',
      'specs': {for (final e in specs.entries) '${e.key}': e.value},
      'clears': {for (final e in clears.entries) '${e.key}': e.value},
    }),
    onSimulationError: (msg) =>
        mainPort.send({'type': 'simError', 'msg': msg}),
    onWorkerDied: (deaths) =>
        mainPort.send({'type': 'workerDied', 'deaths': deaths}),
    onRunStats: (sg, pc, psg, psc) => mainPort.send({
      'type': 'runStats',
      'specsGenerated': sg,
      'plugSuitCandidates': pc,
      'plugSuitSpecsGenerated': psg,
      'plugSuitSpecsChecked': psc,
    }),
    onSharedPassReport: (fetched, skipped, teams) =>
        mainPort.send({'type': 'sharedPassReport', 'fetched': fetched, 'skipped': skipped, 'teams': teams}),
    onPatternPassReport: (matches) =>
        mainPort.send({'type': 'patternPassReport', 'matches': matches}),
    onBruteForceReport: (report) =>
        mainPort.send({'type': 'bruteForceReport', ...report}),
    dryRunBruteForce: dryRunBruteForce,
  );

  try {
    await engine.run();
    mainPort.send({'type': 'done', 'engineMs': DateTime.now().millisecondsSinceEpoch});
  } catch (e, st) {
    mainPort.send({'type': 'engineError', 'msg': 'Engine error: $e\n$st'});
  } finally {
    controlPort.close();
  }
}

// ---------------------------------------------------------------------------
// EngineRunner — root-isolate handle to the background engine Isolate
// ---------------------------------------------------------------------------

class EngineRunner {
  final QuestPhase quest;
  final UserRoster roster;
  final int workerCount;
  final String? historyFile;

  /// App data directory — passed to [PatternPass.prepare] so it can scan
  /// optimizer history files for cross-quest matching.
  final String appPath;

  /// Community teams to try in SharedPass before the heuristic RulesPass.
  /// Each entry is a [BattleShareData.toDataV2()] encoded string, pre-fetched
  /// in the root isolate by [RunNotifier] before the engine is started.
  final List<String> communityTeams;

  final void Function(int checked, int cleared, int engineMs)? onProgress;
  final void Function(RunRecord record)? onClear;
  final void Function(String msg)? onSimulationError;
  final void Function(int totalDeaths)? onWorkerDied;
  final void Function(int total, int g1, int g2)? onGateStats;
  final void Function(Map<int, int> specs, Map<int, int> clears)? onServantStats;
  final void Function(int processed, int total)? onCandidateProcessed;
  final void Function(String msg)? onEngineError;
  final void Function(int engineMs)? onDone;
  final void Function(
    int specsGenerated,
    int plugSuitCandidates,
    int plugSuitSpecsGenerated,
    int plugSuitSpecsChecked,
  )? onRunStats;

  final void Function(int fetched, int skipped, List<Map<String, dynamic>> teams)? onSharedPassReport;
  final void Function(List<Map<String, dynamic>> matches)? onPatternPassReport;
  final void Function(Map<String, dynamic> report)? onBruteForceReport;

  /// Per-pass enable toggles. When false the pass is omitted entirely.
  final bool enableSharedPass;
  final bool enablePatternPass;
  final bool enableRulesPass;
  final bool enableBruteForcePass;

  /// When true, BruteForce enumerates and counts dedup hits but does not
  /// dispatch any candidates to workers.
  final bool dryRunBruteForce;

  Isolate? _isolate;
  ReceivePort? _port;

  /// SendPort for the engine isolate's control channel.
  /// Set when the isolate sends its 'ready' message.
  SendPort? _controlPort;

  /// True if [stop()] was called before the engine isolate sent its 'ready'
  /// message. The stop signal is forwarded as soon as the control port arrives.
  bool _stopRequested = false;

  EngineRunner({
    required this.quest,
    required this.roster,
    required this.workerCount,
    required this.appPath,
    this.historyFile,
    this.communityTeams = const [],
    this.onProgress,
    this.onClear,
    this.onSimulationError,
    this.onWorkerDied,
    this.onGateStats,
    this.onServantStats,
    this.onCandidateProcessed,
    this.onEngineError,
    this.onDone,
    this.onRunStats,
    this.onSharedPassReport,
    this.onPatternPassReport,
    this.enableSharedPass = true,
    this.enablePatternPass = true,
    this.enableRulesPass = true,
    this.enableBruteForcePass = false,
    this.dryRunBruteForce = false,
    this.onBruteForceReport,
  });

  /// Runs the engine, returning once it completes or encounters a fatal error.
  Future<void> run() async {
    final token = ServicesBinding.rootIsolateToken;
    if (token == null) {
      // DIAGNOSTIC: if this fires, the engine is running on the root isolate
      // (no background isolate), which will freeze the UI for the entire run.
      // Root cause: ServicesBinding.rootIsolateToken is null — check that
      // WidgetsFlutterBinding.ensureInitialized() was called before run().
      debugPrint('[EngineRunner] WARNING: rootIsolateToken is null — '
          'running engine on root isolate (UI will freeze)');
      await _runDirect();
      return;
    }
    debugPrint('[EngineRunner] rootIsolateToken OK — spawning engine isolate');

    _port = ReceivePort();
    final completer = Completer<void>();

    try {
      _isolate = await Isolate.spawn(
        _engineEntry,
        [
          token,
          _port!.sendPort,
          {
            'appPath': db.paths.appPath,
            'questJson': quest.toJson(),
            'rosterJson': roster.toJson(),
            'workerCount': workerCount,
            'historyFile': historyFile,
            'communityTeams': communityTeams,
            'enableSharedPass': enableSharedPass,
            'enablePatternPass': enablePatternPass,
            'enableRulesPass': enableRulesPass,
            'enableBruteForcePass': enableBruteForcePass,
            'dryRunBruteForce': dryRunBruteForce,
          },
        ],
        debugName: 'OptimizerEngine',
      );
    } catch (e) {
      _port?.close();
      _port = null;
      onEngineError?.call('Failed to spawn engine isolate: $e');
      return;
    }

    _port!.listen(
      (msg) {
        if (msg is! Map) return;
        _handleMessage(msg, completer);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
    );

    await completer.future;
    _cleanup();
  }

  /// Sends a graceful stop signal to the engine isolate.
  ///
  /// The engine finishes any in-flight candidate evaluations, then exits
  /// normally. Workers are disposed of cleanly via the engine's finally block.
  /// Has no effect after the engine has already finished or if running in
  /// direct (test) mode.
  void stop() {
    _stopRequested = true;
    _controlPort?.send({'type': 'stop'});
  }

  void _handleMessage(Map msg, Completer<void> completer) {
    switch (msg['type'] as String?) {
      case 'ready':
        _controlPort = msg['controlPort'] as SendPort;
        if (_stopRequested) _controlPort!.send({'type': 'stop'});
      case 'progress':
        onProgress?.call(msg['checked'] as int, msg['cleared'] as int,
            (msg['engineMs'] as int?) ?? 0);
      case 'clear':
        final record = RunRecord.fromJson(
            Map<String, dynamic>.from(msg['record'] as Map));
        onClear?.call(record);
      case 'gate':
        onGateStats?.call(
            msg['total'] as int, msg['g1'] as int, msg['g2'] as int);
      case 'candidate':
        onCandidateProcessed?.call(
            msg['processed'] as int, msg['total'] as int);
      case 'svtStats':
        final specsRaw = msg['specs'] as Map;
        final clearsRaw = msg['clears'] as Map;
        onServantStats?.call(
          {for (final e in specsRaw.entries) int.parse(e.key as String): e.value as int},
          {for (final e in clearsRaw.entries) int.parse(e.key as String): e.value as int},
        );
      case 'runStats':
        onRunStats?.call(
          msg['specsGenerated'] as int,
          msg['plugSuitCandidates'] as int,
          msg['plugSuitSpecsGenerated'] as int,
          msg['plugSuitSpecsChecked'] as int,
        );
      case 'sharedPassReport':
        final teamsRaw = msg['teams'] as List;
        onSharedPassReport?.call(
          msg['fetched'] as int,
          msg['skipped'] as int,
          teamsRaw.map((t) => Map<String, dynamic>.from(t as Map)).toList(),
        );
      case 'patternPassReport':
        final matchesRaw = msg['matches'] as List;
        onPatternPassReport?.call(
          matchesRaw.map((m) => Map<String, dynamic>.from(m as Map)).toList(),
        );
      case 'bruteForceReport':
        onBruteForceReport?.call(Map<String, dynamic>.from(msg));
      case 'workerDied':
        onWorkerDied?.call(msg['deaths'] as int);
      case 'simError':
        onSimulationError?.call(msg['msg'] as String);
      case 'done':
        onDone?.call((msg['engineMs'] as int?) ?? 0);
        if (!completer.isCompleted) completer.complete();
        _port?.close();
      case 'engineError':
        onEngineError?.call(msg['msg'] as String);
        if (!completer.isCompleted) completer.complete();
        _port?.close();
    }
  }

  Future<void> _runDirect() async {
    final passes = [
      if (enableSharedPass && communityTeams.isNotEmpty) SharedPass(encodedTeams: communityTeams),
      if (enablePatternPass) PatternPass.prepare(quest: quest, roster: roster, appPath: appPath),
      if (enableRulesPass) RulesPass(),
      if (enableBruteForcePass) BruteForcePass(),
    ];
    final engine = OptimizerEngine(
      quest: quest,
      roster: roster,
      passes: passes,
      workerCount: workerCount,
      historyFilePath: historyFile,
      onProgress: onProgress,
      onClear: onClear,
      onSimulationError: onSimulationError,
      onWorkerDied: onWorkerDied,
      onGateStats: onGateStats,
      onServantStats: onServantStats,
      onCandidateProcessed: onCandidateProcessed,
      onRunStats: onRunStats,
      onSharedPassReport: onSharedPassReport,
      onPatternPassReport: onPatternPassReport,
      onBruteForceReport: onBruteForceReport,
      dryRunBruteForce: dryRunBruteForce,
    );
    try {
      await engine.run();
    } catch (e, st) {
      onEngineError?.call('Engine error: $e\n$st');
    }
  }

  void _cleanup() {
    _port?.close();
    _port = null;
    _isolate = null;
    _controlPort = null;
  }

  /// Kills the engine isolate immediately. Safe to call at any time.
  ///
  /// Prefer [stop()] for a graceful shutdown that lets workers clean up.
  /// Use [dispose()] only when you need immediate termination (e.g. app close).
  void dispose() {
    _port?.close();
    _isolate?.kill(priority: Isolate.immediate);
    _port = null;
    _isolate = null;
    _controlPort = null;
  }
}
