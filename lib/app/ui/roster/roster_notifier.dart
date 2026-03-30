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

  /// All saved profile names, sorted alphabetically.
  List<String> get profiles => _store.listProfiles();

  /// Name of the currently active profile.
  String get activeProfileName => _roster.profileName;

  // -------------------------------------------------------------------------
  // Profile management
  // -------------------------------------------------------------------------

  /// Loads and activates a different profile. No-op if already active.
  void switchProfile(String name) {
    if (name == _roster.profileName) return;
    _roster = _store.loadProfile(name) ?? _roster;
    notifyListeners();
  }

  /// Creates a new empty profile, switches to it, and saves it.
  /// Throws [ArgumentError] if a profile with that name already exists.
  void createNewProfile(String name) {
    _roster = _store.createProfile(name);
    notifyListeners();
  }

  /// Renames the active profile.
  /// Throws [ArgumentError] if a profile with [newName] already exists.
  void renameCurrentProfile(String newName) {
    _roster = _store.renameProfile(_roster, newName);
    notifyListeners();
  }

  /// Deletes the active profile and switches to the next available one.
  /// If this is the only profile, recreates an empty 'default' profile.
  void deleteCurrentProfile() {
    final toDelete = _roster.profileName;
    final remaining = _store.listProfiles()..remove(toDelete);
    _store.deleteProfile(toDelete);
    if (remaining.isEmpty) {
      _roster = _store.createProfile(_defaultProfile);
    } else {
      _roster = _store.loadProfile(remaining.first) ??
          UserRoster(profileName: remaining.first);
    }
    notifyListeners();
  }

  /// Writes the active profile as JSON to [targetPath].
  void exportCurrentProfile(String targetPath) {
    _store.exportProfile(_roster, targetPath);
  }

  /// Saves [imported] into the profiles directory (overwriting if the file
  /// already exists) and switches to it. Use this after the UI has resolved
  /// any name collision (overwrite or rename).
  void saveImported(UserRoster imported) {
    _store.saveProfile(imported);
    _roster = imported;
    notifyListeners();
  }

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
