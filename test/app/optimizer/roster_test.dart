import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:chaldea/app/optimizer/roster/roster_store.dart';
import 'package:chaldea/app/optimizer/roster/user_roster.dart';
import '../../test_init.dart';

void main() async {
  await initiateForTest(loadData: false); // don't need game data for roster tests

  late Directory tempDir;
  late RosterStore store;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('roster_test_');
    store = RosterStore(tempDir.path);
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  // -------------------------------------------------------------------------
  group('UserRoster JSON round-trip', () {
    test('empty roster survives round-trip', () {
      final r = UserRoster(profileName: 'test');
      final r2 = UserRoster.fromJsonString(r.toJsonString());
      expect(r2.profileName, equals('test'));
      expect(r2.servants, isEmpty);
      expect(r2.craftEssences, isEmpty);
      expect(r2.mysticCodes, isEmpty);
      expect(r2.schemaVersion, equals(kRosterSchemaVersion));
    });

    test('servant data survives round-trip', () {
      final r = UserRoster(profileName: 'p')
        ..addServant(2500400,
            data: OwnedServant(
              level: 120,
              npLevel: 5,
              skillLevels: [10, 10, 10],
              appendLevels: [0, 10, 0],
              fouAtk: 2000,
              fouHp: 2000,
              limitCount: 2, // non-default ascension to verify it persists
            ));
      final r2 = UserRoster.fromJsonString(r.toJsonString());
      final svt = r2.servants[2500400]!;
      expect(svt.level, equals(120));
      expect(svt.npLevel, equals(5));
      expect(svt.skillLevels, equals([10, 10, 10]));
      expect(svt.appendLevels, equals([0, 10, 0]));
      expect(svt.fouAtk, equals(2000));
      expect(svt.fouHp, equals(2000));
      expect(svt.limitCount, equals(2));
    });

    test('limitCount defaults to 4 when absent', () {
      // Build manually without limitCount field to simulate old file
      final r = UserRoster.fromJson(<String, dynamic>{
        'schemaVersion': 1,
        'profileName': 'p',
        'servants': <String, dynamic>{
          '2500400': <String, dynamic>{
            'level': 90,
            'npLevel': 1,
            'skillLevels': [10, 10, 10],
            'appendLevels': [0, 0, 0],
            'fouAtk': 1000,
            'fouHp': 1000,
            // no limitCount key — old file
          },
        },
        'craftEssences': <String, dynamic>{},
        'mysticCodes': <String, dynamic>{},
      });
      expect(r.servants[2500400]!.limitCount, equals(4));
    });

    test('CE data survives round-trip', () {
      final r = UserRoster(profileName: 'p')
        ..addCE(9400340,
            data: OwnedCE(level: 100, mlb: true, copies: 2));
      final r2 = UserRoster.fromJsonString(r.toJsonString());
      final ce = r2.craftEssences[9400340]!;
      expect(ce.level, equals(100));
      expect(ce.mlb, isTrue);
      expect(ce.copies, equals(2));
    });

    test('mystic codes survive round-trip', () {
      final r = UserRoster(profileName: 'p')
        ..mysticCodes[210] = 10; // Chaldea Combat Uniform at level 10
      final r2 = UserRoster.fromJsonString(r.toJsonString());
      expect(r2.mysticCodes[210], equals(10));
    });
  });

  // -------------------------------------------------------------------------
  group('Schema forward-compatibility', () {
    test('missing fields in old JSON get safe defaults', () {
      // Simulate an "old" file that predates fouAtk/fouHp fields
      const oldJson = '''
      {
        "schemaVersion": 1,
        "profileName": "olduser",
        "servants": {
          "100100": {
            "level": 90,
            "npLevel": 1,
            "skillLevels": [10, 10, 10],
            "appendLevels": [0, 0, 0]
          }
        },
        "craftEssences": {},
        "mysticCodes": {}
      }
      ''';
      final r = UserRoster.fromJsonString(oldJson);
      final svt = r.servants[100100]!;
      expect(svt.level, equals(90));
      expect(svt.fouAtk, equals(1000)); // default, not error
      expect(svt.fouHp, equals(1000)); // default, not error
    });

    test('unknown future fields are silently ignored', () {
      // Simulate a file from a future version that has extra fields
      const futureJson = '''
      {
        "schemaVersion": 99,
        "profileName": "future",
        "servants": {
          "100100": {
            "level": 90,
            "npLevel": 1,
            "skillLevels": [10, 10, 10],
            "appendLevels": [0, 0, 0],
            "fouAtk": 1000,
            "fouHp": 1000,
            "newFieldAddedInV99": true
          }
        },
        "craftEssences": {},
        "mysticCodes": {},
        "someNewTopLevelField": "ignored"
      }
      ''';
      // Should load without throwing
      final r = UserRoster.fromJsonString(futureJson);
      expect(r.profileName, equals('future'));
      expect(r.servants[100100]!.level, equals(90));
    });
  });

  // -------------------------------------------------------------------------
  group('RosterStore profile lifecycle', () {
    test('create and list profiles', () {
      expect(store.listProfiles(), isEmpty);
      store.createProfile('matt');
      store.createProfile('wife');
      expect(store.listProfiles(), containsAll(['matt', 'wife']));
    });

    test('load returns null for missing profile', () {
      expect(store.loadProfile('nobody'), isNull);
    });

    test('save and load round-trip', () {
      final r = UserRoster(profileName: 'matt')
        ..addServant(2500400,
            data: OwnedServant(level: 90, npLevel: 5, skillLevels: [10, 10, 10]));
      store.saveProfile(r);

      final loaded = store.loadProfile('matt')!;
      expect(loaded.servants[2500400]!.npLevel, equals(5));
    });

    test('delete removes profile', () {
      store.createProfile('temp');
      expect(store.listProfiles(), contains('temp'));
      store.deleteProfile('temp');
      expect(store.listProfiles(), isNot(contains('temp')));
    });

    test('rename moves file and updates profileName field', () {
      final r = store.createProfile('oldname');
      final renamed = store.renameProfile(r, 'newname');
      expect(renamed.profileName, equals('newname'));
      expect(store.listProfiles(), contains('newname'));
      expect(store.listProfiles(), isNot(contains('oldname')));
    });

    test('duplicate name on create throws', () {
      store.createProfile('duplicate');
      expect(() => store.createProfile('duplicate'), throwsArgumentError);
    });
  });

  // -------------------------------------------------------------------------
  group('RosterStore export / import', () {
    test('export then import produces identical data', () {
      final r = UserRoster(profileName: 'exporttest')
        ..addServant(100100, data: OwnedServant(level: 90, npLevel: 1))
        ..addCE(9400340, data: OwnedCE(level: 100, mlb: true, copies: 1));
      store.saveProfile(r);

      final exportPath = p.join(tempDir.path, 'exported.json');
      store.exportProfile(r, exportPath);

      // Import into a second store (simulates wife's machine)
      final store2 = RosterStore(p.join(tempDir.path, 'other_machine'));
      final imported = store2.importProfile(exportPath)!;

      expect(imported.profileName, equals('exporttest'));
      expect(imported.servants[100100]!.level, equals(90));
      expect(imported.craftEssences[9400340]!.mlb, isTrue);
    });

    test('import with name collision appends _imported suffix', () {
      store.createProfile('collision');

      // Build a file that would collide
      final collidingRoster = UserRoster(profileName: 'collision');
      final exportPath = p.join(tempDir.path, 'collision_export.json');
      store.exportProfile(collidingRoster, exportPath);

      final imported = store.importProfile(exportPath)!;
      expect(imported.profileName, equals('collision_imported'));
      expect(store.listProfiles(), containsAll(['collision', 'collision_imported']));
    });
  });
}
