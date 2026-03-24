/// McListPage — lists all Mystic Codes from game data.
///
/// The player checks off which ones they own and sets the level (1-10).
/// Only owned MCs are stored in the roster; unchecked = not stored.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chaldea/models/models.dart';

import 'roster_notifier.dart';

class McListPage extends StatelessWidget {
  const McListPage({super.key});

  @override
  Widget build(BuildContext context) {
    final notifier = RosterScope.of(context);
    final allMcs = db.gameData.mysticCodes.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));

    return ListView.builder(
      itemCount: allMcs.length,
      itemBuilder: (context, i) => _McTile(mc: allMcs[i], notifier: notifier),
    );
  }
}

class _McTile extends StatefulWidget {
  final MysticCode mc;
  final RosterNotifier notifier;

  const _McTile({required this.mc, required this.notifier});

  @override
  State<_McTile> createState() => _McTileState();
}

class _McTileState extends State<_McTile> {
  late final TextEditingController _level;

  @override
  void initState() {
    super.initState();
    final existing = widget.notifier.roster.mysticCodes[widget.mc.id];
    _level = TextEditingController(text: (existing ?? 10).toString());
  }

  @override
  void dispose() {
    _level.dispose();
    super.dispose();
  }

  bool get _owned => widget.notifier.roster.mysticCodes.containsKey(widget.mc.id);

  void _toggle(bool value) {
    if (value) {
      final lv = int.tryParse(_level.text) ?? 10;
      widget.notifier.setMysticCode(widget.mc.id, lv.clamp(1, 10));
    } else {
      widget.notifier.removeMysticCode(widget.mc.id);
    }
  }

  void _onLevelChanged(String text) {
    if (!_owned) return;
    final lv = int.tryParse(text);
    if (lv != null && lv >= 1 && lv <= 10) {
      widget.notifier.setMysticCode(widget.mc.id, lv);
    }
  }

  @override
  Widget build(BuildContext context) {
    final owned = _owned;

    return ListenableBuilder(
      listenable: widget.notifier,
      builder: (context, _) {
        return ListTile(
          leading: Checkbox(
            value: owned,
            onChanged: (v) => _toggle(v ?? false),
          ),
          title: Text(widget.mc.lName.l),
          trailing: owned
              ? SizedBox(
                  width: 64,
                  child: TextField(
                    controller: _level,
                    decoration: const InputDecoration(
                      labelText: 'Lv',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: _onLevelChanged,
                  ),
                )
              : null,
        );
      },
    );
  }
}
