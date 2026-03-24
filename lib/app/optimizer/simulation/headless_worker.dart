/// HeadlessWorker — simulation engine running in a background Dart Isolate.
///
/// The worker Isolate loads game data once on startup, then processes
/// simulation jobs (serialized TeamSpec messages) via SendPort/ReceivePort.
/// This keeps the main/UI thread completely free for Flutter rendering,
/// Win32 message processing, and user input regardless of how long each
/// spec simulation takes.
///
/// Usage (same interface as HeadlessRunner):
///   final worker = HeadlessWorker(quest: questPhase);
///   final result = await worker.run(spec);              // non-blocking
///   final minResult = await worker.run(spec, pessimistic: true);
///   worker.dispose();  // shut down isolate when done
///
/// The first call to [run] spawns the Isolate and waits for it to finish
/// loading game data (a one-time cost). Subsequent calls reuse the same
/// Isolate with near-zero overhead.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/services.dart';

import 'package:chaldea/app/tools/gamedata_loader.dart';
import 'package:chaldea/generated/l10n.dart';
import 'package:chaldea/models/models.dart';

import 'headless_runner.dart';

// ---------------------------------------------------------------------------
// TeamSpec serialization
//
// Dart Isolates cannot share memory — all messages must be plain primitives,
// Lists, Maps, and SendPorts. TeamSpec holds rich game objects (Servant, CE)
// that can't cross the isolate boundary, so we convert to integer IDs + plain
// values here and reconstruct from db.gameData on the worker side.
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
/// Uses the worker's local [db.gameData] to resolve servant/CE/MC objects.
TeamSpec _deserializeSpec(Map m) {
  final slots = (m['slots'] as List).map((s) {
    if (s == null) return null;
    final svtId = s['svtId'] as int;
    final svt = db.gameData.servantsById[svtId];
    if (svt == null) return null; // servant not in worker game data — skip
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
// Worker Isolate entry point
//
// Must be a top-level function (not a closure) for Isolate.spawn().
// Receives: [RootIsolateToken, appPath, mainSendPort]
// ---------------------------------------------------------------------------

Future<void> _workerEntry(List<Object?> args) async {
  final token = args[0] as RootIsolateToken;
  final appPath = args[1] as String;
  final mainPort = args[2] as SendPort;

  // Allow platform channel calls (required for rootBundle / asset loading).
  BackgroundIsolateBinaryMessenger.ensureInitialized(token);

  // Localization must be initialized before any battle simulation runs.
  // S.current is used inside battle functions (e.g. AddState.shouldAddState).
  await S.load(const Locale('en'));

  // Set up db path and load settings; no UI, no path_provider needed since
  // we receive the resolved appPath from the main isolate.
  await db.initiateForTest(testAppPath: appPath);

  // Load game data from disk (offline — no network required).
  final data = await GameDataLoader.instance.reload(offline: true, silent: true);
  if (data == null) {
    mainPort.send({'type': 'error', 'msg': 'Worker: failed to load game data'});
    return;
  }
  db.gameData = data;

  // Open the receive port and signal readiness to the main isolate.
  final port = ReceivePort();
  mainPort.send({'type': 'ready', 'port': port.sendPort});

  // Cache the runner — created once per quest, reused for all specs.
  HeadlessRunner? runner;

  await for (final msg in port) {
    if (msg is! Map) continue;
    switch (msg['type'] as String?) {
      case 'run':
        final replyPort = msg['reply'] as SendPort;
        try {
          // Accept an updated quest JSON (sent only when the quest changes).
          final questJson = msg['questJson'] as Map?;
          if (questJson != null) {
            final quest = QuestPhase.fromJson(Map<String, dynamic>.from(questJson));
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

  Isolate? _isolate;
  SendPort? _workerPort;

  // Guards concurrent calls to [run] during the initial startup sequence.
  Completer<void>? _startCompleter;

  // True once the quest JSON has been sent to the worker (sent only once).
  bool _questSent = false;

  // Non-null when the isolate cannot be started (e.g. test environment):
  // falls back to running simulation directly on the calling thread.
  HeadlessRunner? _directRunner;

  HeadlessWorker({required this.quest});

  /// Spawns the background Isolate on first call; returns immediately on
  /// subsequent calls once the Isolate is ready.
  ///
  /// Falls back to direct [HeadlessRunner] execution when
  /// [ServicesBinding.rootIsolateToken] is unavailable (test environments).
  Future<void> _ensureStarted() async {
    if (_workerPort != null || _directRunner != null) return;
    if (_startCompleter != null) return _startCompleter!.future;

    // rootIsolateToken is only available in a real Flutter app — not in
    // flutter_test's headless environment. Fall back to direct execution.
    final token = ServicesBinding.rootIsolateToken;
    if (token == null) {
      _directRunner = HeadlessRunner(quest: quest);
      return;
    }

    _startCompleter = Completer();
    final mainPort = ReceivePort();

    // Pass the already-resolved app path so the worker doesn't need
    // path_provider and can be initialised without Flutter bindings.
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

  /// Runs [spec] in the background Isolate. Drop-in replacement for
  /// [HeadlessRunner.run] — same signature, never blocks the main thread.
  Future<SimulationResult> run(TeamSpec spec, {bool pessimistic = false}) async {
    await _ensureStarted();

    // Direct-mode fallback (test environment, no root isolate token).
    if (_directRunner != null) {
      return _directRunner!.run(spec, pessimistic: pessimistic);
    }

    final replyPort = ReceivePort();
    _workerPort!.send({
      'type': 'run',
      // Send quest JSON on the very first run only; worker caches it.
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

  /// Shuts down the background Isolate. Call once after the engine run ends.
  void dispose() {
    _workerPort?.send({'type': 'stop'});
    _isolate?.kill(priority: Isolate.immediate);
    _workerPort = null;
    _isolate = null;
    _directRunner = null;
  }
}
