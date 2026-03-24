/// Tests for SkillClassifier: profiling, dependency detection, topological sort.
///
/// These tests work directly against game data loaded from the local Chaldea
/// database, so they require initiateForTest() (same as headless_runner_test).
///
/// Key test cases:
///   - profileSkill: time-sensitive vs multi-turn, single-ally vs party-wide
///   - detectDependencies: Elly S1 (downTolerance) → Yaraandoo S2 (resistible)
///   - topoSort: basic ordering, dependency enforcement, cycle detection
import 'package:flutter_test/flutter_test.dart';

import 'package:chaldea/app/optimizer/candidate_to_team_spec/skill_classifier.dart';
import 'package:chaldea/models/models.dart';
import '../../test_init.dart';

// Servant IDs (Chaldea internal IDs — verified against game data collectionNo)
const int kCastoriaId = 504500;    // Altria Caster "Castoria" (collectionNo 339, Caster)
const int kOberonId = 2800100;     // Oberon-Vortigern (collectionNo 352, Pretender)
const int kEllyId = 2800400;       // Elisa the Nine-Tattooed Dragon (collectionNo 353, Pretender)
const int kYaraandooId = 2501200;  // Nuknarea-Yaraandoo (collectionNo 317, Ruler)
const int kWaverId = 501900;       // Zhuge Liang / Lord El-Melloi II "Waver" (collectionNo 37, Caster)

void main() async {
  await initiateForTest();

  // ---------------------------------------------------------------------------
  // profileSkill
  // ---------------------------------------------------------------------------

  group('profileSkill', () {
    test('Castoria S1 (charge + Arts up) is party-wide and schedulable', () {
      final svt = db.gameData.servantsById[kCastoriaId]!;
      final skill = _skill(svt, 1);
      expect(skill, isNotNull);

      final profile = SkillClassifier.profileSkill(skill!, 10);
      expect(profile.targeting, equals(SkillTargeting.partyWide));
      expect(profile.isTimeSensitive, isFalse);
      expect(profile.isSchedulable, isTrue);
    });

    test('Castoria S1 is a battery (chargesNp=true)', () {
      final svt = db.gameData.servantsById[kCastoriaId]!;
      final skill = _skill(svt, 1);
      expect(skill, isNotNull);
      final profile = SkillClassifier.profileSkill(skill!, 10);
      expect(profile.chargesNp, isTrue);
    });

    test('Oberon S1 (party NP dmg up + charge) is partyWide and schedulable', () {
      final svt = db.gameData.servantsById[kOberonId]!;
      final skill = _skill(svt, 1);
      expect(skill, isNotNull);

      final profile = SkillClassifier.profileSkill(skill!, 10);
      expect(profile.targeting, equals(SkillTargeting.partyWide));
      expect(profile.isSchedulable, isTrue);
    });

    test('Oberon S3 (single-ally Buster + crit buffs) is singleAlly and schedulable', () {
      // S3 is the targeted powerup skill — verifying singleAlly detection works.
      final svt = db.gameData.servantsById[kOberonId]!;
      final skill = _skill(svt, 3);
      expect(skill, isNotNull);

      final profile = SkillClassifier.profileSkill(skill!, 10);
      expect(profile.targeting, equals(SkillTargeting.singleAlly));
      expect(profile.isSchedulable, isTrue);
    });

    test('Waver S1 (single-ally NP charge + DEF up) has chargesNp=true and isSchedulable=true', () {
      // Waver S1: Increase NP gauge for one ally (30%) + Increase DEF for one ally.
      // The NP charge component makes this schedulable; DEF up alone would not.
      final svt = db.gameData.servantsById[kWaverId]!;
      final skill = _skill(svt, 1);
      expect(skill, isNotNull);

      final profile = SkillClassifier.profileSkill(skill!, 10);
      expect(profile.chargesNp, isTrue,
          reason: 'Waver S1 has a gainNp function');
      expect(profile.isSchedulable, isTrue,
          reason: 'NP charge is an offensive/battery component');
    });
  });

  // ---------------------------------------------------------------------------
  // detectDependencies — Elly / Yaraandoo interaction
  // ---------------------------------------------------------------------------

  group('detectDependencies', () {
    test('Elly S2 → Yaraandoo S2 dependency is detected', () {
      // Elly S2 (極大宴会・梁山泊): party NP charge + HP up + downTolerance [DEMERIT].
      //   Elly's downTolerance lowers all allies' debuff resistance.
      // Yaraandoo S2 (女王の契約): applies donotSkill [My Fair Soldier] to allies
      //   (a negative/debuff-type buff) which enables their conditional ATK/DEF up.
      //   donotSkill always goes through the resist check, so allies with positive
      //   debuff resistance may partially resist it, causing the ATK/DEF up to not
      //   apply. Elly S2 must precede Yaraandoo S2 so the seal reliably lands.
      final ellySvt = db.gameData.servantsById[kEllyId];
      final yaraSvt = db.gameData.servantsById[kYaraandooId];

      if (ellySvt == null || yaraSvt == null) {
        markTestSkipped('Elly ($kEllyId) or Yaraandoo ($kYaraandooId) not in game data');
        return;
      }

      final ellyS2 = _skill(ellySvt, 2)!;
      final yaraS2 = _skill(yaraSvt, 2)!;

      // Elly in slot 0, Yaraandoo in slot 2
      final skills = [(0, ellyS2, 10), (2, yaraS2, 10)];
      final deps = SkillClassifier.detectDependencies(skills);

      final ellyRef = (0, ellyS2.svt.num - 1);
      final yaraRef = (2, yaraS2.svt.num - 1);
      expect(
        deps.any((d) => d.before == ellyRef && d.after == yaraRef),
        isTrue,
        reason: 'Elly S2 (downTolerance) must precede Yaraandoo S2 (donotSkill on allies)',
      );
    });

    test('returns empty list when no downTolerance skills present', () {
      final waver = db.gameData.servantsById[kWaverId]!;
      final s1 = _skill(waver, 1);
      final s2 = _skill(waver, 2);
      if (s1 == null || s2 == null) {
        markTestSkipped('Waver ($kWaverId) skills not found');
        return;
      }

      final deps = SkillClassifier.detectDependencies([
        (0, s1, 10),
        (0, s2, 10),
      ]);
      expect(deps, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // topoSort
  // ---------------------------------------------------------------------------

  group('topoSort', () {
    test('no deps — returns skills in original order', () {
      final List<SkillRef> refs = [(0, 0), (0, 1), (1, 0)];
      final sorted = SkillClassifier.topoSort(refs, []);
      expect(sorted, equals(refs));
    });

    test('single dep — after comes after before', () {
      final List<SkillRef> refs = [(0, 0), (1, 0), (2, 0)];
      final deps = [SkillDep((0, 0), (2, 0))];
      final sorted = SkillClassifier.topoSort(refs, deps);
      expect(sorted, isNotNull);
      final idxBefore = sorted!.indexOf((0, 0));
      final idxAfter = sorted.indexOf((2, 0));
      expect(idxBefore, lessThan(idxAfter));
    });

    test('reversed input with dep — dep forces correct order', () {
      final List<SkillRef> refs = [(2, 0), (0, 0)];
      final deps = [SkillDep((0, 0), (2, 0))];
      final sorted = SkillClassifier.topoSort(refs, deps);
      expect(sorted, isNotNull);
      expect(sorted!.first, equals((0, 0)));
      expect(sorted.last, equals((2, 0)));
    });

    test('cycle returns null', () {
      final List<SkillRef> refs = [(0, 0), (1, 0)];
      final deps = [
        SkillDep((0, 0), (1, 0)),
        SkillDep((1, 0), (0, 0)), // cycle
      ];
      expect(SkillClassifier.topoSort(refs, deps), isNull);
    });

    test('dep referencing skill not in set is ignored', () {
      final List<SkillRef> refs = [(0, 0), (0, 1)];
      final deps = [SkillDep((99, 0), (0, 1))];
      final sorted = SkillClassifier.topoSort(refs, deps);
      expect(sorted, isNotNull);
      expect(sorted!.length, equals(2));
    });
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Gets the active skill at slot [num] (1/2/3) for a servant (NA region).
NiceSkill? _skill(Servant svt, int num) {
  final candidates = svt.groupedActiveSkills[num];
  if (candidates == null || candidates.isEmpty) return null;
  return svt.getDefaultSkill(candidates, Region.na);
}
