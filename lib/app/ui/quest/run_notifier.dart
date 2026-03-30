/// RunNotifier — shared engine state across Quest, Results, and Status tabs.
///
/// Holds the selected quest, engine run progress, and the list of clears
/// found so far. Provided at the app level via [RunScope] so all tabs see
/// the same state regardless of which tab is currently visible.
library;

import 'dart:io' show Platform, ProcessInfo;

import 'package:flutter/widgets.dart';

import 'package:chaldea/app/api/atlas.dart';
import 'package:chaldea/models/models.dart';
import 'package:chaldea/packages/logger.dart';

import '../../optimizer/engine_runner.dart';
import '../../optimizer/roster/run_history.dart';
import '../../optimizer/roster/user_roster.dart';

class RunNotifier extends ChangeNotifier {
  NiceWar? selectedWar;
  Quest? selectedQuest;

  /// The loaded [QuestPhase] for [selectedQuest]. Null while loading or if
  /// no quest is selected. Populated from local cache or Atlas Academy NA API.
  QuestPhase? loadedPhase;
  bool isLoadingPhase = false;
  String? phaseLoadError;

  bool isRunning = false;
  bool isStopping = false; // true between stopRun() and engine reporting done
  final List<RunRecord> clears = [];
  int specsChecked = 0;
  int simulationErrors = 0;
  int workerDeaths = 0;
  final List<String> recentSimErrors = []; // last 5 errors
  String? firstSimulationError;
  String? error;

  // Gate stats — populated once after pruning, before simulation begins.
  int candidatesTotal = 0;
  int gate1Blocked = 0;
  int gate2Blocked = 0;

  // Candidate-level progress — updated as simulation proceeds.
  int candidatesProcessed = 0;
  int get candidatesPassed => candidatesTotal - gate1Blocked - gate2Blocked;

  // Per-servant simulation stats — populated at end of run.
  Map<int, int> svtSpecsChecked = {};
  Map<int, int> svtClears = {};

  // Spec generation stats — populated at end of run.
  int specsGenerated = 0;
  int plugSuitCandidates = 0;
  int plugSuitSpecsGenerated = 0;
  int plugSuitSpecsChecked = 0;

  // Diagnostic: root-isolate responsiveness during runs.
  // These measure whether the root-isolate event loop processes engine messages
  // at a steady rate or only in a burst at the end (indicating a blockage).
  int progressMsgsReceived = 0;
  int maxProgressIntervalMs = 0;     // longest gap between consecutive progress messages
  int maxProgressIntervalIndex = 0;  // index of the message that ended the max gap
  int maxEngineRootLatencyMs = 0;    // longest time a progress message sat in the port queue
  int highLatencyProgressCount = 0;  // messages with engine→root latency > 5s
  int doneLatencyMs = 0;             // time 'done' message sat in the port queue
  int firstProgressEngineMs = 0;     // engine wall-clock ms when first progress message was sent
  int lastProgressEngineMs = 0;      // engine wall-clock ms when last progress message was sent
  int rssAtRunStartMb = 0;           // process RSS (MB) at run start
  int rssAtFirstProgressMb = 0;      // process RSS (MB) when first candidate result arrived
  int rssAtFreezeStartMb = 0;        // process RSS (MB) just before the longest freeze started
  int rssAtDoneMb = 0;               // process RSS (MB) when engine finished
  Duration? runElapsedAtGateStats;   // run time when pruning finished (workers started)
  Duration? runElapsedAtFirstProgress; // run time when first candidate result arrived
  Duration? runElapsedAtFreezeStart; // run time just before the longest gap started
  Duration? runElapsedAtFreezeEnd;   // run time when the longest gap ended (root thawed)
  Duration? runElapsedAtLastProgress; // run time when the last progress message was processed
  Duration? runElapsedAtDone;        // run time when root isolate processed 'done'
  DateTime? _prevProgressWallTime;
  Duration? _prevProgressRunElapsed;

  /// Number of parallel worker Isolates to use. Adjustable via the Debug tab.
  // Leave 2 cores uncontested: one for the engine background isolate,
  // one for the root/UI isolate. Saturating every core starves the timer
  // and makes the UI unresponsive.
  int workerCount = (Platform.numberOfProcessors - 2).clamp(1, Platform.numberOfProcessors);

  void setWorkerCount(int count) {
    workerCount = count.clamp(1, Platform.numberOfProcessors);
    notifyListeners();
  }

  /// Wall-clock time for the current or most recent run.
  final Stopwatch _runWatch = Stopwatch();

  /// Elapsed time of the current (or most recently completed) run.
  Duration get elapsed => _runWatch.elapsed;

  // Active engine runner — kept so stopRun() can send a stop signal.
  EngineRunner? _runner;


  // ---------------------------------------------------------------------------
  // Selection
  // ---------------------------------------------------------------------------

  void selectWar(NiceWar? war) {
    if (war == selectedWar) return;
    selectedWar = war;
    selectedQuest = null;
    loadedPhase = null;
    phaseLoadError = null;
    notifyListeners();
  }

  void selectQuest(Quest? quest) {
    if (quest == selectedQuest) return;
    selectedQuest = quest;
    loadedPhase = null;
    phaseLoadError = null;
    notifyListeners();
    if (quest != null) _loadPhase(quest);
  }

  Future<void> _loadPhase(Quest quest) async {
    final phase = quest.phasesWithEnemies.lastOrNull;
    if (phase == null) return;

    // Check local game data cache first (no network needed).
    final cached = db.gameData.questPhases[quest.id * 100 + phase];
    if (cached != null) {
      if (selectedQuest == quest) {
        loadedPhase = cached;
        notifyListeners();
      }
      return;
    }

    isLoadingPhase = true;
    notifyListeners();
    try {
      final fetched =
          await AtlasApi.questPhase(quest.id, phase, region: Region.na);
      if (selectedQuest == quest) {
        loadedPhase = fetched;
        phaseLoadError =
            fetched == null ? 'Quest data not found on Atlas Academy.' : null;
      }
    } catch (e, st) {
      if (selectedQuest == quest) {
        phaseLoadError = 'Failed to load quest data: $e';
      }
      logger.e('Quest phase fetch failed for ${quest.id}/$phase', e, st);
    } finally {
      if (selectedQuest == quest) {
        isLoadingPhase = false;
        notifyListeners();
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Engine run
  // ---------------------------------------------------------------------------

  Future<void> run(UserRoster roster) async {
    if (selectedQuest == null || isRunning || loadedPhase == null) return;

    final questPhase = loadedPhase!;

    isRunning = true;
    isStopping = false;
    clears.clear();
    specsChecked = 0;
    simulationErrors = 0;
    workerDeaths = 0;
    recentSimErrors.clear();
    firstSimulationError = null;
    error = null;
    candidatesTotal = 0;
    gate1Blocked = 0;
    gate2Blocked = 0;
    candidatesProcessed = 0;
    svtSpecsChecked = {};
    svtClears = {};
    specsGenerated = 0;
    plugSuitCandidates = 0;
    plugSuitSpecsGenerated = 0;
    plugSuitSpecsChecked = 0;
    progressMsgsReceived = 0;
    maxProgressIntervalMs = 0;
    maxProgressIntervalIndex = 0;
    maxEngineRootLatencyMs = 0;
    highLatencyProgressCount = 0;
    doneLatencyMs = 0;
    firstProgressEngineMs = 0;
    lastProgressEngineMs = 0;
    rssAtRunStartMb = ProcessInfo.currentRss ~/ (1024 * 1024);
    rssAtFirstProgressMb = 0;
    rssAtFreezeStartMb = 0;
    rssAtDoneMb = 0;
    runElapsedAtGateStats = null;
    runElapsedAtFirstProgress = null;
    runElapsedAtFreezeStart = null;
    runElapsedAtFreezeEnd = null;
    runElapsedAtLastProgress = null;
    runElapsedAtDone = null;
    _prevProgressWallTime = null;
    _prevProgressRunElapsed = null;
    _runWatch.reset();
    _runWatch.start();

    // UI updates are driven directly by engine callbacks — each callback calls
    // notifyListeners() so the root isolate only wakes up when there is new
    // data to display. The old periodic-timer approach registered each worker
    // with the root isolate's platform infrastructure via
    // BackgroundIsolateBinaryMessenger, causing root-isolate overhead that
    // scaled with worker count and starved the timer.
    notifyListeners();

    final historyFile =
        '${db.paths.appPath}/optimizer_history_${selectedQuest!.id}.jsonl';

    _runner = EngineRunner(
      quest: questPhase,
      roster: roster,
      workerCount: workerCount,
      historyFile: historyFile,
      onProgress: (checked, _, engineMs) {
        specsChecked = checked;
        progressMsgsReceived++;
        final now = DateTime.now();
        final elapsed = _runWatch.elapsed;
        final latencyMs = now.millisecondsSinceEpoch - engineMs;
        if (latencyMs > maxEngineRootLatencyMs) maxEngineRootLatencyMs = latencyMs;
        if (latencyMs > 5000) highLatencyProgressCount++;
        if (firstProgressEngineMs == 0) {
          firstProgressEngineMs = engineMs;
          rssAtFirstProgressMb = ProcessInfo.currentRss ~/ (1024 * 1024);
        }
        lastProgressEngineMs = engineMs;
        if (_prevProgressWallTime == null) {
          runElapsedAtFirstProgress = elapsed;
        } else {
          final gapMs = now.difference(_prevProgressWallTime!).inMilliseconds;
          if (gapMs > maxProgressIntervalMs) {
            maxProgressIntervalMs = gapMs;
            maxProgressIntervalIndex = progressMsgsReceived;
            runElapsedAtFreezeStart = _prevProgressRunElapsed;
            runElapsedAtFreezeEnd = elapsed;
            rssAtFreezeStartMb = ProcessInfo.currentRss ~/ (1024 * 1024);
          }
        }
        runElapsedAtLastProgress = elapsed;
        _prevProgressWallTime = now;
        _prevProgressRunElapsed = elapsed;
        notifyListeners();
      },
      onClear: (record) {
        clears.add(record);
        notifyListeners();
      },
      onSimulationError: (msg) {
        simulationErrors++;
        firstSimulationError ??= msg;
        if (recentSimErrors.length >= 5) recentSimErrors.removeAt(0);
        recentSimErrors.add(msg);
        notifyListeners();
      },
      onWorkerDied: (deaths) {
        workerDeaths = deaths;
        notifyListeners();
      },
      onGateStats: (total, g1, g2) {
        candidatesTotal = total;
        gate1Blocked = g1;
        gate2Blocked = g2;
        runElapsedAtGateStats = _runWatch.elapsed;
        notifyListeners();
      },
      onServantStats: (specsPerSvt, clearsPerSvt) {
        svtSpecsChecked = specsPerSvt;
        svtClears = clearsPerSvt;
      },
      onRunStats: (sg, pc, psg, psc) {
        specsGenerated = sg;
        plugSuitCandidates = pc;
        plugSuitSpecsGenerated = psg;
        plugSuitSpecsChecked = psc;
      },
      onCandidateProcessed: (processed, _) {
        candidatesProcessed = processed;
        notifyListeners();
      },
      onEngineError: (msg) {
        error = msg;
        logger.e('EngineRunner error: $msg');
        notifyListeners();
      },
      onDone: (engineMs) {
        doneLatencyMs = DateTime.now().millisecondsSinceEpoch - engineMs;
        runElapsedAtDone = _runWatch.elapsed;
        rssAtDoneMb = ProcessInfo.currentRss ~/ (1024 * 1024);
      },
    );

    try {
      await _runner!.run();
    } finally {
      _runner?.dispose();
      _runner = null;
      isStopping = false;
      _runWatch.stop();
      isRunning = false;
      notifyListeners(); // flush final state
    }
  }

  /// Sends a graceful stop signal to the running engine.
  ///
  /// The engine finishes any in-flight candidate evaluations, then exits
  /// cleanly. [isRunning] will become false once the engine reports done.
  /// Has no effect if no run is in progress.
  void stopRun() {
    if (!isRunning || isStopping) return;
    isStopping = true;
    _runner?.stop();
    notifyListeners();
  }
}

// ---------------------------------------------------------------------------
// InheritedNotifier — makes RunNotifier available in the widget tree
// ---------------------------------------------------------------------------

class RunScope extends InheritedNotifier<RunNotifier> {
  const RunScope({
    super.key,
    required super.notifier,
    required super.child,
  });

  static RunNotifier of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<RunScope>();
    assert(scope != null, 'RunScope not found in widget tree');
    return scope!.notifier!;
  }
}
