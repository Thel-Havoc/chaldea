/// ClearGroupDetailPage — turn-by-turn breakdown for all specs in a group.
///
/// Pushed via [Navigator.push] from [ResultsScreen]. Each spec in the group
/// is shown as a collapsible card. Tapping a card expands the turn-by-turn
/// skill and NP sequence for that spec.
library;

import 'package:flutter/material.dart';

import 'package:chaldea/models/models.dart';
import 'package:chaldea/utils/extension.dart';

import '../../optimizer/roster/run_history.dart';
import 'results_screen.dart';

// ---------------------------------------------------------------------------
// ClearGroupDetailPage
// ---------------------------------------------------------------------------

class ClearGroupDetailPage extends StatefulWidget {
  final GroupedResult group;
  const ClearGroupDetailPage({super.key, required this.group});

  @override
  State<ClearGroupDetailPage> createState() => _ClearGroupDetailPageState();
}

class _ClearGroupDetailPageState extends State<ClearGroupDetailPage> {
  @override
  Widget build(BuildContext context) {
    final slots = widget.group.slots;

    // Title: on-field servant names (slots 0–2)
    final title = List.generate(3, (i) {
      final svtId = slots.getOrNull(i)?.svtId;
      if (svtId == null || svtId == 0) return null;
      return db.gameData.servantsById[svtId]?.lName.l ?? 'Svt $svtId';
    }).whereType<String>().join(' · ');

    // Sort within group: guaranteed first, then fewest presses, then turns
    final sorted = [...widget.group.records]..sort((a, b) {
        final gCmp =
            (b.clearsAtMinDamage ? 1 : 0) - (a.clearsAtMinDamage ? 1 : 0);
        if (gCmp != 0) return gCmp;
        final bCmp = a.buttonPresses.compareTo(b.buttonPresses);
        if (bCmp != 0) return bCmp;
        return a.totalTurns.compareTo(b.totalTurns);
      });

    return Scaffold(
      appBar: AppBar(title: Text(title.isEmpty ? 'Team Details' : title)),
      body: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: sorted.length,
        itemBuilder: (context, i) => _SpecCard(
          record: sorted[i],
          index: i + 1,
          total: sorted.length,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _SpecCard — one spec, expandable to show turn-by-turn actions
// ---------------------------------------------------------------------------

class _SpecCard extends StatefulWidget {
  final RunRecord record;
  final int index;
  final int total;

  const _SpecCard({
    required this.record,
    required this.index,
    required this.total,
  });

  @override
  State<_SpecCard> createState() => _SpecCardState();
}

class _SpecCardState extends State<_SpecCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.record;
    final textTheme = Theme.of(context).textTheme;

    final header = Row(
      children: [
        ReliabilityBadge(guaranteed: r.clearsAtMinDamage),
        const SizedBox(width: 8),
        if (widget.total > 1)
          Text('Spec ${widget.index}', style: textTheme.titleSmall),
        const Spacer(),
        Text(
          '${r.buttonPresses} presses · ${r.totalTurns} turns',
          style: textTheme.bodySmall,
        ),
        const SizedBox(width: 4),
        Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 20),
      ],
    );

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              header,
              if (_expanded) ...[
                const SizedBox(height: 8),
                const Divider(height: 1),
                const SizedBox(height: 8),
                ..._buildTurnRows(context, r),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildTurnRows(BuildContext context, RunRecord r) {
    final displays = _resolveTurnDisplays(r);
    final textStyle = Theme.of(context).textTheme.bodySmall;
    return displays
        .map((d) => _TurnRowWidget(display: d, textStyle: textStyle))
        .toList();
  }
}

// ---------------------------------------------------------------------------
// Turn display model — all strings pre-resolved before rendering
// ---------------------------------------------------------------------------

class _TurnDisplay {
  final int turnNum;
  final List<String> skills; // may include OC description
  final List<String> npFirers;
  _TurnDisplay({required this.turnNum, required this.skills, required this.npFirers});
}

/// Resolves all action descriptions for a [RunRecord] into [_TurnDisplay]s,
/// including Order Change descriptions with servant names.
///
/// After an Order Change fires, slot indices in the action log refer to the
/// *current* occupant of that field position, not the original one. We track
/// a [slotRemap] to translate "current field slot → initial formation slot"
/// so that post-OC skill attributions show the correct servant.
List<_TurnDisplay> _resolveTurnDisplays(RunRecord r) {
  final formation = r.battleData.formation;
  final delegate = r.battleData.delegate;
  final turns = _parseTurns(r.battleData.actions);

  // Tracks how many OC events we've resolved so far.
  int ocIdx = 0;

  // Maps field-slot-index → formation-svts-index after swaps.
  // Initially identity (each slot maps to itself).
  final slotRemap = <int, int>{};

  return turns.asMap().entries.map((entry) {
    final turnNum = entry.key + 1;
    final turn = entry.value;

    final skillDescs = <String>[];
    for (final action in turn.skills) {
      final svtIdx = action.svt;
      final skillIdx = action.skill ?? 0;

      // Detect Order Change: MC skill (svt == null), skill index 2 (S3),
      // with a delegate entry available for this OC occurrence.
      if (svtIdx == null &&
          skillIdx == 2 &&
          delegate != null &&
          ocIdx < delegate.replaceMemberIndexes.length) {
        final pair = delegate.replaceMemberIndexes[ocIdx++];
        final onFieldSlot = pair[0];
        // backlineSlot is 0-based within the backline; formation slot = 3 + backlineSlot
        final backlineFormationSlot = 3 + pair[1];

        final outName = _svtNameForSlot(formation, onFieldSlot, slotRemap);
        final inName = _svtNameForSlot(formation, backlineFormationSlot, slotRemap);
        skillDescs.add('MC S3: Order Change ($outName → $inName)');

        // Update remap: the two slots swap occupants.
        final prevField = slotRemap[onFieldSlot] ?? onFieldSlot;
        final prevBench = slotRemap[backlineFormationSlot] ?? backlineFormationSlot;
        slotRemap[onFieldSlot] = prevBench;
        slotRemap[backlineFormationSlot] = prevField;
      } else {
        skillDescs.add(_describeSkill(action, formation, slotRemap));
      }
    }

    final npFirers = turn.attack?.attacks
            ?.where((a) => a.isTD)
            .map((a) => _svtNameForSlot(formation, a.svt, slotRemap))
            .toList() ??
        [];

    return _TurnDisplay(turnNum: turnNum, skills: skillDescs, npFirers: npFirers);
  }).toList();
}

// ---------------------------------------------------------------------------
// _TurnRowWidget — renders a single _TurnDisplay
// ---------------------------------------------------------------------------

class _TurnRowWidget extends StatelessWidget {
  final _TurnDisplay display;
  final TextStyle? textStyle;

  const _TurnRowWidget({required this.display, this.textStyle});

  @override
  Widget build(BuildContext context) {
    final parts = [
      if (display.skills.isNotEmpty) display.skills.join(', '),
      if (display.npFirers.isNotEmpty) '→ NP: ${display.npFirers.join(', ')}',
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 52,
            child: Text(
              'Turn ${display.turnNum}',
              style: textStyle?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: Text(
              parts.isEmpty ? '(no actions)' : parts.join('  '),
              style: textStyle,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _svtNameForSlot(BattleTeamFormation formation, int slotIdx,
    [Map<int, int>? remap]) {
  final effectiveSlot = remap?[slotIdx] ?? slotIdx;
  final svtId = formation.svts.getOrNull(effectiveSlot)?.svtId;
  if (svtId == null || svtId == 0) return 'Slot $slotIdx';
  return db.gameData.servantsById[svtId]?.lName.l ?? 'Svt $svtId';
}

String _describeSkill(BattleRecordData action, BattleTeamFormation formation,
    [Map<int, int>? remap]) {
  final svtIdx = action.svt;
  final skillIdx = action.skill ?? 0;
  final label = 'S${skillIdx + 1}';

  // MC skill (svt == null)
  if (svtIdx == null) {
    final mcId = formation.mysticCode.mysticCodeId;
    final skillName = mcId != null
        ? db.gameData.mysticCodes[mcId]?.skills.getOrNull(skillIdx)?.dispName
        : null;
    return skillName != null ? 'MC $label: $skillName' : 'MC $label';
  }

  // Servant skill — apply remap so post-OC skills show the correct occupant
  final effectiveSlot = remap?[svtIdx] ?? svtIdx;
  final svtData = formation.svts.getOrNull(effectiveSlot);
  final svtId = svtData?.svtId;
  final svtDisplay = (svtId != null && svtId != 0)
      ? (db.gameData.servantsById[svtId]?.lName.l ?? 'Svt $svtId')
      : 'Slot $svtIdx';

  final skillId = svtData?.skillIds.getOrNull(skillIdx);
  final skillName =
      skillId != null ? db.gameData.baseSkills[skillId]?.dispName : null;

  return skillName != null ? '$svtDisplay $label: $skillName' : '$svtDisplay $label';
}

// ---------------------------------------------------------------------------
// Turn parsing — reconstruct per-turn structure from flat action log
//
// The log emitted by ShareDataConverter is: skills* attack? (repeated per turn).
// Each [attack] record marks the end of a turn.
// ---------------------------------------------------------------------------

class _ParsedTurn {
  final List<BattleRecordData> skills;
  final BattleRecordData? attack;
  _ParsedTurn({required this.skills, this.attack});
}

List<_ParsedTurn> _parseTurns(List<BattleRecordData> actions) {
  final turns = <_ParsedTurn>[];
  var pending = <BattleRecordData>[];
  for (final a in actions) {
    switch (a.type) {
      case BattleRecordDataType.skill:
        pending.add(a);
      case BattleRecordDataType.attack:
        turns.add(_ParsedTurn(skills: List.of(pending), attack: a));
        pending = [];
      case BattleRecordDataType.base:
        break;
    }
  }
  if (pending.isNotEmpty) {
    turns.add(_ParsedTurn(skills: pending));
  }
  return turns;
}
