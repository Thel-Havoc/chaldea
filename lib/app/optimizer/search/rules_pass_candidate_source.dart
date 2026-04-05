/// RulesPassCandidateSource — candidate generation strategy for the Rules Pass.
///
/// Uses [Enumerator.servantCombos] to get servant+MC combinations, then applies
/// smart CE selection per-team before pruning:
///
///   Buster teams (support is Oberon / Vitch / Merlin):
///     Computes the minimum starting NP charge the attacker still needs from a
///     CE (i.e., 100 − Append2 − best own battery skill at current level).
///     Tries two CE assignments per combo:
///       (a) The cheapest CE whose charge ≥ that minimum — uses the least NP
///           charge to fire, leaving the largest fraction of the CE budget for
///           secondary effects (NP damage, Buster up, etc.).
///       (b) The CE with the highest NP damage bonus (e.g. Black Grail) — may
///           not be the minimum needed, but maximises burst.
///     Plus the standard "no CE" variant.
///
///   Arts / Quick / Unknown teams (Castoria, Waver, Skadi, other):
///     NP refund is too complex to predict analytically, so we cascade through
///     a few representative CE tiers and let the simulator pick:
///       (a) CE with highest NP damage bonus  (pure damage — Black Grail style)
///       (b) CE with highest NP charge        (full charge — Kaleidoscope style)
///       (c) CE with both charge > 0 AND NP damage > 0 (mixed — Aerial Drive style)
///     Plus the standard "no CE" variant.
///
///   CEs are assigned only to the primary attacker slot to keep the candidate
///   count bounded. Other slots (backline, second frontline) receive null.
///   Deduplication within this source removes any repeated assignments that
///   fall out of the tier logic (e.g. when the min-charge CE == Black Grail).
///
/// See notes/design_decisions.md §"Rules Pass CE Selection".
library;

import 'dart:math';

import 'package:chaldea/models/models.dart';

import '../roster/user_roster.dart';
import 'candidate_source.dart';
import 'enumerator.dart';
import 'pruner.dart';

// ---------------------------------------------------------------------------
// Attacker NP card → team-type classification
// ---------------------------------------------------------------------------

enum _TeamType { buster, arts, quick, unknown }

// ---------------------------------------------------------------------------
// FuncType set for NP-charge functions (mirrors Pruner._kGainNpFuncTypes)
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
// RulesPassCandidateSource
// ---------------------------------------------------------------------------

class RulesPassCandidateSource implements CandidateSource {
  @override
  final List<CandidateTeam> candidates;

  @override
  final int total;

  @override
  final int gate1Blocked;

  @override
  final int gate2Blocked;

  RulesPassCandidateSource._({
    required this.candidates,
    required this.total,
    required this.gate1Blocked,
    required this.gate2Blocked,
  });

  factory RulesPassCandidateSource(QuestPhase quest, UserRoster roster) {
    final pruner = Pruner(quest: quest, roster: roster);
    final enumerator = Enumerator(roster: roster, quest: quest);
    final ceSelector = _RulesCeSelector(roster, quest.logicEventId ?? 0);

    final passed = <CandidateTeam>[];

    for (final combo in enumerator.servantCombos()) {
      for (final ceAssignment in ceSelector.assignments(combo)) {
        final candidate = CandidateTeam(
          supportSvtId: combo.supportSvtId,
          playerSvtIds: combo.playerSvtIds,
          playerCeIds: ceAssignment,
          mysticCodeId: combo.mysticCodeId,
          mysticCodeLevel: combo.mysticCodeLevel,
        );
        if (pruner.passes(candidate)) {
          passed.add(candidate);
        }
      }
    }

    return RulesPassCandidateSource._(
      candidates: passed,
      total: passed.length + pruner.gate1Blocked + pruner.gate2Blocked,
      gate1Blocked: pruner.gate1Blocked,
      gate2Blocked: pruner.gate2Blocked,
    );
  }
}

// ---------------------------------------------------------------------------
// _RulesCeSelector — per-team CE assignment variants
// ---------------------------------------------------------------------------

class _RulesCeSelector {
  final UserRoster roster;

  /// Event ID of the quest being optimised (0 = no event / non-event quest).
  /// When non-zero, CE skills gated to this event ID are included in buff
  /// calculations; event skills for other event IDs are always ignored.
  final int questEventId;

  /// All owned CE IDs sorted by NP charge (highest first).
  late final List<int> _byChargeDesc;

  /// All owned CE IDs sorted by NP damage bonus (highest first).
  late final List<int> _byNpDamageDesc;

  _RulesCeSelector(this.roster, this.questEventId) {
    final ids = roster.craftEssences.keys.toList();
    _byChargeDesc = List.of(ids)
      ..sort((a, b) => _npChargeOf(b) - _npChargeOf(a));
    _byNpDamageDesc = List.of(ids)
      ..sort((a, b) => _npDamageOf(b) - _npDamageOf(a));
  }

  /// Returns the CE assignment variants to try for [combo].
  ///
  /// Each variant is a list parallel to [combo.playerSvtIds] — the CE id for
  /// the primary attacker slot, null for all other slots.
  /// The "no CE" variant (all null) is always included last.
  List<List<int?>> assignments(CandidateTeam combo) {
    final n = combo.playerSvtIds.length;
    final attackerIdx = _primaryAttackerIndex(combo.playerSvtIds);

    final ceOptions = <int>[];

    if (attackerIdx >= 0) {
      final type = _teamType(combo.playerSvtIds[attackerIdx]);
      if (type == _TeamType.buster) {
        _addBusterCeOptions(combo.playerSvtIds[attackerIdx], ceOptions);
      } else {
        _addCascadeCeOptions(ceOptions);
      }
    }

    // Build assignment lists, deduplicating CE IDs.
    final result = <List<int?>>[];
    final seen = <int>{};
    for (final ceId in ceOptions) {
      if (!seen.add(ceId)) continue;
      final assignment = List<int?>.filled(n, null);
      assignment[attackerIdx] = ceId;
      result.add(assignment);
    }

    // Always include the no-CE variant.
    result.add(List.filled(n, null));
    return result;
  }

  // ---------------------------------------------------------------------------
  // Buster CE selection
  // ---------------------------------------------------------------------------

  void _addBusterCeOptions(int attackerSvtId, List<int> out) {
    final minCharge = _minCeChargeNeeded(attackerSvtId);

    // (a) Cheapest CE that still provides enough starting gauge.
    //     Since _byChargeDesc is sorted highest→lowest, lastWhere gives
    //     the lowest-charge CE that still meets the threshold.
    final minChargeCe = _byChargeDesc.lastWhere(
      (id) => _npChargeOf(id) >= minCharge,
      orElse: () => -1,
    );
    if (minChargeCe != -1) out.add(minChargeCe);

    // (b) CE with highest NP damage bonus (Black Grail / equivalent).
    final maxDmgCe = _byNpDamageDesc.firstOrNull;
    if (maxDmgCe != null) out.add(maxDmgCe);
  }

  // ---------------------------------------------------------------------------
  // Arts / Quick / Unknown CE cascade
  // ---------------------------------------------------------------------------

  void _addCascadeCeOptions(List<int> out) {
    // Tier 1: pure damage (Black Grail style — highest NP damage bonus).
    final maxDmgCe = _byNpDamageDesc.firstOrNull;
    if (maxDmgCe != null) out.add(maxDmgCe);

    // Tier 2: full charge (Kaleidoscope style — highest starting NP gauge).
    final fullChargeCe = _byChargeDesc.firstOrNull;
    if (fullChargeCe != null) out.add(fullChargeCe);

    // Tier 3: mixed — the highest-charge CE that also carries an NP damage bonus
    //         (Aerial Drive / Ocean Flier style: partial charge + partial damage).
    final mixedCe = _byChargeDesc.where(
      (id) => _npChargeOf(id) > 0 && _npDamageOf(id) > 0,
    ).firstOrNull;
    if (mixedCe != null) out.add(mixedCe);
  }

  // ---------------------------------------------------------------------------
  // Minimum CE charge needed for Buster attacker to fire on turn 1
  // ---------------------------------------------------------------------------

  /// How much starting NP charge the attacker still needs from a CE so they
  /// can fire on turn 1 (Append 2 + best own battery skill at current level).
  ///
  /// Returns a value in [0, 100]. A result of 0 means the attacker can already
  /// fire on turn 1 without any CE.
  int _minCeChargeNeeded(int svtId) {
    final svt = db.gameData.servantsById[svtId];
    final owned = roster.servants[svtId];
    if (svt == null || owned == null) return 100; // safe fallback: need full charge

    // Append 2 (starting NP gauge passive).
    int appendCharge = 0;
    if (owned.appendLevels.length > 1) {
      final appendLevel = owned.appendLevels[1];
      if (appendLevel > 0 && svt.appendPassive.length > 1) {
        appendCharge = _skillNpCharge(svt.appendPassive[1].skill, appendLevel);
      }
    }

    // Best single-turn charge skill at the player's current level.
    // Only the best skill fires on turn 1, so take max over all three slots.
    int bestSkill = 0;
    for (int i = 0; i < min(svt.skills.length, 3); i++) {
      final level = i < owned.skillLevels.length ? owned.skillLevels[i] : 1;
      bestSkill = max(bestSkill, _skillNpCharge(svt.skills[i], level));
    }

    return (100 - appendCharge - bestSkill).clamp(0, 100);
  }

  // ---------------------------------------------------------------------------
  // Team-type classification
  // ---------------------------------------------------------------------------

  /// Classifies the team type by the attacker's NP card colour.
  _TeamType _teamType(int attackerSvtId) {
    final svt = db.gameData.servantsById[attackerSvtId];
    if (svt == null) return _TeamType.unknown;
    final nps = svt.groupedNoblePhantasms[1] ?? [];
    final card = nps.firstOrNull?.card;
    if (card == null) return _TeamType.unknown;
    if (CardType.isBuster(card)) return _TeamType.buster;
    if (CardType.isArts(card)) return _TeamType.arts;
    if (CardType.isQuick(card)) return _TeamType.quick;
    return _TeamType.unknown;
  }

  // ---------------------------------------------------------------------------
  // Attacker-slot lookup
  // ---------------------------------------------------------------------------

  /// Index of the first attacker-tagged servant in [svtIds], or -1 if none.
  int _primaryAttackerIndex(List<int> svtIds) {
    for (int i = 0; i < svtIds.length; i++) {
      final owned = roster.servants[svtIds[i]];
      if (owned != null && owned.roles.contains(ServantRole.attacker)) return i;
    }
    return -1;
  }

  // ---------------------------------------------------------------------------
  // CE property readers
  // ---------------------------------------------------------------------------

  /// Starting NP charge (0–100) this CE provides.
  ///
  /// Scans regular (non-event-gated) skills first. If [questEventId] is
  /// non-zero, also scans skills gated to that event, which covers event CEs
  /// like Hot Springs Table Tennis that only carry NP charge during an event.
  int _npChargeOf(int ceId) {
    final ownedCe = roster.craftEssences[ceId];
    final ce = db.gameData.craftEssencesById[ceId];
    if (ownedCe == null || ce == null) return 0;

    // Regular (non-event-gated) skills.
    for (final skills in ce.getActivatedSkills(ownedCe.mlb).values) {
      for (final skill in skills) {
        if (_isPurelyEventSkill(skill)) continue;
        for (final func in skill.functions) {
          if (_kGainNpFuncTypes.contains(func.funcType)) {
            final val = func.svals.firstOrNull?.Value;
            if (val != null) return val ~/ 100;
          }
        }
      }
    }

    // Event-gated skills for the current quest's event.
    if (questEventId != 0) {
      for (final skill in ce.eventSkills(questEventId)) {
        for (final func in skill.functions) {
          if (_kGainNpFuncTypes.contains(func.funcType)) {
            final val = func.svals.firstOrNull?.Value;
            if (val != null) return val ~/ 100;
          }
        }
      }
    }

    return 0;
  }

  /// Total NP damage bonus (BuffAction.npdamage) this CE provides (0–10000 scale).
  ///
  /// Scans regular skills first, then event-gated skills for [questEventId]
  /// (when non-zero). This ensures event CEs are ranked correctly for the
  /// quests where their effects actually apply.
  int _npDamageOf(int ceId) {
    final ownedCe = roster.craftEssences[ceId];
    final ce = db.gameData.craftEssencesById[ceId];
    if (ownedCe == null || ce == null) return 0;
    final constData = db.gameData.constData;
    int total = 0;

    void scanSkills(Iterable<NiceSkill> skills) {
      for (final skill in skills) {
        for (final func in skill.functions) {
          if (func.funcType != FuncType.addState &&
              func.funcType != FuncType.addStateShort) { continue; }
          for (final buff in func.buffs) {
            final val = func.svals.lastOrNull?.Value ?? 0;
            if (val > 0 &&
                constData.checkPlusType(BuffAction.npdamage, buff.type)) {
              total += val;
            }
          }
        }
      }
    }

    // Regular (non-event-gated) skills.
    for (final ceSkills in ce.getActivatedSkills(ownedCe.mlb).values) {
      scanSkills(ceSkills.where((s) => !_isPurelyEventSkill(s)));
    }

    // Event-gated skills for the current quest's event.
    if (questEventId != 0) {
      scanSkills(ce.eventSkills(questEventId));
    }

    return total;
  }

  /// True if every [SkillSvt] entry for this skill has a non-zero event ID,
  /// meaning the skill is only active during a specific event and should not
  /// be counted for non-event quests.
  static bool _isPurelyEventSkill(NiceSkill skill) =>
      skill.skillSvts.isNotEmpty &&
      skill.skillSvts.every((s) => s.eventId != 0);

  // ---------------------------------------------------------------------------
  // Skill NP charge helper (mirrors Pruner._skillNpCharge)
  // ---------------------------------------------------------------------------

  /// NP charge (0–100) from a single [skill] at [level] (1–10).
  int _skillNpCharge(NiceSkill skill, int level) {
    final lvIdx = (level - 1).clamp(0, 9);
    int total = 0;
    for (final func in skill.functions) {
      if (!_kGainNpFuncTypes.contains(func.funcType)) continue;
      if (!_appliesToAlly(func.funcTargetType)) continue;
      if (lvIdx >= func.svals.length) continue;
      final val = func.svals[lvIdx].Value ?? 0;
      total += val ~/ 100;
    }
    return total;
  }

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
}
