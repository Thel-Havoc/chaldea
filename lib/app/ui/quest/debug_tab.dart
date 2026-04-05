/// DebugTab — post-run diagnostic report for the optimizer.
///
/// Shows gate block counts, roster attacker analysis, and quest wave
/// structure as selectable text so the user can copy and paste the
/// report for further debugging.
library;

import 'dart:io' show Platform;
import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chaldea/app/tools/gamedata_loader.dart';
import 'package:chaldea/models/models.dart';

import '../../optimizer/roster/user_roster.dart';
import '../roster/roster_notifier.dart';
import 'brute_force_debug_tab.dart';
import 'pattern_debug_tab.dart';
import 'run_notifier.dart';
import 'shared_debug_tab.dart';

class DebugTab extends StatelessWidget {
  const DebugTab({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: 'System'),
              Tab(text: 'Shared'),
              Tab(text: 'Pattern'),
              Tab(text: 'Brute Force'),
            ],
          ),
          const Expanded(
            child: TabBarView(
              children: [
                _SystemTab(),
                SharedDebugTab(),
                PatternDebugTab(),
                BruteForceDebugTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _SystemTab — the original debug report content
// ---------------------------------------------------------------------------

class _SystemTab extends StatelessWidget {
  const _SystemTab();

  @override
  Widget build(BuildContext context) {
    final run = RunScope.of(context);
    final roster = RosterScope.of(context).roster;
    final report = _buildReport(run, roster);
    final maxWorkers = Platform.numberOfProcessors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Worker count control
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              const Text('Workers:'),
              Expanded(
                child: Slider(
                  value: run.workerCount.toDouble(),
                  min: 1,
                  max: maxWorkers.toDouble(),
                  divisions: maxWorkers > 1 ? maxWorkers - 1 : null,
                  label: '${run.workerCount}',
                  onChanged: run.isRunning
                      ? null
                      : (v) => run.setWorkerCount(v.round()),
                ),
              ),
              SizedBox(
                width: 52,
                child: Text(
                  '${run.workerCount} / $maxWorkers',
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.end,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // Pass enable toggles
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Text('Passes:', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(width: 12),
              for (final (label, key, enabled) in [
                ('Shared',      'shared',     run.enableSharedPass),
                ('Pattern',     'pattern',    run.enablePatternPass),
                ('Rules',       'rules',      run.enableRulesPass),
                ('Brute Force', 'bruteForce', run.enableBruteForcePass),
              ]) ...[
                FilterChip(
                  label: Text(label),
                  selected: enabled,
                  onSelected: run.isRunning
                      ? null
                      : (v) => run.setPassEnabled(key, v),
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 8),
              ],
          if (run.enableBruteForcePass) ...[
            const SizedBox(width: 4),
            FilterChip(
              label: const Text('Dry Run'),
              selected: run.dryRunBruteForce,
              selectedColor: Colors.orange.withValues(alpha: 0.2),
              checkmarkColor: Colors.orange,
              onSelected: run.isRunning
                  ? null
                  : (v) => run.setDryRunBruteForce(v),
              visualDensity: VisualDensity.compact,
            ),
          ],
            ],
          ),
        ),
        const Divider(height: 1),
        const _GameDataSection(),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy Report'),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: report));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Report copied to clipboard'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              report,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.6,
              ),
            ),
          ),
        ),
      ],
    );
  }
} // end _SystemTab

// ---------------------------------------------------------------------------
// _GameDataSection — shows current game data version + manual update button
// ---------------------------------------------------------------------------

class _GameDataSection extends StatefulWidget {
  const _GameDataSection();

  @override
  State<_GameDataSection> createState() => _GameDataSectionState();
}

class _GameDataSectionState extends State<_GameDataSection> {
  bool _checking = false;
  String? _status;

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _status = null;
    });
    try {
      final updated =
          await GameDataLoader.instance.reload(offline: false, silent: false);
      if (!mounted) return;
      if (updated != null) {
        db.gameData = updated;
        setState(() => _status = 'Updated to ${updated.version.utc}');
      } else {
        setState(
            () => _status = 'Already up to date (${db.gameData.version.utc})');
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Game data: ${db.gameData.version.utc}',
                    style: textTheme.bodySmall),
                if (_status != null)
                  Text(_status!, style: textTheme.bodySmall),
              ],
            ),
          ),
          TextButton.icon(
            icon: _checking
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.system_update_alt, size: 16),
            label: const Text('Check for Updates'),
            onPressed: _checking ? null : _check,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Report builder (free function — was a static method of DebugTab)
// ---------------------------------------------------------------------------

String _buildReport(RunNotifier run, UserRoster roster) {
    final svtSpecCounts = run.svtSpecsChecked;
    final svtClearCounts = run.svtClears;
    final buf = StringBuffer();
    final now = DateTime.now();

    buf.writeln('=== Optimizer Debug Report ===');
    buf.writeln('Generated: ${now.year}-${_pad(now.month)}-${_pad(now.day)}'
        ' ${_pad(now.hour)}:${_pad(now.minute)}:${_pad(now.second)}');
    buf.writeln();

    // --- Run Summary ---
    buf.writeln('--- Run Summary ---');
    final status = run.isRunning
        ? 'Running...'
        : run.specsChecked > 0
            ? 'Complete'
            : 'Not started';
    buf.writeln('Status:   $status');
    buf.writeln('Workers:  ${run.workerCount} / ${Platform.numberOfProcessors}');
    buf.writeln('Duration: ${_fmtDuration(run.elapsed)}');

    if (run.selectedWar != null || run.selectedQuest != null) {
      final war = run.selectedWar?.lName.l ?? '?';
      final quest = run.selectedQuest?.lName.l ?? '?';
      final phase = run.loadedPhase?.phase.toString() ?? '?';
      buf.writeln('Quest:    $war / $quest (Phase $phase)');
    } else {
      buf.writeln('Quest:    (none selected)');
    }
    buf.writeln();

    // --- Process Memory ---
    buf.writeln('--- Process Memory (RSS) ---');
    buf.writeln('At run start:    ${_fmtN(run.rssAtRunStartMb)} MB');
    if (run.rssAtFirstProgressMb > 0) {
      buf.writeln('At first result: ${_fmtN(run.rssAtFirstProgressMb)} MB'
          '  (+${_fmtN(run.rssAtFirstProgressMb - run.rssAtRunStartMb)} MB'
          ' — ${run.workerCount} workers loaded)');
    }
    if (run.rssAtFreezeStartMb > 0) {
      buf.writeln('At freeze start: ${_fmtN(run.rssAtFreezeStartMb)} MB'
          '  (← heap size when GC triggered)');
    }
    if (run.rssAtDoneMb > 0) {
      buf.writeln('At run end:      ${_fmtN(run.rssAtDoneMb)} MB');
    }
    buf.writeln();

    // --- Root Isolate Responsiveness ---
    buf.writeln('--- Root Isolate Responsiveness ---');
    buf.writeln('(Measures whether root-isolate event loop ran during the run)');
    final gateElapsed = run.runElapsedAtGateStats;
    final firstProgress = run.runElapsedAtFirstProgress;
    if (gateElapsed != null) {
      buf.writeln('Pruning done at:               run+${_fmtDuration(gateElapsed)}');
    } else {
      buf.writeln('Pruning done at:               (not recorded)');
    }
    if (firstProgress != null) {
      buf.writeln('First candidate result at:     run+${_fmtDuration(firstProgress)}');
      if (gateElapsed != null) {
        final loadMs = firstProgress.inMilliseconds - gateElapsed.inMilliseconds;
        buf.writeln('  Worker load/first-run delta: ${_fmtN(loadMs)}ms');
      }
    } else {
      buf.writeln('First candidate result at:     (none)');
    }
    final doneAt = run.runElapsedAtDone;
    if (doneAt != null) {
      buf.writeln('Engine finished at:            run+${_fmtDuration(doneAt)}');
      buf.writeln('  \'done\' msg latency:          ${_fmtN(run.doneLatencyMs)}ms'
          '${run.doneLatencyMs > 5000 ? '  ← root still blocked after engine finished' : ''}');
    } else {
      buf.writeln('Engine finished at:            (not recorded)');
    }
    final lastProgress = run.runElapsedAtLastProgress;
    if (lastProgress != null) {
      buf.writeln('Last progress msg at:          run+${_fmtDuration(lastProgress)}');
    }
    // Engine compute span: how long the engine was actually sending results.
    // If this ≈ total run duration → workers ran the whole time (scheduler starvation).
    // If this << total run duration → workers were also paused (GC stop-the-world).
    if (run.firstProgressEngineMs > 0 && run.lastProgressEngineMs > run.firstProgressEngineMs) {
      final spanMs = run.lastProgressEngineMs - run.firstProgressEngineMs;
      final spanDur = Duration(milliseconds: spanMs);
      buf.writeln('Engine compute span:           ${_fmtDuration(spanDur)}'
          ' (first→last candidate sent by engine)');
      buf.writeln('  vs total run duration:       ${_fmtDuration(run.elapsed)}');
      buf.writeln('  (≈ run → workers ran all along; << run → workers also froze)');
    }
    final expectedProgress = run.candidatesPassed;
    buf.writeln('Progress msgs on root isolate: '
        '${_fmtN(run.progressMsgsReceived)} / ~${_fmtN(expectedProgress)} expected');
    buf.writeln('  High-latency (>5s):           ${_fmtN(run.highLatencyProgressCount)}');
    buf.writeln('  (<<expected = most messages queued, processed in burst at end)');
    final freezeStart = run.runElapsedAtFreezeStart;
    final freezeEnd = run.runElapsedAtFreezeEnd;
    buf.writeln('Longest freeze (root isolate): ${_fmtN(run.maxProgressIntervalMs)}ms'
        ' (msg #${run.maxProgressIntervalIndex - 1} → #${run.maxProgressIntervalIndex})');
    if (freezeStart != null && freezeEnd != null) {
      buf.writeln('  Freeze window:               run+${_fmtDuration(freezeStart)} → run+${_fmtDuration(freezeEnd)}');
    }
    buf.writeln('  (Expected: ~${expectedProgress > 0 && run.elapsed.inSeconds > 0 ? _fmtN((run.elapsed.inMilliseconds / expectedProgress).round()) : "?"}ms avg; large = root isolate blocked)');
    buf.writeln('Max engine→root queue latency: ${_fmtN(run.maxEngineRootLatencyMs)}ms');
    buf.writeln('  (Large = message sat in port queue while root isolate was blocked)');
    buf.writeln();

    if (run.candidatesTotal > 0 || run.specsChecked > 0) {
      final passed =
          run.candidatesTotal - run.gate1Blocked - run.gate2Blocked;
      buf.writeln('Candidates generated:         ${_fmtN(run.candidatesTotal)}');
      buf.writeln('  Gate 1 (NP charge) blocked: ${_fmtN(run.gate1Blocked)}');
      buf.writeln('  Gate 2 (damage)    blocked: ${_fmtN(run.gate2Blocked)}');
      buf.writeln('  Passed pruning:             ${_fmtN(passed)}');
      buf.writeln('Specs simulated:              ${_fmtN(run.specsChecked)}');
      if (run.specsGenerated > 0) {
        final passed =
            run.candidatesTotal - run.gate1Blocked - run.gate2Blocked;
        final nonPlugSuitCandidates =
            passed - run.plugSuitCandidates;
        final nonPlugSuitGenerated =
            run.specsGenerated - run.plugSuitSpecsGenerated;
        final nonPlugSuitChecked =
            run.specsChecked - run.plugSuitSpecsChecked;

        buf.writeln(
            'Specs generated (pre-early-exit):    ${_fmtN(run.specsGenerated)}');
        buf.writeln(
            '  Plug Suit (MC 20/210): ${_fmtN(run.plugSuitCandidates)} candidates');
        buf.writeln(
            '    Generated: ${_fmtN(run.plugSuitSpecsGenerated)}'
            '  (~${run.plugSuitCandidates > 0 ? (run.plugSuitSpecsGenerated / run.plugSuitCandidates).round() : 0} / candidate)');
        buf.writeln(
            '    Checked:   ${_fmtN(run.plugSuitSpecsChecked)}'
            '  (~${run.plugSuitCandidates > 0 ? (run.plugSuitSpecsChecked / run.plugSuitCandidates).round() : 0} / candidate)');
        buf.writeln(
            '  Other MC:   ${_fmtN(nonPlugSuitCandidates)} candidates');
        buf.writeln(
            '    Generated: ${_fmtN(nonPlugSuitGenerated)}'
            '  (~${nonPlugSuitCandidates > 0 ? (nonPlugSuitGenerated / nonPlugSuitCandidates).round() : 0} / candidate)');
        buf.writeln(
            '    Checked:   ${_fmtN(nonPlugSuitChecked)}'
            '  (~${nonPlugSuitCandidates > 0 ? (nonPlugSuitChecked / nonPlugSuitCandidates).round() : 0} / candidate)');
      }
      buf.writeln('Clearing specs found:         ${run.clears.length}');
      buf.writeln('Simulation errors:            ${run.simulationErrors}');
      buf.writeln('Worker deaths (restarted):    ${run.workerDeaths}');
      if (run.error != null) {
        buf.writeln('Engine error: ${run.error}');
      }
    } else {
      buf.writeln('(No run data yet — start a run from the Quest tab)');
    }
    buf.writeln();

    // --- Quest Wave Structure ---
    buf.writeln('--- Quest Wave Structure ---');
    final phase = run.loadedPhase;
    if (phase == null) {
      buf.writeln('(No quest loaded)');
    } else {
      for (int wi = 0; wi < phase.stages.length; wi++) {
        final enemies = phase.stages[wi].enemies;
        if (enemies.isEmpty) continue;
        final hps = enemies.map((e) => _fmtN(e.hp)).join(' / ');
        final maxHp = enemies.map((e) => e.hp).reduce(max);
        final noun = enemies.length == 1 ? 'enemy ' : 'enemies';
        buf.writeln('Wave ${wi + 1}: ${enemies.length} $noun'
            '  HP: $hps  (max: ${_fmtN(maxHp)})');
      }
    }
    buf.writeln();

    // --- Roster Servant Analysis ---
    final attackers = roster.servants.entries
        .where((e) => e.value.roles.contains(ServantRole.attacker))
        .toList();
    final supportsOnly = roster.servants.entries
        .where((e) =>
            e.value.roles.contains(ServantRole.support) &&
            !e.value.roles.contains(ServantRole.attacker))
        .toList();

    buf.writeln('--- Roster Attackers ---');
    buf.writeln('(tagged Attacker — will be assigned NP turns by the engine)');
    if (attackers.isEmpty) {
      buf.writeln('  (none — tag at least one servant as Attacker in the Roster tab)');
    } else {
      for (final e in attackers) {
        _writeServantLine(buf, e.key, e.value,
            showNpType: true,
            specsChecked: svtSpecCounts[e.key],
            specsCleared: svtClearCounts[e.key]);
      }
    }
    buf.writeln();

    buf.writeln('--- Roster Supports ---');
    buf.writeln('(tagged Support-only — will NOT be assigned NP turns)');
    if (supportsOnly.isEmpty) {
      buf.writeln('  (none)');
    } else {
      for (final e in supportsOnly) {
        _writeServantLine(buf, e.key, e.value, showNpType: false);
      }
    }
    buf.writeln();

    // --- Simulation Errors ---
    buf.writeln('--- Simulation Errors (last ${run.recentSimErrors.length}) ---');
    if (run.simulationErrors == 0 && run.workerDeaths == 0) {
      buf.writeln('(none)');
    } else {
      buf.writeln('Total errors: ${run.simulationErrors}');
      buf.writeln('Worker deaths: ${run.workerDeaths}');
      for (int i = 0; i < run.recentSimErrors.length; i++) {
        buf.writeln('[${i + 1}] ${run.recentSimErrors[i]}');
        buf.writeln();
      }
    }

    return buf.toString();
  }

void _writeServantLine(
    StringBuffer buf,
    int svtId,
    OwnedServant owned, {
    required bool showNpType,
    int? specsChecked,
    int? specsCleared,
  }) {
    final svt = db.gameData.servantsById[svtId];
    final name = svt?.lName.l ?? 'Unknown (ID $svtId)';
    final skills = owned.skillLevels.join('/');
    final append2Level =
        owned.appendLevels.length > 1 ? owned.appendLevels[1] : 0;
    final append2Str =
        append2Level > 0 ? 'Append2: Lv$append2Level' : 'Append2: ---';
    final bothRoles = owned.roles.length > 1 ? ' [ATK+SUP]' : '';

    String npTypeStr = '';
    if (showNpType && svt != null) {
      final nps = svt.groupedNoblePhantasms[1] ?? [];
      if (nps.isEmpty) {
        npTypeStr = ' | No NP data';
      } else {
        final hasAoe = nps.any((np) => np.damageType == TdEffectFlag.attackEnemyAll);
        final hasSt = nps.any((np) => np.damageType == TdEffectFlag.attackEnemyOne);
        final hasSupport = nps.any((np) => np.damageType == TdEffectFlag.support);
        if (hasAoe && (hasSt || hasSupport)) {
          npTypeStr = ' | AoE NP (form change)';
        } else if (hasAoe) {
          npTypeStr = ' | AoE NP';
        } else if (hasSt) {
          npTypeStr = ' | ST NP — cannot solo-clear multi-enemy waves';
        } else {
          npTypeStr = ' | Support NP — engine will not assign NP turns';
        }
      }
    }

    final statsStr = specsChecked != null
        ? ' | Specs: ${_fmtN(specsChecked)} tried, ${_fmtN(specsCleared ?? 0)} cleared'
        : '';

    buf.writeln('  $name | Lv${owned.level} NP${owned.npLevel}'
        ' | Skills $skills | Asc${owned.limitCount}'
        ' | $append2Str$npTypeStr$bothRoles$statsStr');
  }

  // ---------------------------------------------------------------------------
  // Formatting helpers
  // ---------------------------------------------------------------------------

String _fmtDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '$h:${_pad(m)}:${_pad(s)}';
    return '$m:${_pad(s)}';
  }

  /// Formats [n] with comma separators: 1234567 → "1,234,567".
String _fmtN(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

String _pad(int n) => n.toString().padLeft(2, '0');
