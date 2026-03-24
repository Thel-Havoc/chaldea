/// CeListPage — shows owned Craft Essences with an Add button.
library;

import 'package:flutter/material.dart';

import 'package:chaldea/models/models.dart';

import '../../optimizer/roster/user_roster.dart';
import 'ce_edit_page.dart';
import 'ce_picker_page.dart';
import 'roster_notifier.dart';

class CeListPage extends StatelessWidget {
  const CeListPage({super.key});

  @override
  Widget build(BuildContext context) {
    final notifier = RosterScope.of(context);
    final ces = notifier.roster.craftEssences;

    return Scaffold(
      body: ces.isEmpty
          ? const Center(
              child: Text('No CEs added yet.\nTap + to add one.', textAlign: TextAlign.center))
          : ListView(
              children: [
                for (final entry in ces.entries)
                  _CeTile(ceId: entry.key, owned: entry.value),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add CE',
        onPressed: () => _pickAndAdd(context, notifier),
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _pickAndAdd(BuildContext context, RosterNotifier notifier) async {
    final picked = await Navigator.push<CraftEssence>(
      context,
      MaterialPageRoute(builder: (_) => const CePickerPage()),
    );
    if (picked == null || !context.mounted) return;

    final existing = notifier.roster.craftEssences[picked.id];
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CeEditPage(ce: picked, initial: existing, notifier: notifier),
      ),
    );
  }
}

class _CeTile extends StatelessWidget {
  final int ceId;
  final OwnedCE owned;

  const _CeTile({required this.ceId, required this.owned});

  @override
  Widget build(BuildContext context) {
    final ce = db.gameData.craftEssencesById[ceId];
    final name = ce?.lName.l ?? 'Unknown ($ceId)';
    final rarity = ce?.rarity ?? 0;
    final notifier = RosterScope.of(context);

    return ListTile(
      title: Text(name),
      subtitle: Text(
        'Lv ${owned.level}  ·  ${owned.mlb ? "MLB" : "not MLB"}  ·  ×${owned.copies}',
      ),
      trailing: Text(
        '★' * rarity,
        style: const TextStyle(color: Colors.amber),
      ),
      onTap: () {
        if (ce == null) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CeEditPage(ce: ce, initial: owned, notifier: notifier),
          ),
        );
      },
    );
  }
}
