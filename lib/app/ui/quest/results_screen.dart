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
    final (:activeSlots, :attackerSlots) = _resolveSlots(r);

    final svts = r.battleData.formation.svts;
    final sorted = activeSlots.toList()..sort();
    final svtPart = sorted.map((i) {
      final s = svts.getOrNull(i);
      final svtId = s?.svtId ?? 0;
      // Include CE only for attacker slots whose NP actually deals damage.
      final np = svtId != 0
          ? db.gameData.servantsById[svtId]?.groupedNoblePhantasms[1]?.firstOrNull
          : null;
      final hasDamageNp = np != null && np.damageType != TdEffectFlag.support;
      final ceId = (attackerSlots.contains(i) && hasDamageNp) ? (s?.equip1.id ?? 0) : 0;
      return '$i:$svtId:$ceId';
    }).join('|');

    // Include MC in the key — same servants with different MCs are different teams.
    final mcId = r.battleData.formation.mysticCode.mysticCodeId ?? 0;
    return '$svtPart|mc:$mcId';
  }

  /// True if any spec in this group clears without RNG dependence.
  bool get isGuaranteed => records.any((r) => r.clearsAtMinDamage);

  /// Fewest button presses across all specs in this group.
  int get bestButtonPresses => records.map((r) => r.buttonPresses).reduce(min);

  /// Fewest turns across all specs in this group.
  int get bestTurns => records.map((r) => r.totalTurns).reduce(min);

  /// Formation slots — same for every record in the group.
  List<SvtSaveData?> get slots => records.first.battleData.formation.svts;

  /// Slot indices of servants that fire an NP (from the first record's log),
  /// remapped to original formation indices after any Order Changes.
  Set<int> get attackerSlots => _resolveSlots(records.first).attackerSlots;

  /// Slot indices of all servants who appear in any action (skill or NP),
  /// remapped to original formation indices after any Order Changes.
  Set<int> get activeSlots => _resolveSlots(records.first).activeSlots;

  /// Resolves active and attacker formation-slot indices from the action log,
  /// applying Order Change remapping so post-swap servant skills are
  /// attributed to the correct original formation slot.
  ///
  /// Without this, a servant like Oberon who swaps in via Order Change would
  /// be attributed to the servant who occupied his field slot before the swap.
  static ({Set<int> activeSlots, Set<int> attackerSlots}) _resolveSlots(
      RunRecord r) {
    final active = <int>{};
    final attackers = <int>{};
    // Maps field-slot index → original formation-slot index. Starts as identity.
    final slotRemap = <int, int>{};
    int ocIdx = 0;
    final delegate = r.battleData.delegate;

    for (final action in r.battleData.actions) {
      if (action.type == BattleRecordDataType.skill) {
        final svt = action.svt;
        if (svt != null) {
          active.add(slotRemap[svt] ?? svt);
        } else if (action.skill == 2 &&
            delegate != null &&
            ocIdx < delegate.replaceMemberIndexes.length) {
          // MC S3 Order Change: the incoming servant gets added to active slots.
          final pair = delegate.replaceMemberIndexes[ocIdx++];
          final fieldSlot = pair[0];
          final backlineFormationSlot = 3 + pair[1];
          active.add(slotRemap[backlineFormationSlot] ?? backlineFormationSlot);
          // Swap the remap entries for the two involved slots.
          final prevField = slotRemap[fieldSlot] ?? fieldSlot;
          final prevBench = slotRemap[backlineFormationSlot] ?? backlineFormationSlot;
          slotRemap[fieldSlot] = prevBench;
          slotRemap[backlineFormationSlot] = prevField;
        }
      } else if (action.type == BattleRecordDataType.attack) {
        for (final a in action.attacks ?? []) {
          if (a.isTD) {
            final orig = slotRemap[a.svt] ?? a.svt;
            active.add(orig);
            attackers.add(orig);
          }
        }
      }
    }

    return (activeSlots: active, attackerSlots: attackers);
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

    // Only servants who actually participate in combat, with role label.
    // Borrowed friend supports get [FRIEND] instead of [ATK]/[SUP].
    final svtNames = active.map((i) {
      final name = _svtName(slots.getOrNull(i)?.svtId);
      final isFriend = slots.getOrNull(i)?.supportType == SupportSvtType.friend;
      final role = isFriend
          ? ' [FRIEND]'
          : attackerSlots.contains(i) ? ' [ATK]' : ' [SUP]';
      return name + role;
    }).toList();

    // CEs for NP-firing (attacker) slots only, paired with servant names
    final ceParts = (attackerSlots.toList()..sort()).map((idx) {
      final svtName = _svtName(slots.getOrNull(idx)?.svtId);
      final ceName = _ceName(slots.getOrNull(idx)?.equip1.id);
      return '$svtName: $ceName';
    }).toList();

    // Mystic Code name (null if no MC used)
    final mcId = group.records.first.battleData.formation.mysticCode.mysticCodeId;
    final mcName = (mcId != null && mcId != 0)
        ? (db.gameData.mysticCodes[mcId]?.lName.l ?? 'MC $mcId')
        : null;

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
          if (mcName != null)
            Text('MC: $mcName', style: textTheme.bodySmall),
          Text(variantText, style: textTheme.bodySmall),
        ],
      ),
      isThreeLine: ceParts.isNotEmpty || mcName != null,
      trailing: const Icon(Icons.chevron_right),
      onTap: () {
        final wavePattern = RunScope.of(context)
            .loadedPhase
            ?.stages
            .map((s) => s.enemies.length)
            .join(' / ');
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) =>
                ClearGroupDetailPage(group: group, wavePattern: wavePattern),
          ),
        );
      },
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

    // Progress fraction — only meaningful while running and after pruning completes.
    final total = run.candidatesPassed;
    final progress = (run.isRunning && total > 0)
        ? (run.candidatesProcessed / total).clamp(0.0, 1.0)
        : null;

    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (progress != null) ...[
            Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 4,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${(progress * 100).toStringAsFixed(0)}%'
                  ' (${run.candidatesProcessed}/$total)',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 4),
          ],
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
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
