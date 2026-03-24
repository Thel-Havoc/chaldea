/// RosterStore — manages loading, saving, and profile lifecycle for UserRoster.
///
/// Profiles are stored as individual JSON files:
///   {db.paths.appPath}/optimizer_profiles/{profileName}.json
///
/// In debug builds this is inside AppData\Roaming\cc.narumi\Chaldea\.
/// In release builds it sits next to the executable in userdata\.
/// Either way the app always knows where it is; the user never needs to.
library;

import 'dart:io';

import 'package:path/path.dart';

import 'package:chaldea/packages/logger.dart';

import 'user_roster.dart';

class RosterStore {
  final String _dir;

  RosterStore(String appPath) : _dir = join(appPath, 'optimizer_profiles');

  // -------------------------------------------------------------------------
  // Internal
  // -------------------------------------------------------------------------

  void _ensureDir() => Directory(_dir).createSync(recursive: true);

  String _path(String profileName) => join(_dir, '$profileName.json');

  // -------------------------------------------------------------------------
  // Read
  // -------------------------------------------------------------------------

  /// Returns profile names (no extension) sorted alphabetically.
  List<String> listProfiles() {
    _ensureDir();
    return Directory(_dir)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .map((f) => basenameWithoutExtension(f.path))
        .toList()
      ..sort();
  }

  /// Loads a profile by name. Returns null if the file doesn't exist or is
  /// unreadable. Logs the error but does NOT throw — a bad profile file should
  /// never crash the app.
  UserRoster? loadProfile(String name) {
    final file = File(_path(name));
    if (!file.existsSync()) return null;
    try {
      return UserRoster.fromJsonString(file.readAsStringSync());
    } catch (e, st) {
      logger.e('RosterStore: failed to load profile "$name"', e, st);
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // Write
  // -------------------------------------------------------------------------

  /// Persists a roster. The file name is derived from roster.profileName.
  void saveProfile(UserRoster roster) {
    _ensureDir();
    File(_path(roster.profileName)).writeAsStringSync(roster.toJsonString());
  }

  /// Creates a new empty profile with the given name, saves it, and returns it.
  /// Throws [ArgumentError] if a profile with that name already exists.
  UserRoster createProfile(String name) {
    if (File(_path(name)).existsSync()) {
      throw ArgumentError('A profile named "$name" already exists.');
    }
    final roster = UserRoster(profileName: name);
    saveProfile(roster);
    return roster;
  }

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  void deleteProfile(String name) {
    final file = File(_path(name));
    if (file.existsSync()) file.deleteSync();
  }

  /// Renames a profile: saves under the new name and deletes the old file.
  UserRoster renameProfile(UserRoster roster, String newName) {
    if (newName == roster.profileName) return roster;
    if (File(_path(newName)).existsSync()) {
      throw ArgumentError('A profile named "$newName" already exists.');
    }
    deleteProfile(roster.profileName);
    final renamed = roster.copyWith(profileName: newName);
    saveProfile(renamed);
    return renamed;
  }

  // -------------------------------------------------------------------------
  // Export / Import
  // -------------------------------------------------------------------------

  /// Writes the roster as JSON to [targetPath] (any path the user chooses,
  /// e.g. from a save-file dialog). The file is human-readable and can be
  /// sent over Discord, copied to a USB drive, etc.
  void exportProfile(UserRoster roster, String targetPath) {
    File(targetPath).writeAsStringSync(roster.toJsonString());
  }

  /// Reads a roster JSON from [sourcePath] (e.g. from an open-file dialog),
  /// saves it into the profiles directory, and returns it.
  ///
  /// If the imported profile name collides with an existing profile, appends
  /// "_imported" to the name before saving.
  UserRoster? importProfile(String sourcePath) {
    try {
      final raw = File(sourcePath).readAsStringSync();
      var roster = UserRoster.fromJsonString(raw);

      // Resolve name collision
      if (File(_path(roster.profileName)).existsSync()) {
        roster = roster.copyWith(profileName: '${roster.profileName}_imported');
      }

      saveProfile(roster);
      return roster;
    } catch (e, st) {
      logger.e('RosterStore: failed to import from "$sourcePath"', e, st);
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // Bundled test profiles
  // -------------------------------------------------------------------------

  /// Saves a well-known small roster used during optimizer development and
  /// testing. Overwrites any existing profile with this name.
  ///
  /// [servants] is a map of {servantId: OwnedServant} with a handful of
  /// servants; [ces] similarly. Use this from test code to seed known-good
  /// teams without requiring a real user roster.
  UserRoster saveTestProfile({
    required String name,
    required Map<int, OwnedServant> servants,
    Map<int, OwnedCE>? ces,
    Map<int, int>? mysticCodes,
  }) {
    final roster = UserRoster(
      profileName: name,
      servants: servants,
      craftEssences: ces ?? {},
      mysticCodes: mysticCodes ?? {},
    );
    saveProfile(roster);
    return roster;
  }

  // -------------------------------------------------------------------------
  // Debug helpers
  // -------------------------------------------------------------------------

  /// Pretty-prints all profiles to stdout. Useful during development.
  void debugDump() {
    final profiles = listProfiles();
    if (profiles.isEmpty) {
      print('RosterStore[$_dir]: no profiles');
      return;
    }
    for (final name in profiles) {
      final r = loadProfile(name);
      print('Profile: $name  '
          '${r?.servants.length ?? "??"} servants  '
          '${r?.craftEssences.length ?? "??"} CEs  '
          '${r?.mysticCodes.length ?? "??"} MCs');
    }
  }
}
