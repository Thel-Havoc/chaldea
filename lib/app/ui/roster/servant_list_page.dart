/// ServantListPage — shows owned servants with an Add button.
library;

import 'package:flutter/material.dart';

import 'package:chaldea/models/models.dart';

import '../../optimizer/roster/user_roster.dart';
import 'roster_notifier.dart';
import 'servant_edit_page.dart';
import 'servant_picker_page.dart';

class ServantListPage extends StatelessWidget {
  const ServantListPage({super.key});

  @override
  Widget build(BuildContext context) {
    final notifier = RosterScope.of(context);
    final servants = notifier.roster.servants;

    return Scaffold(
      body: servants.isEmpty
          ? const Center(child: Text('No servants added yet.\nTap + to add one.', textAlign: TextAlign.center))
          : ListView(
              children: [
                for (final entry in servants.entries)
                  _ServantTile(svtId: entry.key, owned: entry.value),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add servant',
        onPressed: () => _pickAndAdd(context, notifier),
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _pickAndAdd(BuildContext context, RosterNotifier notifier) async {
    final picked = await Navigator.push<Servant>(
      context,
      MaterialPageRoute(builder: (_) => const ServantPickerPage()),
    );
    if (picked == null || !context.mounted) return;

    // If already owned, go straight to edit; otherwise open edit with defaults.
    final existing = notifier.roster.servants[picked.id];
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ServantEditPage(
          svt: picked,
          initial: existing,
          notifier: notifier,
        ),
      ),
    );
  }
}

class _ServantTile extends StatelessWidget {
  final int svtId;
  final OwnedServant owned;

  const _ServantTile({required this.svtId, required this.owned});

  @override
  Widget build(BuildContext context) {
    final svt = db.gameData.servantsById[svtId];
    final name = svt?.lName.l ?? 'Unknown ($svtId)';
    final cls = svt?.className.name ?? '';
    final rarity = svt?.rarity ?? 0;
    final notifier = RosterScope.of(context);

    return ListTile(
      title: Text(name),
      subtitle: Text(
        '${cls[0].toUpperCase()}${cls.substring(1)}  ·  '
        'Lv ${owned.level}  ·  NP${owned.npLevel}  ·  '
        '${owned.skillLevels.join('/')}',
      ),
      trailing: Text('★' * rarity, style: const TextStyle(color: Colors.amber)),
      onTap: () {
        if (svt == null) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ServantEditPage(
              svt: svt,
              initial: owned,
              notifier: notifier,
            ),
          ),
        );
      },
    );
  }
}
