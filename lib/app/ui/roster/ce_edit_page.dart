/// CeEditPage — edit (or add) a single Craft Essence.
library;

import 'package:flutter/material.dart';

import 'package:chaldea/models/models.dart';

import '../../optimizer/roster/user_roster.dart';
import 'roster_notifier.dart';
import 'widgets.dart';

class CeEditPage extends StatefulWidget {
  final CraftEssence ce;
  final OwnedCE? initial;
  final RosterNotifier notifier;

  const CeEditPage({
    super.key,
    required this.ce,
    required this.initial,
    required this.notifier,
  });

  @override
  State<CeEditPage> createState() => _CeEditPageState();
}

class _CeEditPageState extends State<CeEditPage> {
  late final TextEditingController _level;
  late final TextEditingController _copies;
  late bool _mlb;

  @override
  void initState() {
    super.initState();
    final c = widget.initial ?? OwnedCE();
    _level = TextEditingController(text: c.level.toString());
    _copies = TextEditingController(text: c.copies.toString());
    _mlb = c.mlb;
  }

  @override
  void dispose() {
    _level.dispose();
    _copies.dispose();
    super.dispose();
  }

  void _save() {
    widget.notifier.upsertCE(
      widget.ce.id,
      OwnedCE(
        level: int.tryParse(_level.text) ?? 1,
        mlb: _mlb,
        copies: int.tryParse(_copies.text) ?? 1,
      ),
    );
    Navigator.pop(context);
  }

  void _delete() {
    widget.notifier.removeCE(widget.ce.id);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final ce = widget.ce;
    final isNew = widget.initial == null;

    return Scaffold(
      appBar: AppBar(
        title: Text(ce.lName.l),
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
            Text(
              '${'★' * ce.rarity}  ·  No. ${ce.collectionNo}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),

            IntField(_level, 'Level', min: 1, max: 100),
            const SizedBox(height: 12),

            IntField(_copies, 'Copies owned', min: 1, max: 99),
            const SizedBox(height: 12),

            SwitchListTile(
              title: const Text('Max Limit Break (MLB)'),
              value: _mlb,
              onChanged: (v) {
                setState(() {
                  _mlb = v;
                  if (v) _level.text = '15';
                });
              },
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 32),

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

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove CE?'),
        content: Text('Remove ${widget.ce.lName.l} from your roster?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed == true) _delete();
  }
}
