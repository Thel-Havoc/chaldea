/// OptimizerApp — root widget for the FGO Team Optimizer.
///
/// Wraps MaterialApp and handles the game-data loading phase. Once
/// [GameDataLoader] finishes, hands off to [MainShell].
library;

import 'package:flutter/material.dart';

import 'package:window_manager/window_manager.dart';

import 'package:chaldea/app/tools/gamedata_loader.dart';
import 'package:chaldea/models/models.dart';
import 'package:chaldea/packages/logger.dart';

import 'quest/run_notifier.dart';
import 'roster/roster_notifier.dart';
import 'shell/main_shell.dart';

class OptimizerApp extends StatefulWidget {
  const OptimizerApp({super.key});

  @override
  State<OptimizerApp> createState() => _OptimizerAppState();
}

class _OptimizerAppState extends State<OptimizerApp> with WindowListener {
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Future<void> onWindowClose() async {
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FGO Team Optimizer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const _LoadingGate(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// ---------------------------------------------------------------------------
// Loading gate — loads game data, then mounts the shell
// ---------------------------------------------------------------------------

class _LoadingGate extends StatefulWidget {
  const _LoadingGate();

  @override
  State<_LoadingGate> createState() => _LoadingGateState();
}

class _LoadingGateState extends State<_LoadingGate> {
  bool _loaded = false;
  String? _error;
  RosterNotifier? _rosterNotifier;
  final RunNotifier _runNotifier = RunNotifier();

  @override
  void initState() {
    super.initState();
    _loadGameData();
  }

  Future<void> _loadGameData() async {
    setState(() {
      _error = null;
      _loaded = false;
    });
    try {
      final data = await GameDataLoader.instance.reload(offline: true, silent: true);
      if (!mounted) return;
      if (data == null) {
        setState(() => _error = 'Could not load game data.\nMake sure Chaldea has downloaded data at least once.');
        return;
      }
      db.gameData = data;
      _rosterNotifier = RosterNotifier(db.paths.appPath);
      setState(() => _loaded = true);
      // After showing the UI, silently check for updated game data in the background.
      _checkForGameDataUpdate();
    } catch (e, st) {
      logger.e('OptimizerApp: game data load failed', e, st);
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// Checks for updated game data online. If new data is available, updates
  /// [db.gameData] and rebuilds. Silent — never shows an error to the user.
  /// Called automatically after startup and can be triggered manually.
  Future<void> _checkForGameDataUpdate() async {
    final updated = await GameDataLoader.instance.reload(offline: false, silent: true);
    if (updated != null && mounted) {
      setState(() => db.gameData = updated);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 64, color: Colors.red),
                const SizedBox(height: 16),
                Text('Failed to load game data',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: _loadGameData,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (!_loaded) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Loading game data...'),
            ],
          ),
        ),
      );
    }

    return RunScope(
      notifier: _runNotifier,
      child: RosterScope(
        notifier: _rosterNotifier!,
        child: const MainShell(),
      ),
    );
  }
}
