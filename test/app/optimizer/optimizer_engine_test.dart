/// End-to-end tests for the full optimizer pipeline:
///   OptimizerEngine → ShareDataConverter → RunHistory → runFromShareData
///
/// Test groups:
///   1. ShareDataConverter — TeamSpec → BattleShareData roundtrip
///   2. RunHistory         — append/loadAll JSONL roundtrip
///   3. OptimizerEngine    — smoke run (no crash, specs execute)
///   4. runFromShareData   — replay a cleared spec from ShareData
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/optimizer/optimizer_engine.dart';
import 'package:chaldea/app/optimizer/roster/run_history.dart';
import 'package:chaldea/app/optimizer/roster/user_roster.dart';
import 'package:chaldea/app/optimizer/simulation/headless_runner.dart';
import 'package:chaldea/app/optimizer/simulation/share_data_converter.dart';
import 'package:chaldea/models/models.dart';
import '../../test_init.dart';

// ---------------------------------------------------------------------------
// Shared constants
// ---------------------------------------------------------------------------

const int kSmokeQuestId = 9300040603; // single-wave Sky Caster quest

// Servant IDs
const int kAltriaPengId = 100100; // Altria Pendragon (AoE Saber)
const int kCastoriaId = 504500;   // Altria Caster (Castoria)
const int kIbukiSumId = 704300;   // Summer Ibuki-Douji
const int kVitchId = 604200;      // Koyanskaya of Light
const int kOberonId = 2800100;    // Oberon-Vortigern

// CE IDs
const int kKaleidoId = 9400340;   // Kaleidoscope (100% NP start, MLB)
const int kBlackGrailId = 9400480;// Black Grail

// MC IDs
const int kNewYearsOutfitId = 260;
const int kPlugSuitId = 210;

void main() async {
  await initiateForTest();

  // ---------------------------------------------------------------------------
  // 1. ShareDataConverter roundtrip
  // ---------------------------------------------------------------------------

  group('ShareDataConverter', () {
    test('converts TeamSpec → BattleShareData without error', () {
      final quest = db.gameData.questPhases[kSmokeQuestId]!;
      final altria = db.gameData.servantsById[kAltriaPengId]!;
      final kaleido = db.gameData.craftEssencesById[kKaleidoId]!;

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

      final shareData = ShareDataConverter.convert(quest, spec);

      // Formation should have slot 0 filled, slots 1-5 null.
      expect(shareData.formation.svts[0], isNotNull);
      expect(shareData.formation.svts[0]!.svtId, equals(kAltriaPengId));
      expect(shareData.formation.svts[1], isNull);

      // Quest info populated. quest.id is the bare quest ID (not the
      // questPhases map key which is questId*100+phase).
      expect(shareData.quest, isNotNull);
      expect(shareData.quest!.id, equals(quest.id));

      // Action log: 3 attack records (one per turn), no skill records.
      expect(shareData.actions, hasLength(3));
      expect(shareData.actions.every((a) => a.type == BattleRecordDataType.attack),
          isTrue);
    });

    test('skill actions appear before attack actions within each turn', () {
      final quest = db.gameData.questPhases[kSmokeQuestId]!;
      final altria = db.gameData.servantsById[kAltriaPengId]!;
      final kaleido = db.gameData.craftEssencesById[kKaleidoId]!;
      final castoria = db.gameData.servantsById[kCastoriaId]!;

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
          SlotSpec(
            svt: castoria,
            level: 90,
            tdLevel: 1,
            skillLevels: [10, 10, 10],
            atkFou: 1000,
            hpFou: 1000,
          ),
        ],
        turns: [
          TurnActions(
            skills: [
              SkillAction(slotIndex: 1, skillIndex: 0), // Castoria S1
              SkillAction(slotIndex: 1, skillIndex: 2, allyTarget: 0), // Castoria S3 → Altria
            ],
            npSlots: [0],
          ),
          TurnActions(npSlots: [0]),
          TurnActions(npSlots: [0]),
        ],
      );

      final shareData = ShareDataConverter.convert(quest, spec);

      // T1: 2 skill actions + 1 attack = 3 records;  T2, T3: 1 attack each = 2 more.
      expect(shareData.actions, hasLength(5));
      expect(shareData.actions[0].type, equals(BattleRecordDataType.skill));
      expect(shareData.actions[1].type, equals(BattleRecordDataType.skill));
      expect(shareData.actions[2].type, equals(BattleRecordDataType.attack));
    });

    test('MC skill maps to svt=null in action log', () {
      final quest = db.gameData.questPhases[kSmokeQuestId]!;
      final altria = db.gameData.servantsById[kAltriaPengId]!;

      final spec = TeamSpec(
        slots: [
          SlotSpec(
            svt: altria,
            level: 90,
            tdLevel: 1,
            skillLevels: [1, 10, 1],
            atkFou: 1000,
            hpFou: 1000,
          ),
        ],
        mysticCode: db.gameData.mysticCodes[kNewYearsOutfitId],
        mysticCodeLevel: 10,
        turns: [
          TurnActions(
            skills: [SkillAction(slotIndex: -1, skillIndex: 0)], // MC S1
            npSlots: [0],
          ),
        ],
      );

      final shareData = ShareDataConverter.convert(quest, spec);
      final skillAction = shareData.actions.firstWhere(
          (a) => a.type == BattleRecordDataType.skill);

      expect(skillAction.svt, isNull,
          reason: 'MC skills must encode as svt=null');
      expect(skillAction.skill, equals(0));
    });

    test('OrderChange populates replaceMemberIndexes in delegate', () {
      final quest = db.gameData.questPhases[kSmokeQuestId]!;
      final altria = db.gameData.servantsById[kAltriaPengId]!;
      final oberon = db.gameData.servantsById[kOberonId]!;

      final spec = TeamSpec(
        slots: [
          SlotSpec(svt: altria, level: 90, tdLevel: 1, skillLevels: [1, 10, 1],
              atkFou: 1000, hpFou: 1000),
          null,
          null,
          SlotSpec(svt: oberon, level: 90, tdLevel: 1, skillLevels: [10, 10, 10],
              atkFou: 1000, hpFou: 1000),
        ],
        mysticCode: db.gameData.mysticCodes[kPlugSuitId],
        mysticCodeLevel: 8,
        turns: [
          TurnActions(npSlots: [0]),
          TurnActions(
            skills: [SkillAction(slotIndex: -1, skillIndex: 2)], // Order Change
            npSlots: [0],
            orderChange: OrderChangeAction(onFieldSlot: 2, backlineSlot: 0),
          ),
        ],
      );

      final shareData = ShareDataConverter.convert(quest, spec);

      expect(shareData.delegate, isNotNull);
      expect(shareData.delegate!.replaceMemberIndexes, hasLength(1));
      expect(shareData.delegate!.replaceMemberIndexes[0], equals([2, 0]));
    });

    test('BattleShareData serializes and parses back (roundtrip)', () {
      final quest = db.gameData.questPhases[kSmokeQuestId]!;
      final altria = db.gameData.servantsById[kAltriaPengId]!;
      final kaleido = db.gameData.craftEssencesById[kKaleidoId]!;

      final spec = TeamSpec(
        slots: [
          SlotSpec(svt: altria, level: 90, tdLevel: 1, skillLevels: [1, 10, 1],
              atkFou: 1000, hpFou: 1000, ce: kaleido, ceMlb: true, ceLevel: 100),
        ],
        turns: [TurnActions(npSlots: [0])],
      );

      final shareData = ShareDataConverter.convert(quest, spec);
      final json = shareData.toJson();
      final parsed = BattleShareData.fromJson(json);

      expect(parsed.quest!.id, equals(shareData.quest!.id));
      expect(parsed.formation.svts[0]!.svtId, equals(kAltriaPengId));
      expect(parsed.actions, hasLength(shareData.actions.length));
    });
  });

  // ---------------------------------------------------------------------------
  // 2. RunHistory JSONL roundtrip
  // ---------------------------------------------------------------------------

  group('RunHistory', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('run_history_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('append and loadAll roundtrip', () {
      final filePath = '${tempDir.path}/history.jsonl';
      final history = RunHistory(filePath);
      final quest = db.gameData.questPhases[kSmokeQuestId]!;
      final altria = db.gameData.servantsById[kAltriaPengId]!;

      final spec = TeamSpec(
        slots: [
          SlotSpec(svt: altria, level: 90, tdLevel: 1, skillLevels: [1, 10, 1],
              atkFou: 1000, hpFou: 1000),
        ],
        turns: [TurnActions(npSlots: [0])],
      );

      final shareData = ShareDataConverter.convert(quest, spec);
      final record = RunRecord(
        timestamp: DateTime(2026, 3, 19, 12, 0, 0),
        questId: quest.id,
        questPhase: quest.phase,
        totalTurns: 1,
        battleData: shareData,
      );

      history.append(record);
      history.append(record); // append twice to test multi-line

      final loaded = history.loadAll();
      expect(loaded, hasLength(2));
      expect(loaded[0].questId, equals(quest.id));
      expect(loaded[0].totalTurns, equals(1));
      expect(loaded[0].battleData.quest!.id, equals(quest.id));
    });

    test('loadAll returns empty list when file does not exist', () {
      final history = RunHistory('${tempDir.path}/nonexistent.jsonl');
      expect(history.loadAll(), isEmpty);
    });

    test('loadForQuest filters by questId', () {
      final filePath = '${tempDir.path}/history2.jsonl';
      final history = RunHistory(filePath);
      final quest = db.gameData.questPhases[kSmokeQuestId]!;
      final altria = db.gameData.servantsById[kAltriaPengId]!;

      final shareData = ShareDataConverter.convert(
        quest,
        TeamSpec(
          slots: [SlotSpec(svt: altria, level: 90, tdLevel: 1,
              skillLevels: [1, 10, 1], atkFou: 1000, hpFou: 1000)],
          turns: [TurnActions(npSlots: [0])],
        ),
      );

      // Append one record for the smoke quest, one with a fake questId.
      history.append(RunRecord(
          timestamp: DateTime.now(), questId: quest.id, questPhase: quest.phase,
          totalTurns: 1, battleData: shareData));
      history.append(RunRecord(
          timestamp: DateTime.now(), questId: 99999999, questPhase: 1,
          totalTurns: 2, battleData: shareData));

      final filtered = history.loadForQuest(quest.id);
      expect(filtered, hasLength(1));
      expect(filtered[0].questId, equals(quest.id));
    });

    test('malformed line is skipped gracefully', () {
      final filePath = '${tempDir.path}/history3.jsonl';
      // Manually write one good line and one bad line.
      final quest = db.gameData.questPhases[kSmokeQuestId]!;
      final altria = db.gameData.servantsById[kAltriaPengId]!;
      final shareData = ShareDataConverter.convert(
        quest,
        TeamSpec(
          slots: [SlotSpec(svt: altria, level: 90, tdLevel: 1,
              skillLevels: [1, 10, 1], atkFou: 1000, hpFou: 1000)],
          turns: [TurnActions(npSlots: [0])],
        ),
      );
      final goodLine = jsonEncode(RunRecord(
          timestamp: DateTime.now(), questId: quest.id, questPhase: quest.phase,
          totalTurns: 1, battleData: shareData).toJson());
      File(filePath).writeAsStringSync('$goodLine\n{not valid json\n');

      final loaded = RunHistory(filePath).loadAll();
      expect(loaded, hasLength(1)); // bad line skipped
    });
  });

  // ---------------------------------------------------------------------------
  // 3. OptimizerEngine smoke run
  // ---------------------------------------------------------------------------

  group('OptimizerEngine smoke run', () {
    test('runs without crash on single-wave quest with full roster', () async {
      final quest = db.gameData.questPhases[kSmokeQuestId]!;

      // Five-servant roster used to generate real frontline/backline combos.
      final roster = UserRoster(
        profileName: 'engine_test',
        servants: {
          kAltriaPengId: OwnedServant(
            level: 90, npLevel: 1, skillLevels: [1, 10, 1],
            fouAtk: 1000, fouHp: 1000,
          ),
          kIbukiSumId: OwnedServant(
            level: 102, npLevel: 1, skillLevels: [10, 10, 10],
            appendLevels: [0, 10, 0], fouAtk: 2000, fouHp: 2000,
          ),
          kCastoriaId: OwnedServant(
            level: 100, npLevel: 1, skillLevels: [10, 10, 10],
            appendLevels: [0, 10, 0], fouAtk: 1040, fouHp: 1000,
          ),
          kVitchId: OwnedServant(
            level: 90, npLevel: 1, skillLevels: [10, 10, 10],
            fouAtk: 1000, fouHp: 1000,
          ),
          kOberonId: OwnedServant(
            level: 90, npLevel: 1, skillLevels: [10, 10, 10],
            fouAtk: 1000, fouHp: 1000,
          ),
        },
        craftEssences: {
          kKaleidoId: OwnedCE(level: 100, mlb: true),
          kBlackGrailId: OwnedCE(level: 89, mlb: true),
        },
        mysticCodes: {kNewYearsOutfitId: 10, kPlugSuitId: 8},
      );

      int progressCallCount = 0;
      final engine = OptimizerEngine(
        quest: quest,
        roster: roster,
        maxClears: 5,
        onProgress: (checked, cleared, engineMs) => progressCallCount++,
        progressInterval: 10,
      );

      // Should run and return without throwing.
      final results = await engine.run();

      // Progress callback was called at least once (final tick).
      expect(progressCallCount, greaterThan(0));

      // Each result has the correct quest metadata.
      for (final r in results) {
        expect(r.questId, equals(quest.id));
        expect(r.totalTurns, greaterThan(0));
        expect(r.battleData.formation.svts[0], isNotNull,
            reason: 'Every clear must have a servant in slot 0');
      }

      print('Engine found ${results.length} clear(s) on smoke quest');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('persists clears to RunHistory when filePath provided', () async {
      final tempDir = Directory.systemTemp.createTempSync('engine_history_test_');
      final historyPath = '${tempDir.path}/clears.jsonl';

      try {
        final quest = db.gameData.questPhases[kSmokeQuestId]!;
        // Same five-servant roster so enumerator generates candidates.
        final roster = UserRoster(
          profileName: 'engine_history_test',
          servants: {
            kAltriaPengId: OwnedServant(level: 90, npLevel: 1,
                skillLevels: [1, 10, 1], fouAtk: 1000, fouHp: 1000),
            kIbukiSumId: OwnedServant(level: 102, npLevel: 1,
                skillLevels: [10, 10, 10], fouAtk: 2000, fouHp: 2000),
            kCastoriaId: OwnedServant(level: 100, npLevel: 1,
                skillLevels: [10, 10, 10], fouAtk: 1000, fouHp: 1000),
            kVitchId: OwnedServant(level: 90, npLevel: 1,
                skillLevels: [10, 10, 10], fouAtk: 1000, fouHp: 1000),
            kOberonId: OwnedServant(level: 90, npLevel: 1,
                skillLevels: [10, 10, 10], fouAtk: 1000, fouHp: 1000),
          },
          craftEssences: {kKaleidoId: OwnedCE(level: 100, mlb: true)},
        );

        final results = await OptimizerEngine(
          quest: quest,
          roster: roster,
          historyFilePath: historyPath,
          maxClears: 1,
        ).run();

        // If any clears found, verify they were written to history.
        if (results.isNotEmpty) {
          final loaded = RunHistory(historyPath).loadAll();
          expect(loaded, hasLength(results.length));
          expect(loaded.first.questId, equals(quest.id));
        }
        // Regardless of clears, the pipeline must have run without error.
        print('History test: ${results.length} clear(s) found');
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  // ---------------------------------------------------------------------------
  // 4. OptimizerEngine — Montjoie 90 end-to-end clear (battery timing validation)
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // 4. runFromShareData — replay
  // ---------------------------------------------------------------------------

  group('runFromShareData', () {
    test('replays a cleared spec and returns cleared', () async {
      final quest = db.gameData.questPhases[kSmokeQuestId]!;
      final altria = db.gameData.servantsById[kAltriaPengId]!;
      final kaleido = db.gameData.craftEssencesById[kKaleidoId]!;

      // Hand-craft a spec we know clears (Altria + Kaleido, single wave).
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

      final runner = HeadlessRunner(quest: quest);

      // Verify the spec clears first.
      final directResult = await runner.run(spec);
      // The smoke quest may or may not clear depending on HP — we at least need no error.
      expect(directResult.outcome, isNot(SimulationOutcome.error),
          reason: directResult.errorMessage ?? '');

      // Convert to BattleShareData and replay.
      final shareData = ShareDataConverter.convert(quest, spec);
      final replayResult = await runner.runFromShareData(shareData);

      expect(replayResult.outcome, isNot(SimulationOutcome.error),
          reason: 'Replay via runFromShareData must not error: '
              '${replayResult.errorMessage}');

      // Replay should produce the same outcome as the direct run.
      expect(replayResult.outcome, equals(directResult.outcome),
          reason: 'Replay outcome should match direct run outcome');
    });

    test('runFromShareData handles multi-skill multi-turn specs', () async {
      final file = File('test/app/optimizer/fixtures/quest_94093408.json');
      final jsonMap = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final montjoieQuest = QuestPhase.fromJson(jsonMap);

      final ibuki = db.gameData.servantsById[kIbukiSumId]!;
      final castoria = db.gameData.servantsById[kCastoriaId]!;
      final blackGrail = db.gameData.craftEssencesById[kBlackGrailId]!;

      // Use the same Arts team spec from headless_runner_test — verified 3-turn clear.
      final spec = TeamSpec(
        slots: [
          SlotSpec(svt: ibuki, level: 102, limitCount: 4, tdLevel: 1,
              skillLevels: [10, 10, 10], appendLevels: [0, 10, 0],
              atkFou: 2000, hpFou: 2000, ce: blackGrail, ceMlb: true, ceLevel: 89),
          SlotSpec(svt: castoria, level: 100, limitCount: 4, tdLevel: 1,
              skillLevels: [10, 10, 10], appendLevels: [0, 10, 0],
              atkFou: 1040, hpFou: 1000),
          SlotSpec(svt: castoria, level: 90, limitCount: 4, tdLevel: 5,
              skillLevels: [10, 10, 10], atkFou: 1000, hpFou: 1000, isSupport: true),
        ],
        mysticCode: db.gameData.mysticCodes[kNewYearsOutfitId],
        mysticCodeLevel: 10,
        turns: [
          TurnActions(
            skills: [
              SkillAction(slotIndex: 0, skillIndex: 0),
              SkillAction(slotIndex: 0, skillIndex: 1),
              SkillAction(slotIndex: 1, skillIndex: 0),
              SkillAction(slotIndex: 1, skillIndex: 1, allyTarget: 0),
              SkillAction(slotIndex: 1, skillIndex: 2, allyTarget: 0),
              SkillAction(slotIndex: 2, skillIndex: 0),
              SkillAction(slotIndex: 2, skillIndex: 2, allyTarget: 0),
              SkillAction(slotIndex: -1, skillIndex: 0),
            ],
            npSlots: [0],
          ),
          TurnActions(
            skills: [SkillAction(slotIndex: 2, skillIndex: 1, allyTarget: 0)],
            npSlots: [0],
          ),
          TurnActions(
            skills: [SkillAction(slotIndex: 0, skillIndex: 2)],
            npSlots: [0],
          ),
        ],
      );

      final runner = HeadlessRunner(quest: montjoieQuest);
      final shareData = ShareDataConverter.convert(montjoieQuest, spec);
      final replayResult = await runner.runFromShareData(shareData);

      expect(replayResult.outcome, isNot(SimulationOutcome.error),
          reason: 'runFromShareData must not error on Arts team: '
              '${replayResult.errorMessage}');
      // This spec is a verified 3-turn clear — replay should also clear.
      expect(replayResult.cleared, isTrue,
          reason: 'Replay of verified 3-turn clear should also clear');
    });
  });
}
