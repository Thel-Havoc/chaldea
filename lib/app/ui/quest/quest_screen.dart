/// QuestScreen — select a quest and launch the optimizer.
///
/// Section dropdown: active events first, then upcoming (within 1 week),
/// then Chaldea Gate dailies, then other permanent free quests.
/// Quest dropdown: quests within the selected war that have local phase data.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chaldea/models/models.dart';

import '../roster/roster_notifier.dart';
import 'run_notifier.dart';

class QuestScreen extends StatefulWidget {
  const QuestScreen({super.key});

  @override
  State<QuestScreen> createState() => _QuestScreenState();
}

class _QuestScreenState extends State<QuestScreen> {
  late final List<_WarEntry> _wars;
  // ignore: prefer_final_fields
  String _sectionSearch = '';
  late final TextEditingController _sectionSearchCtrl;

  @override
  void initState() {
    super.initState();
    _wars = _buildWarList();
    _sectionSearchCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _sectionSearchCtrl.dispose();
    super.dispose();
  }

  List<_WarEntry> get _filteredWars {
    final q = _sectionSearch.toLowerCase();
    if (q.isEmpty) return _wars;
    return _wars.where((e) => e.label.toLowerCase().contains(q)).toList();
  }

  // ---------------------------------------------------------------------------
  // Data helpers
  // ---------------------------------------------------------------------------

  /// Quests in [war] that have enemy phase data (needed to simulate).
  /// Phase data may be local or fetched from Atlas on selection.
  static List<Quest> _farmableQuests(NiceWar war) {
    return war.quests
        .where((q) => q.phasesWithEnemies.isNotEmpty)
        .toList()
      ..sort((a, b) => a.id.compareTo(b.id));
  }

  static List<_WarEntry> _buildWarList() {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final oneWeekLater = now + 7 * 24 * 3600;

    final active = <NiceWar>[];
    final upcoming = <NiceWar>[];
    final otherEvent = <NiceWar>[];
    final chaldeaGate = <NiceWar>[];
    final permanent = <NiceWar>[];

    for (final war in db.gameData.wars.values) {
      if (_farmableQuests(war).isEmpty) continue;

      if (war.id == WarId.chaldeaGate) {
        chaldeaGate.add(war);
      } else if (war.eventId != 0) {
        final event = db.gameData.events[war.eventId];
        final start = event?.startTimeOf(Region.na);
        final end = event?.endTimeOf(Region.na);
        if (start != null && end != null && start <= now && end > now) {
          active.add(war);
        } else if (start != null && start > now && start <= oneWeekLater) {
          upcoming.add(war);
        } else {
          // Ended events, Ordeal Call, events without NA timing, etc.
          otherEvent.add(war);
        }
      } else {
        permanent.add(war);
      }
    }

    for (final list in [active, upcoming, otherEvent, chaldeaGate, permanent]) {
      list.sort((a, b) => a.id.compareTo(b.id));
    }

    return [
      ...active.map((w) => _WarEntry(w, '[Active] ${w.lName.l}')),
      ...upcoming.map((w) => _WarEntry(w, '[Soon] ${w.lName.l}')),
      ...otherEvent.map((w) => _WarEntry(w, w.lName.l)),
      ...chaldeaGate.map((w) => _WarEntry(w, '[Daily] ${w.lName.l}')),
      ...permanent.map((w) => _WarEntry(w, w.lName.l)),
    ];
  }

  /// Wave structure string like "1 / 3 / 1" from a loaded [QuestPhase].
  static String _waveStructure(QuestPhase qp) =>
      qp.stages.map((s) => s.enemies.length).join(' / ');

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final run = RunScope.of(context);
    final roster = RosterScope.of(context).roster;

    final selectedEntry =
        _wars.where((e) => e.war == run.selectedWar).firstOrNull;
    final quests =
        selectedEntry == null ? <Quest>[] : _farmableQuests(selectedEntry.war);
    final waveInfo =
        run.loadedPhase != null ? _waveStructure(run.loadedPhase!) : null;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label(context, 'Section'),
          TextField(
            controller: _sectionSearchCtrl,
            decoration: const InputDecoration(
              hintText: 'Search sections...',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => setState(() => _sectionSearch = v),
          ),
          const SizedBox(height: 8),
          _Dropdown<NiceWar>(
            value: run.selectedWar,
            hint: 'Select section',
            items: [
              for (final entry in _filteredWars)
                DropdownMenuItem(
                  value: entry.war,
                  child: Text(entry.label, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: run.isRunning ? null : run.selectWar,
          ),
          const SizedBox(height: 16),

          _label(context, 'Quest'),
          _Dropdown<Quest>(
            value: run.selectedQuest,
            hint: 'Select quest',
            items: [
              for (final q in quests)
                DropdownMenuItem(
                  value: q,
                  child: Text(
                    q.recommendLv.isNotEmpty
                        ? '${q.lName.l} (${q.recommendLv})'
                        : q.lName.l,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (run.isRunning || quests.isEmpty)
                ? null
                : run.selectQuest,
          ),
          const SizedBox(height: 8),

          // Wave structure / loading / error
          if (waveInfo != null)
            Text('Waves: $waveInfo',
                style: Theme.of(context).textTheme.bodySmall)
          else if (run.isLoadingPhase)
            Row(children: [
              const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 8),
              Text('Loading quest data…',
                  style: Theme.of(context).textTheme.bodySmall),
            ])
          else if (run.phaseLoadError != null)
            Text(run.phaseLoadError!,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 24),

          // Run button
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: (run.selectedQuest == null ||
                      run.isRunning ||
                      run.isLoadingPhase ||
                      run.loadedPhase == null)
                  ? null
                  : () => run.run(roster),
              child: run.isRunning
                  ? const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                        SizedBox(width: 8),
                        Text('Running…'),
                      ],
                    )
                  : const Text('Run Optimizer'),
            ),
          ),
          const SizedBox(height: 16),

          // Status / error
          if (run.isRunning || run.specsChecked > 0 || run.clears.isNotEmpty)
            _StatusCard(run: run),

          if (run.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                run.error!,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }

  Widget _label(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: Theme.of(context).textTheme.labelLarge),
      );
}

// ---------------------------------------------------------------------------
// Status card — shown while running and after completion
// ---------------------------------------------------------------------------

class _StatusCard extends StatefulWidget {
  final RunNotifier run;
  const _StatusCard({required this.run});

  @override
  State<_StatusCard> createState() => _StatusCardState();
}

class _StatusCardState extends State<_StatusCard> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    if (widget.run.isRunning) _startTicker();
    widget.run.addListener(_onRunChanged);
  }

  @override
  void dispose() {
    widget.run.removeListener(_onRunChanged);
    _ticker?.cancel();
    super.dispose();
  }

  void _onRunChanged() {
    if (widget.run.isRunning) {
      _startTicker();
    } else {
      _ticker?.cancel();
      _ticker = null;
      if (mounted) setState(() {});
    }
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final run = widget.run;
    final elapsed = _fmt(run.elapsed);
    final statusText = run.isRunning
        ? 'Checking… ${run.specsChecked} specs ($elapsed)'
        : 'Done — ${run.specsChecked} specs checked in $elapsed';

    final errorColor = Theme.of(context).colorScheme.error;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(statusText, style: Theme.of(context).textTheme.bodyMedium),
            Text(
              '${run.clears.length} clear${run.clears.length == 1 ? '' : 's'} found',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (run.simulationErrors > 0) ...[
              const SizedBox(height: 4),
              Text(
                '${run.simulationErrors} simulation error${run.simulationErrors == 1 ? '' : 's'}',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: errorColor),
              ),
              if (run.firstSimulationError != null)
                Text(
                  run.firstSimulationError!,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: errorColor),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Reusable outlined dropdown (DropdownButton + InputDecorator).
// DropdownButtonFormField.value is deprecated in Flutter 3.33+; this wrapper
// keeps controlled state without the deprecation warning.
// ---------------------------------------------------------------------------

class _Dropdown<T> extends StatelessWidget {
  final T? value;
  final String hint;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;

  const _Dropdown({
    required this.value,
    required this.hint,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: DropdownButton<T>(
        value: value,
        hint: Text(hint),
        isExpanded: true,
        underline: const SizedBox.shrink(),
        items: items,
        onChanged: onChanged,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Internal data model
// ---------------------------------------------------------------------------

class _WarEntry {
  final NiceWar war;
  final String label;
  _WarEntry(this.war, this.label);
}
