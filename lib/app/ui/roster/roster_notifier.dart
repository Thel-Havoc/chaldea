/// RosterNotifier — ChangeNotifier wrapping UserRoster + RosterStore.
///
/// Single source of truth for the player's owned servants/CEs/MCs.
/// Auto-saves to disk after every mutation.
///
/// Exposed to the widget tree via [RosterScope].
library;

import 'package:flutter/widgets.dart';

import '../../optimizer/roster/roster_store.dart';
import '../../optimizer/roster/user_roster.dart';

class RosterNotifier extends ChangeNotifier {
  static const _defaultProfile = 'default';

  final RosterStore _store;
  late UserRoster _roster;

  RosterNotifier(String appPath) : _store = RosterStore(appPath) {
    _roster = _store.loadProfile(_defaultProfile) ?? _store.createProfile(_defaultProfile);
  }

  UserRoster get roster => _roster;

  // -------------------------------------------------------------------------
  // Servants
  // -------------------------------------------------------------------------

  void upsertServant(int svtId, OwnedServant data) {
    _roster.servants[svtId] = data;
    _save();
  }

  void removeServant(int svtId) {
    _roster.removeServant(svtId);
    _save();
  }

  // -------------------------------------------------------------------------
  // Craft Essences
  // -------------------------------------------------------------------------

  void upsertCE(int ceId, OwnedCE data) {
    _roster.craftEssences[ceId] = data;
    _save();
  }

  void removeCE(int ceId) {
    _roster.removeCE(ceId);
    _save();
  }

  // -------------------------------------------------------------------------
  // Mystic Codes
  // -------------------------------------------------------------------------

  void setMysticCode(int mcId, int level) {
    _roster.mysticCodes[mcId] = level;
    _save();
  }

  void removeMysticCode(int mcId) {
    _roster.mysticCodes.remove(mcId);
    _save();
  }

  // -------------------------------------------------------------------------

  void _save() {
    _store.saveProfile(_roster);
    notifyListeners();
  }
}

// ---------------------------------------------------------------------------
// InheritedNotifier — makes RosterNotifier available in the widget tree
// ---------------------------------------------------------------------------

class RosterScope extends InheritedNotifier<RosterNotifier> {
  const RosterScope({
    super.key,
    required super.notifier,
    required super.child,
  });

  static RosterNotifier of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<RosterScope>();
    assert(scope != null, 'RosterScope not found in widget tree');
    return scope!.notifier!;
  }
}
