/// ServantEditPage — edit (or add) a single servant's roster data.
///
/// Used for both adding a new servant and editing an existing one.
/// [initial] is null when adding fresh; non-null when editing.
library;

import 'package:flutter/material.dart';
import 'package:chaldea/models/models.dart';

import '../../optimizer/roster/user_roster.dart';
import 'roster_notifier.dart';
import 'widgets.dart';

class ServantEditPage extends StatefulWidget {
  final Servant svt;
  final OwnedServant? initial;
  final RosterNotifier notifier;

  const ServantEditPage({
    super.key,
    required this.svt,
    required this.initial,
    required this.notifier,
  });

  @override
  State<ServantEditPage> createState() => _ServantEditPageState();
}

class _ServantEditPageState extends State<ServantEditPage> {
  late final TextEditingController _level;
  late final TextEditingController _fouAtk;
  late final TextEditingController _fouHp;
  late final List<TextEditingController> _skills;
  late final List<TextEditingController> _appends;
  late int _npLevel;
  late int _limitCount;
  late Set<ServantRole> _roles;

  @override
  void initState() {
    super.initState();
    final s = widget.initial ?? OwnedServant(level: _defaultLevel(widget.svt.rarity));
    _level = TextEditingController(text: s.level.toString());
    _fouAtk = TextEditingController(text: s.fouAtk.toString());
    _fouHp = TextEditingController(text: s.fouHp.toString());
    _skills = s.skillLevels.map((v) => TextEditingController(text: v.toString())).toList();
    _appends = s.appendLevels.map((v) => TextEditingController(text: v.toString())).toList();
    _npLevel = s.npLevel;
    _limitCount = s.limitCount;
    if (widget.initial != null) {
      _roles = Set.of(widget.initial!.roles);
    } else {
      // Smart default: infer from NP type so most servants are pre-tagged correctly.
      final np = widget.svt.groupedNoblePhantasms[1]?.firstOrNull;
      if (np == null || np.damageType == TdEffectFlag.support) {
        _roles = {ServantRole.support};
      } else {
        _roles = {ServantRole.attacker};
      }
    }
  }

  @override
  void dispose() {
    _level.dispose();
    _fouAtk.dispose();
    _fouHp.dispose();
    for (final c in _skills) { c.dispose(); }
    for (final c in _appends) { c.dispose(); }
    super.dispose();
  }

  static int _defaultLevel(int rarity) {
    if (rarity >= 5) return 90;
    if (rarity == 4) return 80;
    if (rarity == 3) return 70;
    if (rarity == 2) return 65;
    return 60; // 0-1 star
  }

  void _save() {
    final data = OwnedServant(
      level: int.tryParse(_level.text) ?? 90,
      npLevel: _npLevel,
      limitCount: _limitCount,
      skillLevels: _skills.map((c) => int.tryParse(c.text) ?? 1).toList(),
      appendLevels: _appends.map((c) => int.tryParse(c.text) ?? 0).toList(),
      fouAtk: int.tryParse(_fouAtk.text) ?? 1000,
      fouHp: int.tryParse(_fouHp.text) ?? 1000,
      roles: Set.of(_roles),
    );
    widget.notifier.upsertServant(widget.svt.id, data);
    Navigator.pop(context);
  }

  void _delete() {
    widget.notifier.removeServant(widget.svt.id);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final svt = widget.svt;
    final isNew = widget.initial == null;

    return Scaffold(
      appBar: AppBar(
        title: Text(svt.lName.l),
        actions: [
          if (!isNew)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Remove from roster',
              onPressed: () => _confirmDelete(context),
            ),
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: 'Save',
            onPressed: _save,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header info (read-only)
            Text(
              '${_clsName(svt.className)}  ·  ${'★' * svt.rarity}  ·  No. ${svt.collectionNo}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),

            // Level + Ascension row
            Row(children: [
              Expanded(child: IntField(_level, 'Level', min: 1, max: 120)),
              const SizedBox(width: 12),
              Expanded(child: _ascensionSelector()),
            ]),
            const SizedBox(height: 12),

            // NP Level
            _npSelector(),
            const SizedBox(height: 16),

            // Role tags
            _roleSelector(),
            const SizedBox(height: 16),

            // Skill Levels
            _label('Skill Levels'),
            Row(children: [
              for (int i = 0; i < 3; i++) ...[
                Expanded(child: IntField(_skills[i], 'S${i + 1}', min: 1, max: 10)),
                if (i < 2) const SizedBox(width: 8),
              ],
            ]),
            const SizedBox(height: 12),

            // Append Skill Levels
            _label('Append Skills'),
            Row(children: [
              for (int i = 0; i < 3; i++) ...[
                Expanded(child: IntField(_appends[i], 'A${i + 1}', min: 0, max: 10)),
                if (i < 2) const SizedBox(width: 8),
              ],
            ]),
            const SizedBox(height: 12),

            // Fous
            _label('Fou Boosts'),
            Row(children: [
              Expanded(child: IntField(_fouAtk, 'Fou ATK', min: 0, max: 2000)),
              const SizedBox(width: 12),
              Expanded(child: IntField(_fouHp, 'Fou HP', min: 0, max: 2000)),
            ]),
            const SizedBox(height: 32),

            // Save button
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _save,
                child: Text(isNew ? 'Add to Roster' : 'Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: Theme.of(context).textTheme.labelLarge),
      );

  Widget _npSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('NP Level'),
        SegmentedButton<int>(
          segments: [
            for (int i = 1; i <= 5; i++)
              ButtonSegment(value: i, label: Text('NP$i')),
          ],
          selected: {_npLevel},
          onSelectionChanged: (s) => setState(() => _npLevel = s.first),
        ),
      ],
    );
  }

  Widget _roleSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('Role'),
        Wrap(
          spacing: 8,
          children: [
            for (final role in ServantRole.values)
              FilterChip(
                label: Text(role == ServantRole.attacker ? 'Attacker' : 'Support'),
                selected: _roles.contains(role),
                onSelected: (selected) {
                  setState(() {
                    if (selected) {
                      _roles.add(role);
                    } else if (_roles.length > 1) {
                      // Require at least one role to be selected.
                      _roles.remove(role);
                    }
                  });
                },
              ),
          ],
        ),
      ],
    );
  }

  Widget _ascensionSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('Ascension'),
        SegmentedButton<int>(
          segments: [
            for (int i = 0; i <= 4; i++)
              ButtonSegment(value: i, label: Text('$i')),
          ],
          selected: {_limitCount},
          onSelectionChanged: (s) => setState(() => _limitCount = s.first),
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
          ),
        ),
      ],
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove servant?'),
        content: Text('Remove ${widget.svt.lName.l} from your roster?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed == true) _delete();
  }
}

String _clsName(SvtClass cls) {
  final n = cls.name;
  return n[0].toUpperCase() + n.substring(1);
}
