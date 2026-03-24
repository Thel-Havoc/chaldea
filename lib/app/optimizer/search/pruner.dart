/// Pruner — fast pre-simulation gates that eliminate impossible CandidateTeams.
///
/// Both gates compute optimistic upper bounds: they assume all available charge
/// or buffs can be directed to one attacker in the best possible way.
/// This means: if a team fails a gate, it is GENUINELY impossible — the gate
/// never prunes a valid team.
///
/// Gate 1 — NP charge check (pure arithmetic, ~1µs per candidate):
///   Can any attacker in the team reach 100% starting NP gauge?
///   Sources: CE NP charge + Append 2 + all team skill batteries + MC battery.
///   Optimistic: assumes all charge can be directed to one attacker on one turn.
///
/// Gate 2 — Damage estimate (skill scan, ~10µs per candidate):
///   Can the team's NP damage clear each wave's hardest enemy?
///   Uses the full damage formula constants (attackRate=0.23, card correction,
///   class attack rate, class advantage) plus five buff categories scanned from
///   all team members' skills:
///     - ATK up        (BuffAction.atk)
///     - Card up       (BuffAction.commandAtk — covers Buster/Arts/Quick up)
///     - NP damage up  (BuffAction.npdamage)
///     - General dmg   (BuffAction.damage — trait-independent bonus damage)
///     - Special dmg   (BuffAction.damageIndividuality — trait-gated, counted
///                       optimistically regardless of enemy traits)
///   This covers most of the missing multipliers for high-HP nodes (1M+ HP
///   bosses typically require trait damage like Ibuki's Demonic bonus).
///   Card buff and NP/general/special dmg buffs are combined per the formula:
///     cardTerm × (1 + atkBuff) × (1 + npDmgBuff + genDmgBuff) × (1 + specialDmg)
///
/// See notes/design_decisions.md §"Optimizer Search Strategy".
library;

import 'dart:math';

import 'package:chaldea/models/models.dart';

import '../roster/user_roster.dart';
import 'enumerator.dart';

// ---------------------------------------------------------------------------
// FuncType set for NP-charge functions (mirrors SkillClassifier._kGainNpFuncTypes)
// ---------------------------------------------------------------------------

const Set<FuncType> _kGainNpFuncTypes = {
  FuncType.gainNp,
  FuncType.gainNpFromTargets,
  FuncType.gainNpBuffIndividualSum,
  FuncType.gainNpIndividualSum,
  FuncType.gainNpTargetSum,
  FuncType.gainNpFromOtherUsedNpValue,
  FuncType.gainNpCriticalstarSum,
};

// ---------------------------------------------------------------------------
// Pruner
// ---------------------------------------------------------------------------

class Pruner {
  final QuestPhase quest;
  final UserRoster roster;

  const Pruner({required this.quest, required this.roster});

  /// Returns true if [candidate] passes both gates and should be simulated.
  bool passes(CandidateTeam candidate) {
    return _passesGate1(candidate) && _passesGate2(candidate);
  }

  // =========================================================================
  // Gate 1: NP charge
  // =========================================================================

  bool _passesGate1(CandidateTeam candidate) {
    final svtIds = _allSvtIds(candidate);
    final ceIds = _allCeIds(candidate);

    // Sum all skill-based NP charge from every team member.
    // Optimistic: assume all can be directed to the best attacker in one turn.
    int totalSkillCharge = 0;
    for (final svtId in svtIds) {
      final svt = db.gameData.servantsById[svtId];
      if (svt == null) continue;
      final levels = _skillLevels(svtId);
      for (int si = 0; si < min(svt.skills.length, 3); si++) {
        totalSkillCharge += _skillNpCharge(svt.skills[si], levels[si]);
      }
    }

    // MC NP charge.
    final mcCharge = _mcNpCharge(candidate.mysticCodeId, candidate.mysticCodeLevel);

    // For each potential attacker, check if they can reach 100% NP.
    for (int i = 0; i < svtIds.length; i++) {
      final svtId = svtIds[i];
      final svt = db.gameData.servantsById[svtId];
      if (svt == null || !_isAttacker(svt)) continue;

      final ceCharge = _ceNpCharge(ceIds[i]);
      final appendCharge = _append2Charge(svtId, svt);
      if (ceCharge + appendCharge + totalSkillCharge + mcCharge >= 100) {
        return true;
      }
    }

    return false;
  }

  // =========================================================================
  // Gate 2: Damage estimate
  // =========================================================================

  bool _passesGate2(CandidateTeam candidate) {
    final svtIds = _allSvtIds(candidate);
    final ceIds = _allCeIds(candidate);

    // Collect optimistic team buffs (sum all, assume all land on the attacker).
    final teamBufs = _collectTeamBuffs(svtIds, ceIds);

    // Game constant: base attack rate (230/1000 = 0.23).
    final gameAttackRate = db.gameData.constData.constants.attackRate;

    for (final stage in quest.stages) {
      if (stage.enemies.isEmpty) continue;

      bool waveCanBeCleared = false;

      for (int i = 0; i < svtIds.length; i++) {
        final svtId = svtIds[i];
        final svt = db.gameData.servantsById[svtId];
        if (svt == null || !_isAttacker(svt)) continue;

        final td = svt.groupedNoblePhantasms[1]?.firstOrNull;
        if (td == null) continue;

        final damageFunc =
            td.functions.where((f) => f.funcType.isDamageNp).firstOrNull;
        if (damageFunc == null) continue;

        // NP level: actual for owned servants, NP5 for borrowed support.
        final ownedSvt = roster.servants[svtId];
        final npLevel = (ownedSvt?.npLevel ?? 5).clamp(1, 5);
        final npLvIdx = (npLevel - 1).clamp(0, damageFunc.svals.length - 1);
        final npRate = damageFunc.svals[npLvIdx].Value ?? 0;
        if (npRate == 0) continue;

        // ATK: max stat + Fou. For support assume +1000 Fou.
        final fouAtk = ownedSvt?.fouAtk ?? 1000;
        final atk = svt.atkMax + fouAtk;

        // Card correction (NP card type at chain position 1).
        final cardAdj =
            db.gameData.constData.cardInfo[td.card]?[1]?.adjustAtk ?? 1000;

        // Class-specific attack rate (e.g., Berserker = 1100).
        final classAtkRate =
            db.gameData.constData.classInfo[svt.classId]?.attackRate ?? 1000;

        // Single-target NPs cannot clear multi-enemy waves — skip them.
        final isAoe = damageFunc.funcTargetType == FuncTargetType.enemyAll ||
            damageFunc.funcTargetType == FuncTargetType.enemyFull;
        if (stage.enemies.length > 1 && !isAoe) continue;

        // Check if this attacker can kill every enemy in this wave.
        bool canClearWave = true;
        for (final enemy in stage.enemies) {
          final classAdv = db.gameData.constData
              .getClassIdRelation(svt.classId, enemy.svt.classId);

          final estDmg = _estimateDamage(
            atk: atk,
            npRate: npRate,
            cardAdj: cardAdj,
            gameAttackRate: gameAttackRate,
            classAtkRate: classAtkRate,
            classAdv: classAdv,
            bufs: teamBufs,
          );

          if (estDmg < enemy.hp) {
            canClearWave = false;
            break;
          }
        }

        if (canClearWave) {
          waveCanBeCleared = true;
          break;
        }
      }

      if (!waveCanBeCleared) return false;
    }

    return true;
  }

  // =========================================================================
  // Damage estimate helper
  // =========================================================================

  /// Simplified FGO damage formula (constant terms only; no random, no crit,
  /// no defense buffs, no overkill). Matches battle_utils.dart structure:
  ///
  ///   atk × (npRate/1000) × cardTerm × classAtkRate × classAdv
  ///       × gameAttackRate × (1 + atkBuff) × (1 + npDmgBuff + genDmgBuff)
  ///       × (1 + specialDmgBuff)
  ///
  /// Where cardTerm = (cardAdj/1000) × (1 + cardBuff/1000).
  int _estimateDamage({
    required int atk,
    required int npRate,
    required int cardAdj,
    required int gameAttackRate,
    required int classAtkRate,
    required int classAdv,
    required _TeamBufs bufs,
  }) {
    return (atk *
            (npRate / 1000.0) *
            (cardAdj / 1000.0) *
            ((1000 + bufs.cardBuff) / 1000.0) *
            (classAtkRate / 1000.0) *
            (classAdv / 1000.0) *
            (gameAttackRate / 1000.0) *
            ((1000 + bufs.atkBuff) / 1000.0) *
            ((1000 + bufs.npDmgBuff + bufs.genDmgBuff) / 1000.0) *
            ((1000 + bufs.specialDmgBuff) / 1000.0))
        .floor();
  }

  // =========================================================================
  // Team buff collection
  // =========================================================================

  _TeamBufs _collectTeamBuffs(List<int> svtIds, List<int?> ceIds) {
    final constData = db.gameData.constData;
    int atkBuff = 0;
    int cardBuff = 0;
    int npDmgBuff = 0;
    int genDmgBuff = 0;
    int specialDmgBuff = 0;

    // Servant skills.
    for (final svtId in svtIds) {
      final svt = db.gameData.servantsById[svtId];
      if (svt == null) continue;
      final levels = _skillLevels(svtId);
      for (int si = 0; si < min(svt.skills.length, 3); si++) {
        final skill = svt.skills[si];
        final lvIdx = (levels[si] - 1).clamp(0, 9);
        for (final func in skill.functions) {
          if (!_isAddStateFuncType(func.funcType)) continue;
          if (!_appliesToAlly(func.funcTargetType)) continue;
          for (final buff in func.buffs) {
            if (lvIdx >= func.svals.length) continue;
            final val = func.svals[lvIdx].Value ?? 0;
            if (val <= 0) continue;
            if (constData.checkPlusType(BuffAction.atk, buff.type)) {
              atkBuff += val;
            }
            if (constData.checkPlusType(BuffAction.commandAtk, buff.type)) {
              cardBuff += val;
            }
            if (constData.checkPlusType(BuffAction.npdamage, buff.type)) {
              npDmgBuff += val;
            }
            if (constData.checkPlusType(BuffAction.damage, buff.type)) {
              genDmgBuff += val;
            }
            if (constData.checkPlusType(BuffAction.damageIndividuality, buff.type)) {
              specialDmgBuff += val;
            }
          }
        }
      }
    }

    // CE skills — mirror BattleCEData.activateCE: use getActivatedSkills to
    // pick the correct MLB vs non-MLB skill variant, then read svals directly.
    for (final ceId in ceIds) {
      if (ceId == null) continue;
      final ce = db.gameData.craftEssencesById[ceId];
      if (ce == null) continue;
      final ownedCe = roster.craftEssences[ceId];
      final mlb = ownedCe?.mlb ?? false;
      final skillGroups = ce.getActivatedSkills(mlb);
      for (final ceSkills in skillGroups.values) {
        for (final skill in ceSkills) {
          for (final func in skill.functions) {
            if (!_isAddStateFuncType(func.funcType)) continue;
            for (final buff in func.buffs) {
              final val = func.svals.lastOrNull?.Value ?? 0;
              if (val <= 0) continue;
              if (constData.checkPlusType(BuffAction.npdamage, buff.type)) {
                npDmgBuff += val;
              }
              if (constData.checkPlusType(BuffAction.atk, buff.type)) {
                atkBuff += val;
              }
              if (constData.checkPlusType(BuffAction.commandAtk, buff.type)) {
                cardBuff += val;
              }
              if (constData.checkPlusType(BuffAction.damage, buff.type)) {
                genDmgBuff += val;
              }
            }
          }
        }
      }
    }

    return _TeamBufs(
      atkBuff: atkBuff,
      cardBuff: cardBuff,
      npDmgBuff: npDmgBuff,
      genDmgBuff: genDmgBuff,
      specialDmgBuff: specialDmgBuff,
    );
  }

  // =========================================================================
  // Gate 1 helpers
  // =========================================================================

  /// NP charge (0–100) from a single skill at [level] (1-10).
  int _skillNpCharge(NiceSkill skill, int level) {
    final lvIdx = (level - 1).clamp(0, 9);
    int total = 0;
    for (final func in skill.functions) {
      if (!_kGainNpFuncTypes.contains(func.funcType)) continue;
      if (!_appliesToAlly(func.funcTargetType)) continue;
      if (lvIdx >= func.svals.length) continue;
      final val = func.svals[lvIdx].Value ?? 0;
      total += val ~/ 100; // svals use 0–10000 scale; /100 → 0–100%
    }
    return total;
  }

  /// NP charge from a CE (0–100).
  int _ceNpCharge(int? ceId) {
    if (ceId == null) return 0;
    final ownedCe = roster.craftEssences[ceId];
    final ce = db.gameData.craftEssencesById[ceId];
    if (ownedCe == null || ce == null) return 0;

    // Mirror BattleCEData.activateCE: use getActivatedSkills to pick the
    // correct MLB vs non-MLB skill variant, then read svals directly.
    final skillGroups = ce.getActivatedSkills(ownedCe.mlb);
    for (final skills in skillGroups.values) {
      for (final skill in skills) {
        for (final func in skill.functions) {
          if (!_kGainNpFuncTypes.contains(func.funcType)) continue;
          final val = func.svals.firstOrNull?.Value;
          if (val != null) return val ~/ 100;
        }
      }
    }
    return 0;
  }

  /// NP charge from Append 2 (the starting NP charge append skill).
  int _append2Charge(int svtId, Servant svt) {
    final ownedSvt = roster.servants[svtId];
    if (ownedSvt == null) return 0;
    // appendLevels[1] = Append 2 (index 1 = second append, 0 = unlocked but level 1)
    final appendLevel = ownedSvt.appendLevels.length > 1
        ? ownedSvt.appendLevels[1]
        : 0;
    if (appendLevel <= 0) return 0;
    if (svt.appendPassive.length <= 1) return 0;

    final appendSkill = svt.appendPassive[1].skill;
    return _skillNpCharge(appendSkill, appendLevel);
  }

  /// NP charge from the Mystic Code's skills (sum across all MC skills).
  int _mcNpCharge(int? mcId, int mcLevel) {
    if (mcId == null) return 0;
    final mc = db.gameData.mysticCodes[mcId];
    if (mc == null) return 0;

    int total = 0;
    final lvIdx = (mcLevel - 1).clamp(0, 9);
    for (final skill in mc.skills) {
      for (final func in skill.functions) {
        if (!_kGainNpFuncTypes.contains(func.funcType)) continue;
        if (!_appliesToAlly(func.funcTargetType)) continue;
        if (lvIdx >= func.svals.length) continue;
        final val = func.svals[lvIdx].Value ?? 0;
        total += val ~/ 100;
      }
    }
    return total;
  }

  // =========================================================================
  // Shared helpers
  // =========================================================================

  List<int> _allSvtIds(CandidateTeam candidate) =>
      [candidate.supportSvtId, ...candidate.playerSvtIds];

  List<int?> _allCeIds(CandidateTeam candidate) =>
      [candidate.supportCeId, ...candidate.playerCeIds];

  /// Skill levels for [svtId]: player servants use their roster data,
  /// support servants are assumed to be max level (10/10/10).
  List<int> _skillLevels(int svtId) {
    final ownedSvt = roster.servants[svtId];
    if (ownedSvt != null) return ownedSvt.skillLevels;
    return const [10, 10, 10]; // support: assume max skills
  }

  /// True if this servant has a damageNp-type Noble Phantasm.
  bool _isAttacker(Servant svt) {
    final td = svt.groupedNoblePhantasms[1]?.firstOrNull;
    if (td == null) return false;
    return td.functions.any((f) => f.funcType.isDamageNp);
  }

  /// True if the function targets allies (self, one ally, party-wide, etc.).
  /// Used to skip enemy-targeting effects when counting buffs.
  static bool _appliesToAlly(FuncTargetType t) {
    return t == FuncTargetType.self ||
        t == FuncTargetType.ptOne ||
        t == FuncTargetType.ptAnother ||
        t == FuncTargetType.ptOther ||
        t == FuncTargetType.ptOtherFull ||
        t == FuncTargetType.ptAll ||
        t == FuncTargetType.ptFull ||
        t.needNormalOneTarget;
  }

  static bool _isAddStateFuncType(FuncType t) =>
      t == FuncType.addState || t == FuncType.addStateShort;
}

// ---------------------------------------------------------------------------
// _TeamBufs — collected damage buff totals for the whole team
// ---------------------------------------------------------------------------

class _TeamBufs {
  /// Sum of all ATK up buff values from team skills (BuffAction.atk).
  final int atkBuff;

  /// Sum of all card-type up buff values (BuffAction.commandAtk).
  /// Covers Buster up, Arts up, Quick up — counted optimistically regardless
  /// of whether the attacker's NP card type matches.
  final int cardBuff;

  /// Sum of all NP damage up buff values (BuffAction.npdamage).
  final int npDmgBuff;

  /// Sum of all general damage up buff values (BuffAction.damage).
  final int genDmgBuff;

  /// Sum of all trait-gated special damage up values (BuffAction.damageIndividuality).
  /// Counted optimistically: assumed to always apply regardless of enemy traits.
  final int specialDmgBuff;

  const _TeamBufs({
    required this.atkBuff,
    required this.cardBuff,
    required this.npDmgBuff,
    required this.genDmgBuff,
    required this.specialDmgBuff,
  });
}
