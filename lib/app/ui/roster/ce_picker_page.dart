/// CePickerPage — scrollable list of all collectible CEs with rarity filter.
/// Returns the selected [CraftEssence] on pop.
library;

import 'package:flutter/material.dart';

import 'package:chaldea/models/models.dart';

class CePickerPage extends StatefulWidget {
  const CePickerPage({super.key});

  @override
  State<CePickerPage> createState() => _CePickerPageState();
}

class _CePickerPageState extends State<CePickerPage> {
  int? _rarityFilter;
  String _search = '';
  late final TextEditingController _searchCtrl;

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<CraftEssence> get _filtered {
    final naIds = db.gameData.mappingData.entityRelease.ofRegion(Region.na) ?? [];
    final q = _search.toLowerCase();
    return db.gameData.craftEssencesById.values
        .where((ce) => ce.collectionNo > 0 && naIds.contains(ce.id))
        .where((ce) => _rarityFilter == null || ce.rarity == _rarityFilter)
        .where((ce) => q.isEmpty || ce.lName.l.toLowerCase().contains(q))
        .toList()
      ..sort((a, b) => a.collectionNo.compareTo(b.collectionNo));
  }

  @override
  Widget build(BuildContext context) {
    final ces = _filtered;

    return Scaffold(
      appBar: AppBar(title: const Text('Select Craft Essence')),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: TextField(
              controller: _searchCtrl,
              decoration: const InputDecoration(
                hintText: 'Search by name...',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
          // Rarity filter
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [5, 4, 3, 2, 1].map((r) {
                return Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: FilterChip(
                    label: Text(
                      '★' * r,
                      style: const TextStyle(color: Colors.amber, fontSize: 12),
                    ),
                    selected: _rarityFilter == r,
                    onSelected: (_) =>
                        setState(() => _rarityFilter = _rarityFilter == r ? null : r),
                    visualDensity: VisualDensity.compact,
                  ),
                );
              }).toList(),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: ces.length,
              itemBuilder: (context, i) {
                final ce = ces[i];
                return ListTile(
                  dense: true,
                  leading: Text(
                    '#${ce.collectionNo}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  title: Text(ce.lName.l),
                  trailing: Text(
                    '★' * ce.rarity,
                    style: const TextStyle(color: Colors.amber, fontSize: 12),
                  ),
                  onTap: () => Navigator.pop(context, ce),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
