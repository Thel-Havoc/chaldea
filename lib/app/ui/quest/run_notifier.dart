/// RunNotifier — shared engine state across Quest, Results, and Status tabs.
///
/// Holds the selected quest, engine run progress, and the list of clears
/// found so far. Provided at the app level via [RunScope] so all tabs see
/// the same state regardless of which tab is currently visible.
library;

import 'package:flutter/widgets.dart';

import 'package:chaldea/app/api/atlas.dart';
import 'package:chaldea/models/models.dart';
import 'package:chaldea/packages/logger.dart';

import '../../optimizer/optimizer_engine.dart';
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
  final List<RunRecord> clears = [];
  int specsChecked = 0;
  int simulationErrors = 0;
  String? firstSimulationError;
  String? error;

  /// Wall-clock time for the current or most recent run.
  final Stopwatch _runWatch = Stopwatch();

  /// Elapsed time of the current (or most recently completed) run.
  Duration get elapsed => _runWatch.elapsed;

  // Throttle notifyListeners() to at most once per ~16 ms (one frame).
  // Progress and clear callbacks can fire hundreds of times per second;
  // rebuilding the entire QuestScreen (including 200+ dropdown items) that
  // often makes the UI churn faster than Flutter can render.
  final Stopwatch _notifyWatch = Stopwatch()..start();
  static const int _notifyIntervalMs = 16;

  void _scheduleNotify() {
    if (_notifyWatch.elapsedMilliseconds >= _notifyIntervalMs) {
      notifyListeners();
      _notifyWatch.reset();
    }
  }

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
    clears.clear();
    specsChecked = 0;
    simulationErrors = 0;
    firstSimulationError = null;
    error = null;
    _runWatch.reset();
    _runWatch.start();
    notifyListeners();

    final historyFile =
        '${db.paths.appPath}/optimizer_history_${selectedQuest!.id}.jsonl';

    try {
      final engine = OptimizerEngine(
        quest: questPhase,
        roster: roster,
        historyFilePath: historyFile,
        onProgress: (checked, _) {
          specsChecked = checked;
          _scheduleNotify();
        },
        onClear: (record) {
          clears.add(record);
          _scheduleNotify();
        },
        onSimulationError: (msg) {
          simulationErrors++;
          firstSimulationError ??= msg;
        },
      );
      await engine.run();
    } catch (e, st) {
      error = 'Engine error: $e';
      logger.e('OptimizerEngine run failed', e, st);
    } finally {
      _runWatch.stop();
      isRunning = false;
      notifyListeners(); // always flush final state unconditionally
    }
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
