import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/optimizer/simulation/headless_runner.dart';
import 'package:chaldea/models/models.dart';
import '../../test_init.dart';

void main() async {
  await initiateForTest();

  // Quest 9300040603 is used by Chaldea's own battle tests.
  // It has a Sky (Caster) enemy at index 1 on wave 1.
  // We use it here as a known-good single-test-wave quest.
  const int testQuestId = 9300040603;

  // Kaleidoscope MLB id: 9400340
  // Yang Guifei (id 2500400): AoE Quick, fires NP well, used in existing tests.
  // With MLB Kaleido she starts at 100% NP.

  group('HeadlessRunner smoke tests', () {
    test('initializes and runs without crashing', () async {
      final quest = db.gameData.questPhases[testQuestId]!;
      final runner = HeadlessRunner(quest: quest);

      final svt = db.gameData.servantsById[2500400]!; // Yang Guifei
      final kaleido = db.gameData.craftEssencesById[9400340]!; // Kaleidoscope

      final spec = TeamSpec(
        slots: [
          SlotSpec(
            svt: svt,
            level: 90,
            tdLevel: 5,
            skillLevels: [10, 10, 10],
            atkFou: 1000,
            hpFou: 1000,
            ce: kaleido,
            ceMlb: true,
            ceLevel: 100,
          ),
        ],
        turns: [
          // Turn 1: fire NP immediately (MLB Kaleido = 100% start)
          TurnActions(npSlots: [0]),
          // Turns 2-3 in case quest has multiple waves
          TurnActions(npSlots: [0]),
          TurnActions(npSlots: [0]),
        ],
      );

      final result = await runner.run(spec);

      // We just verify it ran without an error — pass/fail depends on quest structure
      expect(result.outcome, isNot(SimulationOutcome.error),
          reason: result.errorMessage ?? '');
      print('Result: $result');
    });

    test('Altria Pendragon with MLB Kaleido runs without error', () async {
      final quest = db.gameData.questPhases[testQuestId]!;
      final runner = HeadlessRunner(quest: quest);

      final altria = db.gameData.servantsById[100100]!;
      final kaleido = db.gameData.craftEssencesById[9400340]!;

      final spec = TeamSpec(
        slots: [
          SlotSpec(
            svt: altria,
            level: 90,
            tdLevel: 1,
            skillLevels: [1, 10, 1],
            atkFou: 1000,
            hpFou: 1000,
            ce: kaleido,
            ceMlb: true,
            ceLevel: 100,
          ),
        ],
        turns: [
          TurnActions(npSlots: [0]),
          TurnActions(npSlots: [0]),
          TurnActions(npSlots: [0]),
        ],
      );

      final result = await runner.run(spec);

      // Smoke test: just verify no crash. Quest 9300040603 has multiple waves
      // so a lone NP1 Altria without buffs is not expected to clear.
      // Actual clearing behaviour is validated by the Montjoie group below.
      expect(result.outcome, isNot(SimulationOutcome.error),
          reason: result.errorMessage ?? '');
    });
  });

  // ---------------------------------------------------------------------------
  // Montjoie 90 node (quest 94093408) — verified 3-turn clears from manual run
  //
  // "Acting Boot Camp! Hall" — all Berserkers, Recommend Lv 90, 40 AP.
  // Wave 1: Demonic Monkey × 2 + Shark Pirate
  // Wave 2: Ugallu + Shark Pirate + Demonic Monkey
  // Wave 3: Beowulf (100k HP) + Demonic Monkey + Shark Pirate
  //
  // Two known-good teams confirmed in the Chaldea simulator by the user.
  // The quest fixture is in test/app/optimizer/fixtures/quest_94093408.json
  // (fetched from Atlas Academy API and committed as a test asset).
  // ---------------------------------------------------------------------------

  group('Montjoie 90 node (quest 94093408) — verified 3-turn clears', () {
    late QuestPhase montjoieQuest;

    setUpAll(() {
      final file = File('test/app/optimizer/fixtures/quest_94093408.json');
      final jsonMap = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      montjoieQuest = QuestPhase.fromJson(jsonMap);
    });

    // -------------------------------------------------------------------------
    // Team 1: Arts loop — Summer Ibuki-Douji + double Castoria
    //
    // Roster:
    //   Slot 0: Summer Ibuki-Douji (704300), Lv.102, NP1, skills 10/10/10,
    //           append [0,10,0], Fou 2000/2000, limitCount=4,
    //           CE 9400480 Black Grail MLB Lv.89 (50% starting NP + NP dmg up)
    //   Slot 1: Own Castoria (504500), Lv.100, NP1, skills 10/10/10,
    //           append [0,10,0], Fou 1040/1000
    //   Slot 2: Borrowed Castoria (504500, support), Lv.90, NP5, skills 10/10/10
    //   MC:     260 (新春の装い / New Year's Outfit), Lv.10
    //
    // Castoria skills (index 0-2):
    //   S1 (761450) 希望のカリスマ B — party-wide NP charge + card-type up
    //   S2 (762550) 湖の加護 A      — single-target NP charge + NP damage up
    //   S3 (763650) 選定の剣 EX     — single-target NP charge + Arts up
    //
    // Turn sequence:
    //   T1: Ibuki S1 (party NP charge), Ibuki S2 (self buff),
    //       Castoria(own) S1, S2→Ibuki, S3→Ibuki,
    //       Castoria(sup) S1, S3→Ibuki,
    //       MC S1; fire NP slot 0
    //   T2: Castoria(sup) S2→Ibuki; fire NP slot 0
    //   T3: Ibuki S3; fire NP slot 0
    // -------------------------------------------------------------------------
    test('Arts team: Summer Ibuki + double Castoria clears in 3 turns', () async {
      final ibuki = db.gameData.servantsById[704300]!;
      final castoria = db.gameData.servantsById[504500]!;
      final blackGrail = db.gameData.craftEssencesById[9400480]!;

      final spec = TeamSpec(
        slots: [
          // Slot 0: Summer Ibuki-Douji with Black Grail MLB
          SlotSpec(
            svt: ibuki,
            level: 102,
            limitCount: 4,
            tdLevel: 1,
            skillLevels: [10, 10, 10],
            appendLevels: [0, 10, 0],
            atkFou: 2000,
            hpFou: 2000,
            ce: blackGrail,
            ceMlb: true,
            ceLevel: 89,
          ),
          // Slot 1: Own Castoria
          SlotSpec(
            svt: castoria,
            level: 100,
            limitCount: 4,
            tdLevel: 1,
            skillLevels: [10, 10, 10],
            appendLevels: [0, 10, 0],
            atkFou: 1040,
            hpFou: 1000,
          ),
          // Slot 2: Borrowed support Castoria
          SlotSpec(
            svt: castoria,
            level: 90,
            limitCount: 4,
            tdLevel: 5,
            skillLevels: [10, 10, 10],
            atkFou: 1000,
            hpFou: 1000,
            isSupport: true,
          ),
        ],
        mysticCode: db.gameData.mysticCodes[260],
        mysticCodeLevel: 10,
        turns: [
          TurnActions(
            skills: [
              // Ibuki S1 — 真夏の女神 B (party NP charge + Arts up)
              SkillAction(slotIndex: 0, skillIndex: 0),
              // Ibuki S2 — サマー・チアリーダー C (self buff)
              SkillAction(slotIndex: 0, skillIndex: 1),
              // Own Castoria S1 — 希望のカリスマ B (party NP charge)
              SkillAction(slotIndex: 1, skillIndex: 0),
              // Own Castoria S2 — 湖の加護 A → Ibuki (NP charge + NP dmg up)
              SkillAction(slotIndex: 1, skillIndex: 1, allyTarget: 0),
              // Own Castoria S3 — 選定の剣 EX → Ibuki (NP charge + Arts up)
              SkillAction(slotIndex: 1, skillIndex: 2, allyTarget: 0),
              // Support Castoria S1 — party NP charge
              SkillAction(slotIndex: 2, skillIndex: 0),
              // Support Castoria S3 → Ibuki (NP charge + Arts up)
              SkillAction(slotIndex: 2, skillIndex: 2, allyTarget: 0),
              // MC S1 — 除災招福 (party buff)
              SkillAction(slotIndex: -1, skillIndex: 0),
            ],
            npSlots: [0],
          ),
          TurnActions(
            skills: [
              // Support Castoria S2 → Ibuki (NP charge + NP dmg up)
              SkillAction(slotIndex: 2, skillIndex: 1, allyTarget: 0),
            ],
            npSlots: [0],
          ),
          TurnActions(
            skills: [
              // Ibuki S3 — ビーチ・アポカリプス A+ (damage buff)
              SkillAction(slotIndex: 0, skillIndex: 2),
            ],
            npSlots: [0],
          ),
        ],
      );

      final result = await HeadlessRunner(quest: montjoieQuest).run(spec);

      expect(result.outcome, isNot(SimulationOutcome.error),
          reason: result.errorMessage ?? '');
      expect(result.cleared, isTrue,
          reason: 'Arts team should 3-turn clear Montjoie 90. Result: $result');
      expect(result.totalTurns, lessThanOrEqualTo(3));
      print('Arts team result: $result');
    });

    // -------------------------------------------------------------------------
    // Team 2: Buster — Mélusine + double Koyanskaya of Light + Oberon sub
    //
    // Roster:
    //   Slot 0: Mélusine (304800), Lv.100, NP1, skills 10/10/10,
    //           Fou 2000/2000, limitCount=2,
    //           CE 9400480 Black Grail MLB Lv.89
    //   Slot 1: Own Koyanskaya of Light (604200), Lv.90, NP1, skills 10/10/10,
    //           Fou 1000/1000
    //   Slot 2: Borrowed Koyanskaya of Light (604200, support), Lv.90, NP5,
    //           skills 10/10/10
    //   Slot 3 (backline): Oberon-Vortigern (2800100), Lv.90, NP1,
    //           skills 10/10/10, Fou 1000/1000
    //   MC:     210 (決戦用カルデア制服 / Plug Suit), Lv.8
    //
    // Koyanskaya of Light skills (index 0-2):
    //   S1 (905550) イノベイター・バニー A — single-target NP charge + CD reduce 2
    //                                       [Demerit] party HP drain 1000
    //   S2 (906550) 殺戮技巧（人） A      — single-target Buster up + crit dmg up
    //   S3 (907550) ＮＦＦスペシャル A    — single-target NP charge + crit stars
    //
    // Oberon skills (index 0-2):
    //   S1 (902650) 夜のとばり EX — party Quick up + NP charge to all
    //   S2 (903650) 朝のひばり EX — single-target Buster up + NP damage up
    //   S3 (904650) 夢のおわり EX — single-target large NP charge (+ weakness)
    //
    // Mélusine skills (index 0-2):
    //   S1 (886450) ドラゴンハート B — self NP gain up + NP charge
    //   S2 (887450) ペリー・ダンサー B — self buff
    //   S3 (888550) レイ・ホライゾン A — TRANSFORM skill (switches to dragon form)
    //   S3 post-transform (888575) — post-transform version
    //
    // Turn sequence:
    //   T1: Mélusine S1 (self NP charge), S2 (self buff), S3 (transform);
    //       Koya(own) S2→Mélusine, S3→Mélusine;
    //       Koya(sup) S2→Mélusine, S3→Mélusine;
    //       fire NP slot 0
    //   T2: Koya(own) S1→Mélusine (NP charge + CD reduce 2); Koya(sup) S1→Mélusine;
    //       fire NP slot 0
    //   T3: MC S3 (Order Change: swap slot2 Koya-sup for backline slot0 Oberon);
    //       Mélusine S1, S2, S3 (dragon-form skills if reset by transform);
    //       Oberon S1 (party), S2→Mélusine, S3→Mélusine;
    //       fire NP slot 0
    //
    // Note: Mélusine's transform (T1 S3) may reset her S1/S2 for dragon form.
    // HeadlessRunner silently skips skills that are on cooldown, so specifying
    // them here is safe — if they're on CD, the test will reveal the charge gap.
    // -------------------------------------------------------------------------
    test('Buster team: Mélusine + double Vitch + Oberon sub clears in 3 turns',
        () async {
      final melusine = db.gameData.servantsById[304800]!;
      final vitch = db.gameData.servantsById[604200]!;
      final oberon = db.gameData.servantsById[2800100]!;
      final blackGrail = db.gameData.craftEssencesById[9400480]!;

      final spec = TeamSpec(
        slots: [
          // Slot 0: Mélusine with Black Grail MLB, starts in human form (limitCount=2)
          SlotSpec(
            svt: melusine,
            level: 100,
            limitCount: 2,
            tdLevel: 1,
            skillLevels: [10, 10, 10],
            atkFou: 2000,
            hpFou: 2000,
            ce: blackGrail,
            ceMlb: true,
            ceLevel: 89,
          ),
          // Slot 1: Own Koyanskaya of Light
          SlotSpec(
            svt: vitch,
            level: 90,
            limitCount: 4,
            tdLevel: 1,
            skillLevels: [10, 10, 10],
            atkFou: 1000,
            hpFou: 1000,
          ),
          // Slot 2: Borrowed support Koyanskaya of Light
          SlotSpec(
            svt: vitch,
            level: 90,
            limitCount: 4,
            tdLevel: 5,
            skillLevels: [10, 10, 10],
            atkFou: 1000,
            hpFou: 1000,
            isSupport: true,
          ),
          // Slot 3 (backline): Oberon-Vortigern
          SlotSpec(
            svt: oberon,
            level: 90,
            limitCount: 4,
            tdLevel: 1,
            skillLevels: [10, 10, 10],
            atkFou: 1000,
            hpFou: 1000,
          ),
        ],
        mysticCode: db.gameData.mysticCodes[210],
        mysticCodeLevel: 8,
        turns: [
          // Turn 1: Transform Mélusine, double-Vitch charge her up, fire NP
          TurnActions(
            skills: [
              // Mélusine S1 — ドラゴンハート B (self NP charge + NP gain up)
              SkillAction(slotIndex: 0, skillIndex: 0),
              // Mélusine S2 — ペリー・ダンサー B (self buff)
              SkillAction(slotIndex: 0, skillIndex: 1),
              // Mélusine S3 — レイ・ホライゾン A (TRANSFORM to dragon form)
              SkillAction(slotIndex: 0, skillIndex: 2),
              // Own Koya S2 → Mélusine (Buster up + crit dmg)
              SkillAction(slotIndex: 1, skillIndex: 1, allyTarget: 0),
              // Own Koya S3 → Mélusine (NP charge + crit stars)
              SkillAction(slotIndex: 1, skillIndex: 2, allyTarget: 0),
              // Support Koya S2 → Mélusine
              SkillAction(slotIndex: 2, skillIndex: 1, allyTarget: 0),
              // Support Koya S3 → Mélusine
              SkillAction(slotIndex: 2, skillIndex: 2, allyTarget: 0),
            ],
            npSlots: [0],
          ),
          // Turn 2: Both Koyanskayas use S1 (NP charge → Mélusine), fire NP
          TurnActions(
            skills: [
              // Own Koya S1 — single-target NP charge + CD reduce 2 → Mélusine
              SkillAction(slotIndex: 1, skillIndex: 0, allyTarget: 0),
              // Support Koya S1 — single-target NP charge + CD reduce 2 → Mélusine
              SkillAction(slotIndex: 2, skillIndex: 0, allyTarget: 0),
            ],
            npSlots: [0],
          ),
          // Turn 3: Order Change brings Oberon in, Oberon buffs Mélusine, fire NP
          TurnActions(
            skills: [
              // MC S3 — Order Change (swap frontline slot 2 for backline slot 0)
              SkillAction(slotIndex: -1, skillIndex: 2),
              // Mélusine S1 (dragon form, if available after transform reset)
              SkillAction(slotIndex: 0, skillIndex: 0),
              // Mélusine S2 (dragon form, if available)
              SkillAction(slotIndex: 0, skillIndex: 1),
              // Mélusine S3 post-transform (if available)
              SkillAction(slotIndex: 0, skillIndex: 2),
              // Oberon S1 — 夜のとばり EX (party NP charge + Quick up)
              SkillAction(slotIndex: 2, skillIndex: 0),
              // Oberon S2 → Mélusine — 朝のひばり EX (Buster up + NP dmg up)
              SkillAction(slotIndex: 2, skillIndex: 1, allyTarget: 0),
              // Oberon S3 → Mélusine — 夢のおわり EX (large NP charge)
              SkillAction(slotIndex: 2, skillIndex: 2, allyTarget: 0),
            ],
            npSlots: [0],
            // Swap frontline slot 2 (Koya-support) out for backline slot 0 (Oberon)
            orderChange: OrderChangeAction(onFieldSlot: 2, backlineSlot: 0),
          ),
        ],
      );

      final result = await HeadlessRunner(quest: montjoieQuest).run(spec);

      expect(result.outcome, isNot(SimulationOutcome.error),
          reason: result.errorMessage ?? '');
      expect(result.cleared, isTrue,
          reason: 'Buster team should 3-turn clear Montjoie 90. Result: $result');
      expect(result.totalTurns, lessThanOrEqualTo(3));
      print('Buster team result: $result');
    });
  });
}
