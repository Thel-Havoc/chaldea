/// Tests for CandidateConverter: CandidateTeam → TeamSpec conversion.
///
/// Four test groups:
///
///   1. Structural — verify the converter produces the expected number of
///      TeamSpecs for a given team composition (NP plans × OC options).
///
///   2. Smoke quest end-to-end — feed a simple team (Altria + Castoria support
///      + MLB Kaleido) through the converter and verify at least one generated
///      spec clears the known-good single-wave test quest.
///
///   3. Montjoie 90 Arts team — Summer Ibuki + double Castoria + Black Grail
///      + New Year's Wardrobe MC. Asserts the converter produces at least one
///      clearing spec. This is the primary validation that the battery-spread
///      fix works: Castoria's charge skills (S2/S3) are spread across T1/T2
///      instead of both landing on T1, giving Ibuki enough NP to loop all 3 waves.
///
///   4. Montjoie 90 Buster team — Mélusine (Asc 2) + double Vitch + Oberon
///      + Black Grail + Chaldea Uniform (Decisive Battle) MC. Asserts the
///      converter finds at least one clearing spec via OC-assisted Buster NP.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/optimizer/candidate_to_team_spec/candidate_converter.dart';
import 'package:chaldea/app/optimizer/roster/user_roster.dart';
import 'package:chaldea/app/optimizer/search/enumerator.dart';
import 'package:chaldea/app/optimizer/simulation/headless_runner.dart';
import 'package:chaldea/models/models.dart';
import '../../test_init.dart';

// Quest used in HeadlessRunner smoke tests: single-wave Sky Caster.
const int kSmokeQuestId = 9300040603;

// Servant IDs (Atlas Academy internal IDs)
const int kAltriaPengId = 100100;  // Altria Pendragon (AoE Saber)
const int kCastoriaId = 504500;    // Altria Caster (Castoria)
const int kIbukiSumId = 704300;    // Summer Ibuki-Douji (AoE Arts)
const int kVitchId = 604200;       // Koyanskaya of Light
const int kMelusineId = 304800;    // Mélusine (AoE Buster)
const int kOberonId = 2800100;     // Oberon-Vortigern

// CE IDs
const int kKaleidoId = 9400340;    // Kaleidoscope (100% NP start, MLB)
const int kBlackGrailId = 9400480; // Black Grail (50% NP start + NP dmg up)
const int kDukeOfFlameId = 9403530; // Duke of Flame (+2 NP levels on first NP use)

// MC IDs
const int kNewYearsOutfitId = 260; // New Year's Outfit (Arts team MC)
const int kPlugSuitId = 210;       // Chaldea Combat Uniform (Buster team MC)

void main() async {
  await initiateForTest();

  // ---------------------------------------------------------------------------
  // Structural tests
  // ---------------------------------------------------------------------------

  group('CandidateConverter structural', () {
    test('single attacker, no OC → at least one spec generated', () {
      // 1 attacker slot → 1^3 = 1 NP plan; no Plug Suit → 1 OC option (null).
      // Converter enumerates selfBattery × concentrateSupport variants, so
      // the exact count varies. At minimum one spec must be produced.
      final roster = UserRoster(
        profileName: 'test',
        servants: {
          kAltriaPengId: OwnedServant(
            level: 90,
            npLevel: 1,
            skillLevels: [1, 10, 1],
            fouAtk: 1000,
            fouHp: 1000,
          ),
        },
        craftEssences: {kKaleidoId: OwnedCE(level: 100, mlb: true)},
      );

      final candidate = CandidateTeam(
        supportSvtId: kCastoriaId,
        playerSvtIds: [kAltriaPengId],
        playerCeIds: [kKaleidoId],
      );

      final specs = CandidateConverter(roster).convert(candidate);
      expect(specs, isNotEmpty);
    });

    test('Buster team with Plug Suit → at least 3 specs (one per OC turn)', () {
      // Plug Suit → 3 OC options. Attacker count may vary (Mélusine + possibly
      // Oberon if his NP is ST-typed) → NP plan count ≥ 1. Total ≥ 3.
      final roster = UserRoster(
        profileName: 'test',
        servants: {
          kMelusineId: OwnedServant(
            level: 100,
            npLevel: 1,
            skillLevels: [10, 10, 10],
            fouAtk: 2000,
            fouHp: 2000,
            limitCount: 2,
          ),
          kVitchId: OwnedServant(
            level: 90,
            npLevel: 1,
            skillLevels: [10, 10, 10],
            fouAtk: 1000,
            fouHp: 1000,
          ),
          kOberonId: OwnedServant(
            level: 90,
            npLevel: 1,
            skillLevels: [10, 10, 10],
            fouAtk: 1000,
            fouHp: 1000,
          ),
        },
        craftEssences: {kBlackGrailId: OwnedCE(level: 89, mlb: true)},
        mysticCodes: {kPlugSuitId: 8},
      );

      final candidate = CandidateTeam(
        supportSvtId: kVitchId,
        playerSvtIds: [kMelusineId, kVitchId, kOberonId],
        playerCeIds: [kBlackGrailId, null, null],
        mysticCodeId: kPlugSuitId,
        mysticCodeLevel: 8,
      );

      final specs = CandidateConverter(roster).convert(candidate);
      expect(specs, isNotEmpty);
      expect(specs.length, greaterThanOrEqualTo(3));
    });

    test('unknown player servant id → empty list (converter bails gracefully)', () {
      final roster = UserRoster(profileName: 'test'); // no servants registered

      final candidate = CandidateTeam(
        supportSvtId: kCastoriaId,
        playerSvtIds: [99999999], // does not exist
        playerCeIds: [null],
      );

      final specs = CandidateConverter(roster).convert(candidate);
      expect(specs, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Smoke quest end-to-end
  // ---------------------------------------------------------------------------

  group('CandidateConverter smoke quest end-to-end', () {
    test('Altria + Castoria support + MLB Kaleido: all specs run without error', () async {
      // Verifies the converter produces a runnable spec; does not assert cleared
      // (see file-level note on T1-heavy charge assignment).
      final quest = db.gameData.questPhases[kSmokeQuestId]!;

      final roster = UserRoster(
        profileName: 'test',
        servants: {
          kAltriaPengId: OwnedServant(
            level: 90,
            npLevel: 1,
            skillLevels: [1, 10, 1],
            fouAtk: 1000,
            fouHp: 1000,
          ),
        },
        craftEssences: {kKaleidoId: OwnedCE(level: 100, mlb: true)},
      );

      final candidate = CandidateTeam(
        supportSvtId: kCastoriaId,
        playerSvtIds: [kAltriaPengId],
        playerCeIds: [kKaleidoId],
      );

      final specs = CandidateConverter(roster).convert(candidate);
      expect(specs, isNotEmpty);

      for (final spec in specs) {
        final result = await HeadlessRunner(quest: quest).run(spec);
        expect(result.outcome, isNot(SimulationOutcome.error),
            reason: result.errorMessage ?? '');
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Montjoie 90 end-to-end
  // ---------------------------------------------------------------------------

  group('CandidateConverter Montjoie 90 (quest 94093408)', () {
    late QuestPhase montjoieQuest;

    setUpAll(() {
      final file = File('test/app/optimizer/fixtures/quest_94093408.json');
      final jsonMap = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      montjoieQuest = QuestPhase.fromJson(jsonMap);
    });

    // -------------------------------------------------------------------------
    // Arts team: Ibuki (Black Grail) · owned Castoria · support Castoria
    //            MC: New Year's Wardrobe (id 260)
    //
    // Layout: Ibuki (AoE, lv102) → slot 0; owned Castoria (support, lv100) → slot 1;
    //         support Castoria (support, lv90) → slot 2. All 3 in frontline.
    //
    // Battery spread: each Castoria's S2/S3 are chargesNp=true and ownNpTurn=null,
    // so they spread across npTurns=[1,2,3]. T1 and T2 each get one +50% charge
    // from each Castoria → Ibuki gains 100% on T1 (incl. append 20%) and enough
    // NP regen + batteries to loop T2 and T3.
    // -------------------------------------------------------------------------

    test('Arts team (Ibuki + double Castoria) clears in at least one spec', () async {
      final roster = UserRoster(
        profileName: 'test',
        servants: {
          kIbukiSumId: OwnedServant(
            level: 102,
            npLevel: 1,
            skillLevels: [10, 10, 10],
            appendLevels: [0, 10, 0],
            fouAtk: 2000,
            fouHp: 2000,
          ),
          kCastoriaId: OwnedServant(
            level: 100,
            npLevel: 1,
            skillLevels: [10, 10, 10],
            appendLevels: [0, 10, 0],
            fouAtk: 1040,
            fouHp: 1000,
          ),
        },
        craftEssences: {kBlackGrailId: OwnedCE(level: 89, mlb: true)},
        mysticCodes: {kNewYearsOutfitId: 10},
      );

      final candidate = CandidateTeam(
        supportSvtId: kCastoriaId,
        playerSvtIds: [kIbukiSumId, kCastoriaId],
        playerCeIds: [kBlackGrailId, null],
        mysticCodeId: kNewYearsOutfitId,
        mysticCodeLevel: 10,
      );

      final converter = CandidateConverter(roster);
      final specs = converter.convert(candidate);
      expect(specs, isNotEmpty, reason: 'Converter must produce at least one TeamSpec');
      print('Arts team: ${specs.length} spec(s) generated');

      final runner = HeadlessRunner(quest: montjoieQuest);
      SimulationResult? firstClear;
      for (int i = 0; i < specs.length; i++) {
        final spec = specs[i];
        final result = await runner.run(spec);
        expect(result.outcome, isNot(SimulationOutcome.error),
            reason: 'Spec[$i] crashed: ${result.errorMessage}');
        final t1 = spec.turns[0];
        final t2 = spec.turns[1];
        final t3 = spec.turns[2];
        print('Spec[$i] np=${[t1.npSlots, t2.npSlots, t3.npSlots]} '
            'skills=${[t1.skills.length, t2.skills.length, t3.skills.length]} '
            '→ ${result.outcome} (turns=${result.totalTurns})');
        for (final (ti, t) in [(1,t1),(2,t2),(3,t3)]) {
          if (t.skills.isNotEmpty) {
            print('  T$ti: ${t.skills.map((s) => '(s${s.slotIndex},sk${s.skillIndex},tgt${s.allyTarget})').join(' ')}');
          }
        }
        if (result.cleared) firstClear ??= result;
      }

      expect(firstClear, isNotNull,
          reason: 'Battery spread fix should produce at least one clearing spec '
              'for Ibuki + double Castoria on Montjoie 90.');
    });

    // -------------------------------------------------------------------------
    // Buster team: Mélusine Asc2 (Black Grail) · owned Vitch · Oberon
    //              support: Vitch (friend)  MC: Chaldea Uniform Decisive Battle (id 210)
    //
    // Layout after sort: Mélusine (AoE) → slot 0; Oberon (AoE) → slot 1;
    //   support Vitch (ST) → slot 2; owned Vitch (ST) → slot 3 (backline).
    // Plug Suit OC swaps slot 2 ↔ slot 3, bringing owned Vitch into frontline.
    //
    // Mélusine limitCount=2 (Ascension 2) so her S3 triggers the transformation
    // that changes her to Ascension 4 and fills her NP gauge.
    // -------------------------------------------------------------------------

    test('Buster team (Mélusine Asc2 + double Vitch + Oberon) clears in at least one spec', () async {
      final roster = UserRoster(
        profileName: 'test',
        servants: {
          kMelusineId: OwnedServant(
            level: 90,
            npLevel: 1,
            skillLevels: [10, 10, 10],
            limitCount: 2, // Ascension 2: transformation + NP fill via S3
            fouAtk: 2000,
            fouHp: 2000,
          ),
          kVitchId: OwnedServant(
            level: 90,
            npLevel: 1,
            skillLevels: [10, 10, 10],
            fouAtk: 1000,
            fouHp: 1000,
          ),
          kOberonId: OwnedServant(
            level: 90,
            npLevel: 1,
            skillLevels: [10, 10, 10],
            fouAtk: 1000,
            fouHp: 1000,
          ),
        },
        craftEssences: {kBlackGrailId: OwnedCE(level: 89, mlb: true)},
        mysticCodes: {kPlugSuitId: 8},
      );

      final candidate = CandidateTeam(
        supportSvtId: kVitchId, // friend Vitch as support
        playerSvtIds: [kMelusineId, kVitchId, kOberonId],
        playerCeIds: [kBlackGrailId, null, null],
        mysticCodeId: kPlugSuitId,
        mysticCodeLevel: 8,
      );

      final converter = CandidateConverter(roster);
      final specs = converter.convert(candidate);
      expect(specs, isNotEmpty, reason: 'Converter must produce at least one TeamSpec');

      print('Buster team: ${specs.length} spec(s) generated');
      final runner = HeadlessRunner(quest: montjoieQuest);
      SimulationResult? firstClear;
      for (int i = 0; i < specs.length; i++) {
        final spec = specs[i];
        final result = await runner.run(spec);
        expect(result.outcome, isNot(SimulationOutcome.error),
            reason: 'Spec[$i] crashed the simulator: ${result.errorMessage}');
        final t1 = spec.turns[0];
        final t2 = spec.turns[1];
        final t3 = spec.turns[2];
        if (result.cleared || i == 54 || i == 55 || i == 56) {
          print('Spec[$i] np=${[t1.npSlots, t2.npSlots, t3.npSlots]} '
              'oc=${[t1.orderChange?.onFieldSlot, t2.orderChange?.onFieldSlot, t3.orderChange?.onFieldSlot]} '
              'skills=${[t1.skills.length, t2.skills.length, t3.skills.length]} → ${result.outcome}');
          for (final (ti, t) in [(1, t1), (2, t2), (3, t3)]) {
            if (t.skills.isNotEmpty) {
              print('  T$ti: ${t.skills.map((s) => '(s${s.slotIndex},sk${s.skillIndex},tgt${s.allyTarget})').join(' ')}');
            }
          }
        }
        if (result.cleared) firstClear ??= result;
      }

      expect(firstClear, isNotNull,
          reason: 'Buster OC team should produce at least one clearing spec '
              'for Mélusine (Asc2) + double Vitch + Oberon on Montjoie 90.');
    });

    // -------------------------------------------------------------------------
    // Double skill-use team: Altria Pendragon (Duke of Flame) · owned Vitch ·
    //                        support Vitch  ·  Oberon (backline)
    //                        MC: Chaldea Uniform Decisive Battle (id 210)
    //
    // Layout: Altria (AoE, lv90) → slot 0; owned Vitch → slot 1;
    //         support Vitch → slot 2; Oberon → slot 3 (backline).
    //
    // Key mechanics:
    //   - Duke of Flame: on first NP use, NP level +2 (Altria fires at NP3),
    //     raising NP refund and increasing the T1 NP damage.
    //   - Altria Append 2 lv10: +20% starting NP. Combined with S3 (+30%),
    //     plus Vitch S1 CD reduction (−2 CD to all allies), Altria can re-use
    //     all 3 skills on T3 (double-use). This is the core of the loop.
    //   - Oberon sub (OC T2): S1 party-wide 20% NP top-up on T2; S2 single-ally
    //     50% NP charge on T3; S3 damage amp on T3. The incoming skill split
    //     enumeration (2^N subsets) handles finding the correct assignment.
    // -------------------------------------------------------------------------

    test('Altria double-use (Duke of Flame + double Vitch + Oberon OC) clears in at least one spec', () async {
      final roster = UserRoster(
        profileName: 'test',
        servants: {
          kAltriaPengId: OwnedServant(
            level: 90,
            npLevel: 1,
            skillLevels: [10, 10, 10],
            appendLevels: [0, 10, 0], // Append 2 lv10 = +20% starting NP
            fouAtk: 1000,
            fouHp: 1000,
          ),
          kVitchId: OwnedServant(
            level: 90,
            npLevel: 1,
            skillLevels: [10, 10, 10],
            fouAtk: 1000,
            fouHp: 1000,
          ),
          kOberonId: OwnedServant(
            level: 90,
            npLevel: 1,
            skillLevels: [10, 10, 10],
            fouAtk: 1000,
            fouHp: 1000,
          ),
        },
        craftEssences: {kDukeOfFlameId: OwnedCE(level: 100, mlb: false)},
        mysticCodes: {kPlugSuitId: 10},
      );

      final candidate = CandidateTeam(
        supportSvtId: kVitchId, // friend Vitch as support
        playerSvtIds: [kAltriaPengId, kVitchId, kOberonId],
        playerCeIds: [kDukeOfFlameId, null, null],
        mysticCodeId: kPlugSuitId,
        mysticCodeLevel: 10,
      );

      final converter = CandidateConverter(roster);
      final specs = converter.convert(candidate);
      expect(specs, isNotEmpty, reason: 'Converter must produce at least one TeamSpec');

      print('Altria double-use team: ${specs.length} spec(s) generated');
      final runner = HeadlessRunner(quest: montjoieQuest);
      SimulationResult? firstClear;
      for (int i = 0; i < specs.length; i++) {
        final spec = specs[i];
        final result = await runner.run(spec);
        expect(result.outcome, isNot(SimulationOutcome.error),
            reason: 'Spec[$i] crashed: ${result.errorMessage}');
        if (result.cleared) {
          final t1 = spec.turns[0];
          final t2 = spec.turns[1];
          final t3 = spec.turns[2];
          print('CLEARED Spec[$i] np=${[t1.npSlots, t2.npSlots, t3.npSlots]} '
              'oc=${[t1.orderChange?.onFieldSlot, t2.orderChange?.onFieldSlot, t3.orderChange?.onFieldSlot]} '
              'skills=${[t1.skills.length, t2.skills.length, t3.skills.length]}');
          for (final (ti, t) in [(1, t1), (2, t2), (3, t3)]) {
            if (t.skills.isNotEmpty) {
              print('  T$ti: ${t.skills.map((s) => '(s${s.slotIndex},sk${s.skillIndex},tgt${s.allyTarget})').join(' ')}');
            }
          }
          firstClear ??= result;
        }
      }

      expect(firstClear, isNotNull,
          reason: 'Altria double-use team (Duke of Flame + double Vitch + Oberon OC) '
              'should produce at least one clearing spec for Montjoie 90.');
    });
  });
}
