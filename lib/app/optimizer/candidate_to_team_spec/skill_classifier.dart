/// SkillClassifier — classifies servant skills for sequencing purposes.
///
/// Given the NiceSkill objects from game data, this module determines:
///   - Targeting: does a skill need a specific ally target?
///   - Time-sensitivity: does a buff last only 1 turn (must use same turn as NP)?
///   - Dependencies: must skill A precede skill B for correctness?
///
/// Dependencies are auto-detected from game data buff tags, NOT hardcoded
/// per servant. The canonical example: Elly S1 applies downTolerance
/// (debuff-resist-down) to allies; Yaraandoo S2 applies an ally buff tagged
/// as a debuff with Rate<1000 (resistible). Elly S1 MUST precede Yaraandoo S2
/// or the buff fails. Both constraints are read from Atlas Academy buff data.
///
/// This module has no dependency on the roster or HeadlessRunner —
/// it is pure game-data logic.
library;

import 'package:chaldea/models/models.dart';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Identifies one skill: (servantSlotIndex, skillIndex).
/// slotIndex is 0-5 (team slot, 0-2 = frontline, 3-5 = backline).
/// skillIndex is 0-2 (skill 1/2/3 → 0/1/2).
typedef SkillRef = (int, int);

enum SkillTargeting {
  /// Affects all frontline allies (no ally target needed).
  partyWide,

  /// Affects only the casting servant (self-target, usually no input needed).
  self,

  /// Requires selecting a specific ally. The optimizer targets the NP firer
  /// for this turn, or the most likely benefit target.
  singleAlly,
}

/// Classification of a skill's properties relevant to turn ordering.
class SkillProfile {
  final SkillTargeting targeting;

  /// True if any buff this skill applies lasts exactly 1 turn (Turn==1 in svals).
  ///
  /// NOTE: no longer used to drive turn assignment. Kept for informational
  /// purposes. The isSchedulable / chargesNp fields drive all timing decisions.
  final bool isTimeSensitive;

  /// True if this skill contains a gainNp (NP charge / "battery") function.
  ///
  /// Battery skills from support servants should be spread across the turns
  /// where the attacker fires NP, rather than all landing on turn 1.
  /// This applies regardless of whether the targeting is single-ally or
  /// party-wide — both need to be distributed to be effective.
  final bool chargesNp;

  /// True if this skill reduces the skill cooldown of one or more allies
  /// (FuncType.shortenSkill targeting allies).
  ///
  /// When true, [cdReductionAmount] holds the number of turns reduced per use.
  /// Skills with reducesAllyCd=true create an ordering constraint: any ally
  /// skill that will benefit from the reduction must fire BEFORE this skill
  /// on the same turn (so it is already on cooldown when the reduction applies).
  final bool reducesAllyCd;

  /// Number of turns of skill cooldown reduced per use.
  ///
  /// Only meaningful when [reducesAllyCd] is true. Derived from the
  /// FuncType.shortenSkill function's svals.Value at the skill's level.
  final int cdReductionAmount;

  /// True if this skill should be scheduled at all.
  ///
  /// False only when every function in the skill is purely defensive (heal,
  /// invincibility, guts, DEF up, remove debuffs, etc.) — effects that have
  /// no impact on damage output or NP charging in a 3-turn farming context.
  /// Such skills are silently omitted from the generated spec, keeping the
  /// output clean and avoiding unnecessary button-presses.
  ///
  /// A skill with any offensive or battery component (ATK up, card type up,
  /// NP damage up, NP gain rate up, transforms, etc.) is always schedulable,
  /// even if it also carries a defensive side-effect (e.g. Castoria S3 has
  /// Arts up + invincible — it is schedulable for the Arts up).
  final bool isSchedulable;

  const SkillProfile({
    required this.targeting,
    required this.isTimeSensitive,
    this.chargesNp = false,
    this.isSchedulable = true,
    this.reducesAllyCd = false,
    this.cdReductionAmount = 0,
  });

  @override
  String toString() =>
      'SkillProfile($targeting, ts=$isTimeSensitive, bat=$chargesNp, sched=$isSchedulable, cdReduce=$reducesAllyCd($cdReductionAmount))';
}

/// A dependency edge: [before] must be activated before [after].
///
/// Example: Elly S1 (before=(slot0, 0)) → Yaraandoo S2 (after=(slot2, 1)).
class SkillDep {
  final SkillRef before;
  final SkillRef after;

  const SkillDep(this.before, this.after);

  @override
  String toString() => 'SkillDep($before → $after)';
}

// ---------------------------------------------------------------------------
// SkillClassifier
// ---------------------------------------------------------------------------

class SkillClassifier {
  /// Profiles a single skill at the given skill level (1-10).
  static SkillProfile profileSkill(NiceSkill skill, int level) {
    final lvIdx = (level - 1).clamp(0, 9);
    bool timeSensitive = false;
    bool hasSingleAlly = false;
    bool hasSelf = false;
    bool chargesNp = false;
    bool isSchedulable = false;
    bool reducesAllyCd = false;
    int cdReductionAmount = 0;

    for (final func in skill.functions) {
      // Targeting classification: any single-ally function makes this a targeted skill.
      if (func.funcTargetType.needNormalOneTarget) {
        hasSingleAlly = true;
      } else if (func.funcTargetType == FuncTargetType.self) {
        hasSelf = true;
      }

      // Battery detection: any gainNp* func type adds NP gauge.
      if (_kGainNpFuncTypes.contains(func.funcType)) {
        chargesNp = true;
      }

      // isTimeSensitive: true when the skill's primary (non-defensive) effects
      // last only 1 turn. Purely defensive functions (invincibility, DEF up,
      // guts, etc.) are excluded — a 1-turn invincibility side effect on an
      // otherwise multi-turn skill (e.g. Castoria S3) must not cause the
      // skill to be classified as 1-turn. Note: some 1-turn offensive buffs
      // (e.g. Oberon S3 Buster up) store their duration outside svals, so this
      // field may still miss some cases — but it will never falsely flag a
      // multi-turn skill as 1-turn.
      if (!_isPurelyDefensiveFunc(func) && lvIdx < func.svals.length) {
        final turn = func.svals[lvIdx].Turn;
        if (turn != null && turn == 1) timeSensitive = true;
      }

      // Schedulability: the skill is relevant if at least one function is
      // non-defensive. We use a denylist — if any function falls outside the
      // purely-defensive set, the skill is worth scheduling.
      if (!_isPurelyDefensiveFunc(func)) {
        isSchedulable = true;
      }

      // CD reduction detection: shortenSkill targeting allies.
      // cdReductionAmount = the amount at this skill level (svals.Value).
      if (func.funcType == FuncType.shortenSkill &&
          _appliesToAlly(func.funcTargetType)) {
        if (lvIdx < func.svals.length) {
          final amount = func.svals[lvIdx].Value ?? 0;
          if (amount > 0) {
            reducesAllyCd = true;
            if (amount > cdReductionAmount) {
              cdReductionAmount = amount;
            }
          }
        }
      }
    }

    final targeting = hasSingleAlly
        ? SkillTargeting.singleAlly
        : hasSelf
            ? SkillTargeting.self
            : SkillTargeting.partyWide;

    return SkillProfile(
      targeting: targeting,
      isTimeSensitive: timeSensitive,
      chargesNp: chargesNp,
      isSchedulable: isSchedulable,
      reducesAllyCd: reducesAllyCd,
      cdReductionAmount: cdReductionAmount,
    );
  }

  /// Detects dependency edges between skills in a team's combined skill set.
  ///
  /// [skillsWithSlots]: every skill in the team, as (slotIndex, NiceSkill, level).
  ///   slotIndex: 0-5 (slot in the team layout, same as SkillRef.slotIndex)
  ///   level: actual skill level (1-10) for this servant
  ///
  /// Currently detects:
  ///   downTolerance (BuffType.downTolerance) → debuff-type ally addState
  ///
  /// "Debuff-type ally addState" = an addState/addStateShort function targeting
  /// allies where the applied buff type is intrinsically negative (e.g. donotSkill,
  /// donotAct, stuns). These buffs always go through the battle engine's
  /// resistanceState check regardless of their Rate value — meaning even a
  /// Rate=1000 skill seal can be partially or fully resisted by allies with
  /// positive debuff resistance. downTolerance reduces that resistance,
  /// making the negative ally effect more reliable.
  ///
  /// Example: Elly S2 (downTolerance on all allies) → Yaraandoo S2 (donotSkill
  /// [My Fair Soldier] on allies — required to enable their conditional ATK/DEF up).
  static List<SkillDep> detectDependencies(
      List<(int slot, NiceSkill skill, int level)> skillsWithSlots) {
    final deps = <SkillDep>[];

    // Phase 1: find all skills that apply downTolerance to allies
    final resistDownRefs = <SkillRef>[];
    for (final (slot, skill, _) in skillsWithSlots) {
      for (final func in skill.functions) {
        if (_appliesToAlly(func.funcTargetType) &&
            func.buffs.any((b) => b.type == BuffType.downTolerance)) {
          resistDownRefs.add((slot, skill.svt.num - 1));
          break;
        }
      }
    }

    if (resistDownRefs.isEmpty) return deps;

    // Phase 2: find skills that apply a debuff-type buff to allies via addState.
    // These are effects that always go through the resist check in shouldAddState(),
    // so downTolerance meaningfully increases their landing rate.
    for (final (slot, skill, _) in skillsWithSlots) {
      final ref = (slot, skill.svt.num - 1);
      if (resistDownRefs.contains(ref)) continue;

      bool hasDebuffAllyEffect = false;
      for (final func in skill.functions) {
        if (!_appliesToAlly(func.funcTargetType)) continue;
        if (func.funcType != FuncType.addState &&
            func.funcType != FuncType.addStateShort) {
          continue;
        }
        if (func.buffs.any((b) => _kDebuffBuffTypes.contains(b.type))) {
          hasDebuffAllyEffect = true;
          break;
        }
      }

      if (hasDebuffAllyEffect) {
        for (final rdRef in resistDownRefs) {
          deps.add(SkillDep(rdRef, ref));
        }
      }
    }

    return deps;
  }

  /// FuncTypes that add NP gauge to one or more servants ("batteries").
  /// Sourced from the kFuncValPercentType map in const_data.dart.
  static const Set<FuncType> _kGainNpFuncTypes = {
    FuncType.gainNp,
    FuncType.gainNpFromTargets,
    FuncType.gainNpBuffIndividualSum,
    FuncType.gainNpIndividualSum,
    FuncType.gainNpTargetSum,
    FuncType.gainNpFromOtherUsedNpValue,
    FuncType.gainNpCriticalstarSum,
  };

  /// Returns true if [func] has only defensive/irrelevant effects for a
  /// 3-turn NP-only farming context.
  ///
  /// A function is "purely defensive" if it is one of the known heal/cleanse
  /// func types, OR if it is an addState/addStateShort whose every buff is in
  /// [_kPurelyDefensiveBuffTypes]. Anything else (ATK up, card type up, NP
  /// damage up, NP gain rate up, transform, etc.) is considered offensive and
  /// makes the enclosing skill worth scheduling.
  static bool _isPurelyDefensiveFunc(NiceFunction func) {
    if (_kPurelyDefensiveFuncTypes.contains(func.funcType)) return true;
    if (func.funcType == FuncType.addState ||
        func.funcType == FuncType.addStateShort) {
      return func.buffs.isNotEmpty &&
          func.buffs.every((b) => _kPurelyDefensiveBuffTypes.contains(b.type));
    }
    return false;
  }

  /// FuncTypes that are inherently defensive/irrelevant to damage output.
  /// Skills whose every function matches this set (or the addState check below)
  /// will be flagged isSchedulable=false and omitted from generated specs.
  static const Set<FuncType> _kPurelyDefensiveFuncTypes = {
    FuncType.gainHp,      // flat heal
    FuncType.gainHpPer,   // percentage heal
    FuncType.subState,    // remove debuffs from ally
  };

  /// BuffTypes that are purely defensive when applied via addState/addStateShort.
  /// A skill whose addState functions only ever produce these buffs is not worth
  /// scheduling in a damage-focused 3-turn farming context.
  static const Set<BuffType> _kPurelyDefensiveBuffTypes = {
    BuffType.invincible,     // invincibility
    BuffType.avoidance,      // evade / dodge
    BuffType.guts,           // survive lethal hit
    BuffType.subSelfdamage,  // damage cut
    BuffType.upDefence,      // DEF up (no effect on NP damage output)
  };

  /// Buff types that are intrinsically negative when applied to allies.
  /// These are "debuff-type" effects that always go through the debuff
  /// resistance check in shouldAddState(), so downTolerance is meaningful.
  static const Set<BuffType> _kDebuffBuffTypes = {
    BuffType.donotSkill,       // skill seal
    BuffType.donotSkillSelect, // skill select seal
    BuffType.donotAct,         // stun / cannot act
    BuffType.donotActCommandtype, // command card seal (specific type)
    BuffType.donotNoble,       // NP seal
    BuffType.reduceHp,         // HP drain (periodic)
  };

  /// Topological sort of [skills] respecting [deps].
  ///
  /// Uses Kahn's algorithm. Skills not involved in any dependency retain their
  /// original relative order (stable). Skills only in [skills] — not [deps] —
  /// are treated as order-free and come first.
  ///
  /// Returns null if the dependency graph has a cycle (should not occur with
  /// real FGO skill data; if it does, it's a bug in dependency detection).
  static List<SkillRef>? topoSort(List<SkillRef> skills, List<SkillDep> deps) {
    // Build in-degree map and adjacency list (only for edges within this set)
    final inDegree = <SkillRef, int>{for (final s in skills) s: 0};
    final adj = <SkillRef, List<SkillRef>>{};

    for (final dep in deps) {
      if (!inDegree.containsKey(dep.before) ||
          !inDegree.containsKey(dep.after)) {
        continue; // edge references a skill not in this turn's set; ignore
      }
      adj.putIfAbsent(dep.before, () => []).add(dep.after);
      inDegree[dep.after] = inDegree[dep.after]! + 1;
    }

    // Initialize queue with all zero-in-degree nodes, preserving original order
    final queue = skills.where((s) => inDegree[s] == 0).toList();
    final sorted = <SkillRef>[];

    while (queue.isNotEmpty) {
      final node = queue.removeAt(0);
      sorted.add(node);
      for (final neighbor in adj[node] ?? []) {
        inDegree[neighbor] = inDegree[neighbor]! - 1;
        if (inDegree[neighbor] == 0) queue.add(neighbor);
      }
    }

    // If not all skills were sorted, there's a cycle
    return sorted.length == skills.length ? sorted : null;
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Returns true if the function target type can affect allies.
  static bool _appliesToAlly(FuncTargetType t) {
    return t == FuncTargetType.self ||
        t == FuncTargetType.ptOne ||
        t == FuncTargetType.ptAnother ||
        t == FuncTargetType.ptOther ||      // all allies except self
        t == FuncTargetType.ptOtherFull ||  // all allies except self (including backline)
        t == FuncTargetType.ptAll ||
        t == FuncTargetType.ptFull ||
        t.needNormalOneTarget;
  }
}
