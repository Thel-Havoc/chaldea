/// ResultsScreen — live list of clearing teams found by the optimizer.
///
/// Clears are grouped by team composition (servant + CE per slot). All specs
/// for the same team that clear via different skill timings appear as a single
/// row; the detail page breaks them out individually.
library;

import 'dart:math' show min;

import 'package:flutter/material.dart';

import 'package:chaldea/models/models.dart';
import 'package:chaldea/utils/extension.dart';

import '../../optimizer/roster/run_history.dart';
import 'clear_group_detail_page.dart';
import 'run_notifier.dart';

// ---------------------------------------------------------------------------
// GroupedResult — all RunRecords sharing the same servant + CE layout
// ---------------------------------------------------------------------------

class GroupedResult {
  final List<RunRecord> records = [];

  /// Stable identity key for a team, based only on slots that actually
  /// participate in combat (use a skill or fire an NP). Inactive backline
  /// servants — ones that never swap in — are excluded so that the same
  /// frontline team with different unused bench members groups together.
  ///
  /// CE is included in the key only for NP-firing (attacker) slots.
  /// CEs on supports don't affect farming outcome, so putting Bella Lisa
  /// on Castoria shouldn't create a different "team" in the results.
  static String keyFor(RunRecord r) {
    final activeSlots = <int>{};
    final attackerSlots = <int>{};
    for (final action in r.battleData.actions) {
      if (action.type == BattleRecordDataType.skill) {
        final svt = action.svt;
        if (svt != null) activeSlots.add(svt);
      } else if (action.type == BattleRecordDataType.attack) {
        for (final a in action.attacks ?? []) {
          if (a.isTD) {
            activeSlots.add(a.svt);
            attackerSlots.add(a.svt);
          }
        }
      }
    }

    final svts = r.battleData.formation.svts;
    final sorted = activeSlots.toList()..sort();
    return sorted.map((i) {
      final s = svts.getOrNull(i);
      final svtId = s?.svtId ?? 0;
      // Include CE only for attacker slots whose NP actually deals damage.
      // Support servants (Castoria, Merlin, Waver, Oberon) have damageType==support
      // so their CE never affects farming outcome even if they fire NP.
      final np = svtId != 0
          ? db.gameData.servantsById[svtId]?.groupedNoblePhantasms[1]?.firstOrNull
          : null;
      final hasDamageNp = np != null && np.damageType != TdEffectFlag.support;
      final ceId = (attackerSlots.contains(i) && hasDamageNp) ? (s?.equip1.id ?? 0) : 0;
      return '$i:$svtId:$ceId';
    }).join('|');
  }

  /// True if any spec in this group clears without RNG dependence.
  bool get isGuaranteed => records.any((r) => r.clearsAtMinDamage);

  /// Fewest button presses across all specs in this group.
  int get bestButtonPresses => records.map((r) => r.buttonPresses).reduce(min);

  /// Fewest turns across all specs in this group.
  int get bestTurns => records.map((r) => r.totalTurns).reduce(min);

  /// Formation slots — same for every record in the group.
  List<SvtSaveData?> get slots => records.first.battleData.formation.svts;

  /// Slot indices of servants that fire an NP (from the first record's log).
  Set<int> get attackerSlots => records.first.battleData.actions
      .where((a) => a.type == BattleRecordDataType.attack)
      .expand((a) => a.attacks ?? [])
      .where((a) => a.isTD)
      .map((a) => a.svt as int)
      .toSet();

  /// Slot indices of all servants who appear in any action (skill or NP).
  Set<int> get activeSlots {
    final result = <int>{};
    for (final action in records.first.battleData.actions) {
      if (action.type == BattleRecordDataType.skill) {
        final svt = action.svt;
        if (svt != null) result.add(svt);
      } else if (action.type == BattleRecordDataType.attack) {
        for (final a in action.attacks ?? []) {
          if (a.isTD) result.add(a.svt);
        }
      }
    }
    return result;
  }
}

// ---------------------------------------------------------------------------
// ResultsScreen
// ---------------------------------------------------------------------------

class ResultsScreen extends StatelessWidget {
  const ResultsScreen({super.key});

  static List<GroupedResult> _groupAndSort(List<RunRecord> clears) {
    final map = <String, GroupedResult>{};
    for (final r in clears) {
      (map[GroupedResult.keyFor(r)] ??= GroupedResult()).records.add(r);
    }
    final groups = map.values.toList();
    groups.sort((a, b) {
      // 1. Guaranteed clears first
      final gCmp = (b.isGuaranteed ? 1 : 0) - (a.isGuaranteed ? 1 : 0);
      if (gCmp != 0) return gCmp;
      // 2. Fewest button presses
      final bCmp = a.bestButtonPresses.compareTo(b.bestButtonPresses);
      if (bCmp != 0) return bCmp;
      // 3. Fewest turns
      return a.bestTurns.compareTo(b.bestTurns);
    });
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final run = RunScope.of(context);

    final groups = run.clears.isEmpty ? <GroupedResult>[] : _groupAndSort(run.clears);
    final statusBar = _StatusBar(run: run, groupCount: groups.length);

    if (run.clears.isEmpty) {
      return Column(
        children: [
          statusBar,
          Expanded(
            child: Center(
              child: Text(
                run.isRunning ? 'Searching… no clears yet' : 'No clears found.',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        statusBar,
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: groups.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) => _ClearGroupTile(group: groups[i]),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _ClearGroupTile
// ---------------------------------------------------------------------------

class _ClearGroupTile extends StatelessWidget {
  final GroupedResult group;
  const _ClearGroupTile({required this.group});

  static String _svtName(int? svtId) {
    if (svtId == null || svtId == 0) return '?';
    return db.gameData.servantsById[svtId]?.lName.l ?? 'Svt $svtId';
  }

  static String _ceName(int? ceId) {
    if (ceId == null || ceId == 0) return 'No CE';
    return db.gameData.craftEssencesById[ceId]?.lName.l ?? 'CE $ceId';
  }

  @override
  Widget build(BuildContext context) {
    final slots = group.slots;
    final active = group.activeSlots.toList()..sort();
    final attackerSlots = group.attackerSlots;

    // Only servants who actually participate in combat, with role label
    final svtNames = active.map((i) {
      final name = _svtName(slots.getOrNull(i)?.svtId);
      final role = attackerSlots.contains(i) ? ' [ATK]' : ' [SUP]';
      return name + role;
    }).toList();

    // CEs for NP-firing (attacker) slots only
    final ceParts = (attackerSlots.toList()..sort())
        .map((idx) => _ceName(slots.getOrNull(idx)?.equip1.id))
        .toList();

    final variantText = group.records.length == 1
        ? '1 variant · ${group.bestButtonPresses} presses'
        : '${group.records.length} variants · best ${group.bestButtonPresses} presses';

    final textTheme = Theme.of(context).textTheme;

    return ListTile(
      leading: _ReliabilityBadge(guaranteed: group.isGuaranteed),
      title: Text(svtNames.join(' · '), overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (ceParts.isNotEmpty)
            Text(
              ceParts.join(' · '),
              style: textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          Text(variantText, style: textTheme.bodySmall),
        ],
      ),
      isThreeLine: ceParts.isNotEmpty,
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ClearGroupDetailPage(group: group),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _ReliabilityBadge — shared by this file and the detail page
// ---------------------------------------------------------------------------

class ReliabilityBadge extends StatelessWidget {
  final bool guaranteed;
  const ReliabilityBadge({super.key, required this.guaranteed});

  @override
  Widget build(BuildContext context) => _ReliabilityBadge(guaranteed: guaranteed);
}

// ---------------------------------------------------------------------------
// _StatusBar — specs checked + clears summary shown above the list
// ---------------------------------------------------------------------------

class _StatusBar extends StatelessWidget {
  final RunNotifier run;
  final int groupCount;
  const _StatusBar({required this.run, required this.groupCount});

  @override
  Widget build(BuildContext context) {
    if (!run.isRunning && run.specsChecked == 0) return const SizedBox.shrink();

    final clearText = run.clears.isEmpty
        ? 'no clears yet'
        : '${run.clears.length} clear${run.clears.length == 1 ? '' : 's'}'
            ' across $groupCount team${groupCount == 1 ? '' : 's'}';

    final label = run.isRunning
        ? 'Searching… ${_fmt(run.specsChecked)} specs · $clearText'
        : '${_fmt(run.specsChecked)} specs checked · $clearText';

    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(label, style: Theme.of(context).textTheme.bodySmall),
    );
  }

  static String _fmt(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }
}

class _ReliabilityBadge extends StatelessWidget {
  final bool guaranteed;
  const _ReliabilityBadge({required this.guaranteed});

  @override
  Widget build(BuildContext context) {
    final color =
        guaranteed ? Colors.green.shade700 : Colors.amber.shade800;
    final label = guaranteed ? 'Guaranteed' : 'RNG';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
