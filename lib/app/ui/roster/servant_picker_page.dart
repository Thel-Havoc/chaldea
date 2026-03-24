/// ServantPickerPage — scrollable list of all playable servants with
/// class and rarity filters. Returns the selected [Servant] on pop.
library;

import 'package:flutter/material.dart';

import 'package:chaldea/models/models.dart';

/// Servant classes shown as filter chips (playable classes only).
const _filterClasses = [
  SvtClass.saber,
  SvtClass.archer,
  SvtClass.lancer,
  SvtClass.rider,
  SvtClass.caster,
  SvtClass.assassin,
  SvtClass.berserker,
  SvtClass.ruler,
  SvtClass.alterego,
  SvtClass.avenger,
  SvtClass.moonCancer,
  SvtClass.foreigner,
  SvtClass.pretender,
  SvtClass.shielder,
];

class ServantPickerPage extends StatefulWidget {
  const ServantPickerPage({super.key});

  @override
  State<ServantPickerPage> createState() => _ServantPickerPageState();
}

class _ServantPickerPageState extends State<ServantPickerPage> {
  SvtClass? _classFilter;
  int? _rarityFilter; // null = all

  List<Servant> get _filtered {
    final naIds = db.gameData.mappingData.entityRelease.ofRegion(Region.na) ?? [];
    return db.gameData.servantsNoDup.values
        .where((s) => s.collectionNo > 0 && naIds.contains(s.id))
        .where((s) => _classFilter == null || s.className == _classFilter)
        .where((s) => _rarityFilter == null || s.rarity == _rarityFilter)
        .toList()
      ..sort((a, b) => b.collectionNo.compareTo(a.collectionNo));
  }

  @override
  Widget build(BuildContext context) {
    final servants = _filtered;

    return Scaffold(
      appBar: AppBar(title: const Text('Select Servant')),
      body: Column(
        children: [
          _ClassFilterBar(
            selected: _classFilter,
            onSelected: (c) => setState(() => _classFilter = _classFilter == c ? null : c),
          ),
          _RarityFilterBar(
            selected: _rarityFilter,
            onSelected: (r) => setState(() => _rarityFilter = _rarityFilter == r ? null : r),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: servants.length,
              itemBuilder: (context, i) {
                final svt = servants[i];
                return ListTile(
                  dense: true,
                  leading: Text(
                    '#${svt.collectionNo}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  title: Text(svt.lName.l),
                  subtitle: Text(_className(svt.className)),
                  trailing: Text(
                    '★' * svt.rarity,
                    style: const TextStyle(color: Colors.amber, fontSize: 12),
                  ),
                  onTap: () => Navigator.pop(context, svt),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

String _className(SvtClass cls) {
  final n = cls.name;
  return n[0].toUpperCase() + n.substring(1);
}

// ---------------------------------------------------------------------------

class _ClassFilterBar extends StatelessWidget {
  final SvtClass? selected;
  final void Function(SvtClass) onSelected;

  const _ClassFilterBar({required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: _filterClasses.map((cls) {
          return Padding(
            padding: const EdgeInsets.only(right: 4),
            child: FilterChip(
              label: Text(_className(cls), style: const TextStyle(fontSize: 12)),
              selected: selected == cls,
              onSelected: (_) => onSelected(cls),
              visualDensity: VisualDensity.compact,
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _RarityFilterBar extends StatelessWidget {
  final int? selected;
  final void Function(int) onSelected;

  const _RarityFilterBar({required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [5, 4, 3, 2, 1].map((r) {
          return Padding(
            padding: const EdgeInsets.only(right: 4),
            child: FilterChip(
              label: Text('★' * r, style: const TextStyle(color: Colors.amber, fontSize: 12)),
              selected: selected == r,
              onSelected: (_) => onSelected(r),
              visualDensity: VisualDensity.compact,
            ),
          );
        }).toList(),
      ),
    );
  }
}
