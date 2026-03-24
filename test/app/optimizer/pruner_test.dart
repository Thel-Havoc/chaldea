/// Tests for Pruner: Gate 1 (NP charge) and Gate 2 (damage estimate).
///
/// Test groups:
///   1. Gate 1 (NP charge) — correctly passes/rejects teams based on charge.
///   2. Gate 2 (damage estimate) — correctly passes/rejects teams based on damage.
///   3. Pruner efficiency — measures before/after candidate counts on a real quest
///      to verify the pruner is actually eliminating work.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/optimizer/roster/user_roster.dart';
import 'package:chaldea/app/optimizer/search/enumerator.dart';
import 'package:chaldea/app/optimizer/search/pruner.dart';
import 'package:chaldea/models/models.dart';
import '../../test_init.dart';

// ---------------------------------------------------------------------------
// Shared constants (same IDs used across optimizer tests)
// ---------------------------------------------------------------------------

const int kSmokeQuestId = 9300040603; // single-wave Sky Caster quest

const int kAltriaPengId  = 100100;  // Altria Pendragon (AoE Saber)
const int kCastoriaId    = 504500;  // Altria Caster (Castoria)
const int kIbukiSumId    = 704300;  // Summer Ibuki-Douji (AoE Arts)
const int kVitchId       = 604200;  // Koyanskaya of Light
const int kMelusineId    = 304800;  // Mélusine (AoE Buster)
const int kOberonId      = 2800100; // Oberon-Vortigern
const int kIoriId        = 106000;  // Miyamoto Iori (single-target Arts Saber)
const int kAnraId        = 1100100; // Angra Mainyu (AoE, very weak stats)

const int kMerlinId      = 500800;  // Merlin (buff support, NP has no damage)
const int kWaverId       = 501900;  // Waver / Zhuge Liang (buff support, NP has no damage)

const int kKaleidoId     = 9400340; // Kaleidoscope (100% NP start, MLB)
const int kBlackGrailId  = 9400480; // Black Grail (50% NP start + NP dmg up)
const int kBellaLisaId   = 9403690; // Bella Lisa (non-combat CE — no battle effect)

const int kNewYearsOutfitId = 260;
const int kPlugSuitId       = 210;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Full roster: strong Meta servants + intentionally weak ones to exercise
/// the pruner's elimination logic.
UserRoster _buildFullRoster() => UserRoster(
      profileName: 'pruner_test',
      servants: {
        // ── Strong / meta ──────────────────────────────────────────────────
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
        // ── Pure-buff supports (no damaging NP) ───────────────────────────
        // Teams of Iori + any combination of these fail Gate 2 because no
        // servant in the team has an AoE damaging NP to clear multi-enemy waves.
        kMerlinId: OwnedServant(
          level: 90, npLevel: 1, skillLevels: [10, 10, 10],
          fouAtk: 1000, fouHp: 1000,
        ),
        kWaverId: OwnedServant(
          level: 90, npLevel: 1, skillLevels: [10, 10, 10],
          fouAtk: 1000, fouHp: 1000,
        ),
        // ── Intentionally weak — should be pruned on hard nodes ────────────
        kIoriId: OwnedServant(
          level: 80, npLevel: 1, skillLevels: [10, 10, 10],
          appendLevels: [0, 10, 0], fouAtk: 1000, fouHp: 1000,
        ),
        kAnraId: OwnedServant(
          level: 60, npLevel: 1, skillLevels: [1, 1, 1],
          fouAtk: 0, fouHp: 0,
        ),
      },
      craftEssences: {
        kKaleidoId:    OwnedCE(level: 100, mlb: true),
        kBlackGrailId: OwnedCE(level: 89,  mlb: true),
        kBellaLisaId:  OwnedCE(level: 1,   mlb: false), // no combat effect
      },
      mysticCodes: {kNewYearsOutfitId: 10, kPlugSuitId: 8},
    );

void main() async {
  await initiateForTest();

  // ---------------------------------------------------------------------------
  // 1. Gate 1: NP charge
  // ---------------------------------------------------------------------------

  group('Pruner Gate 1 (NP charge)', () {
    test('passes team where CE gives full charge (Montjoie quest)', () {
      // Use Montjoie 90 so Gate 2 also passes (Ibuki + Castoria buffs → enough
      // damage). This validates the full pipeline including CE charge detection.
      final file = File('test/app/optimizer/fixtures/quest_94093408.json');
      final quest =
          QuestPhase.fromJson(jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);
      final roster = UserRoster(
        profileName: 'test',
        servants: {
          kIbukiSumId: OwnedServant(
            level: 102, npLevel: 1, skillLevels: [10, 10, 10],
            appendLevels: [0, 0, 0], // no Append 2 — relying on MLB Kaleido
            fouAtk: 2000, fouHp: 2000,
          ),
        },
        craftEssences: {kKaleidoId: OwnedCE(level: 100, mlb: true)},
      );
      final pruner = Pruner(quest: quest, roster: roster);

      // Ibuki + MLB Kaleido (100% NP) + double Castoria support buffs.
      // Gate 1: Kaleido alone gives 100% → passes even without skill batteries.
      // Gate 2: Ibuki + Castoria ATK/NP damage buffs → more than enough damage.
      final candidate = CandidateTeam(
        supportSvtId: kCastoriaId,
        playerSvtIds: [kIbukiSumId, kCastoriaId],
        playerCeIds: [kKaleidoId, null],
        mysticCodeId: kNewYearsOutfitId,
        mysticCodeLevel: 10,
      );

      expect(pruner.passes(candidate), isTrue,
          reason: 'MLB Kaleido gives 100% NP — Gate 1 must pass; '
              'Ibuki + Castoria buffs clear Montjoie — Gate 2 must pass');
    });

    test('rejects team with no charge source (Montjoie quest)', () {
      final file = File('test/app/optimizer/fixtures/quest_94093408.json');
      final quest =
          QuestPhase.fromJson(jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);
      // Roster with no CE, no Append 2, and minimal skill levels.
      final roster = UserRoster(
        profileName: 'test',
        servants: {
          kAltriaPengId: OwnedServant(
            level: 90, npLevel: 1, skillLevels: [1, 1, 1],
            fouAtk: 1000, fouHp: 1000,
          ),
        },
      );
      final pruner = Pruner(quest: quest, roster: roster);

      // Altria with no CE, no Append 2, support Oberon (S3 gives ~20% party NP
      // at max). Total reachable charge well under 100%. Gate 1 must reject.
      final candidate = CandidateTeam(
        supportSvtId: kOberonId,
        playerSvtIds: [kAltriaPengId],
        playerCeIds: [null],
      );

      expect(pruner.passes(candidate), isFalse,
          reason: 'No CE, no Append 2, minimal skills → total charge < 100%');
    });
  });

  // ---------------------------------------------------------------------------
  // 2. Gate 2: damage estimate
  // ---------------------------------------------------------------------------

  group('Pruner Gate 2 (damage estimate)', () {
    test('passes Ibuki + double Castoria against Montjoie 90', () {
      final file = File('test/app/optimizer/fixtures/quest_94093408.json');
      final quest =
          QuestPhase.fromJson(jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);
      final roster = _buildFullRoster();
      final pruner = Pruner(quest: quest, roster: roster);

      // Arts team: Summer Ibuki + 2× Castoria. With Append 2 + Black Grail
      // + Castoria batteries Ibuki can reach 100% NP. Ibuki + Castoria buffs
      // should far exceed even the hardest wave's HP.
      final candidate = CandidateTeam(
        supportSvtId: kCastoriaId,
        playerSvtIds: [kIbukiSumId, kCastoriaId],
        playerCeIds: [kBlackGrailId, null],
        mysticCodeId: kNewYearsOutfitId,
        mysticCodeLevel: 10,
      );

      expect(pruner.passes(candidate), isTrue,
          reason: 'Ibuki + double Castoria with Black Grail must pass both gates '
              'on Montjoie 90');
    });

    test('rejects single-target attacker on multi-enemy wave (Iori + Montjoie 90)', () {
      // Iori has a single-target NP. Every wave of Montjoie 90 has multiple
      // enemies. Gate 2 must reject any candidate where the only potential
      // attacker is single-target (AoE check added to Gate 2).
      final file = File('test/app/optimizer/fixtures/quest_94093408.json');
      final quest =
          QuestPhase.fromJson(jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);
      final roster = UserRoster(
        profileName: 'test',
        servants: {
          kIoriId: OwnedServant(
            level: 80, npLevel: 1, skillLevels: [10, 10, 10],
            appendLevels: [0, 10, 0], fouAtk: 1000, fouHp: 1000,
          ),
        },
        craftEssences: {kKaleidoId: OwnedCE(level: 100, mlb: true)},
      );
      final pruner = Pruner(quest: quest, roster: roster);

      // Iori + MLB Kaleido passes Gate 1 (100% charge from CE alone).
      // Gate 2 must reject: Iori's NP is single-target and every wave has
      // multiple enemies — no single servant in this team can clear any wave.
      final candidate = CandidateTeam(
        supportSvtId: kCastoriaId, // support: NP charge only, minimal damage
        playerSvtIds: [kIoriId],
        playerCeIds: [kKaleidoId],
      );

      expect(pruner.passes(candidate), isFalse,
          reason: 'Single-target NP cannot clear multi-enemy waves — '
              'Gate 2 must reject Iori on Montjoie 90');
    });

    test('passes Mélusine + double Vitch against Montjoie 90', () {
      final file = File('test/app/optimizer/fixtures/quest_94093408.json');
      final quest =
          QuestPhase.fromJson(jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);
      final roster = UserRoster(
        profileName: 'test',
        servants: {
          kMelusineId: OwnedServant(
            level: 102, npLevel: 1, skillLevels: [10, 10, 10],
            fouAtk: 2000, fouHp: 2000, limitCount: 2,
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
        craftEssences: {kBlackGrailId: OwnedCE(level: 89, mlb: true)},
        mysticCodes: {kPlugSuitId: 8},
      );
      final pruner = Pruner(quest: quest, roster: roster);

      final candidate = CandidateTeam(
        supportSvtId: kVitchId,
        playerSvtIds: [kMelusineId, kVitchId, kOberonId],
        playerCeIds: [kBlackGrailId, null, null],
        mysticCodeId: kPlugSuitId,
        mysticCodeLevel: 8,
      );

      expect(pruner.passes(candidate), isTrue,
          reason: 'Mélusine + double Vitch + Oberon with Black Grail must pass '
              'both gates on Montjoie 90');
    });
  });

  // ---------------------------------------------------------------------------
  // 3. Pruner efficiency — before vs. after candidate counts
  // ---------------------------------------------------------------------------

  group('Pruner efficiency', () {
    test('reports candidate survival rate on Montjoie 90 with mixed roster', () {
      // Informational: measures how many candidates survive for a mixed roster
      // that includes both strong (Ibuki, Altria) and weak (Iori, Angra) servants.
      //
      // The roster contains Merlin and Waver (pure-buff supports — NPs have
      // isDamageNp=false) alongside Iori (single-target NP). Teams composed of
      // only Iori + Merlin/Waver have no AoE attacker and fail Gate 2.
      // Teams that include Ibuki, Altria, Mélusine, or Vitch pass (AoE NPs).
      // This means some enumerator-generated candidates are pruned, so the
      // efficiency assertion surviving.length < all.length must hold.
      final file = File('test/app/optimizer/fixtures/quest_94093408.json');
      final quest =
          QuestPhase.fromJson(jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);
      final roster = _buildFullRoster();

      final enumerator = Enumerator(roster: roster, quest: quest);
      final all = enumerator.candidates().toList();

      final pruner = Pruner(quest: quest, roster: roster);
      final surviving = all.where(pruner.passes).toList();

      final pct = all.isEmpty ? 0 : (surviving.length * 100 ~/ all.length);
      print(
        'Pruner efficiency on Montjoie 90 (mixed roster): '
        '${surviving.length} / ${all.length} candidates survive ($pct%)',
      );

      // At least one valid team must survive.
      expect(surviving, isNotEmpty,
          reason: 'Roster contains valid clearing teams — '
              'at least one candidate must survive pruning');
      // Pruner must actually eliminate some candidates (Iori + pure-buff support
      // teams have no AoE attacker → Gate 2 rejects them).
      expect(surviving.length, lessThan(all.length),
          reason: 'Teams of Iori + Merlin/Waver have no AoE NP — '
              'pruner must reject at least some candidates');
    });

    test('Gate 1 rejects a team with no charge pathway on a hard quest', () {
      // Pruner adds the most value for weaker rosters. Directly verify that a
      // hand-crafted "bad" candidate — pure supports + attacker with no CE and
      // no Append 2 — is correctly rejected by Gate 1.
      final file = File('test/app/optimizer/fixtures/quest_94093408.json');
      final quest =
          QuestPhase.fromJson(jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);

      // Roster: Altria with no CE, no Append 2, skill levels [1,1,1].
      // Support is Oberon (no ally battery). Combined NP charge from skills
      // will be well below 100%.
      final roster = UserRoster(
        profileName: 'test_weak',
        servants: {
          kAltriaPengId: OwnedServant(
            level: 90, npLevel: 1, skillLevels: [1, 1, 1],
            fouAtk: 1000, fouHp: 1000,
          ),
        },
      );
      final pruner = Pruner(quest: quest, roster: roster);

      final candidate = CandidateTeam(
        supportSvtId: kOberonId,
        playerSvtIds: [kAltriaPengId],
        playerCeIds: [null], // no CE
      );

      // Oberon S3 at level 10 charges party NP by 20%, which combined with
      // Altria's own skills (Charisma/Instinct/Burst — none charge NP) and
      // no CE gives well under 100%. Gate 1 must reject this.
      expect(pruner.passes(candidate), isFalse,
          reason: 'No CE, no Append 2, minimal skills → total charge < 100%');
    });
  });
}
