/// CandidateConverter — converts a CandidateTeam into TeamSpecs for HeadlessRunner.
///
/// This is the bridge between the Enumerator (which outputs who is on the team
/// and what CE/MC they carry) and the HeadlessRunner (which needs fully-specified
/// turn-by-turn action sequences).
///
/// The converter enumerates six variable dimensions:
///   1. NP assignment — which servant fires NP on which wave
///   2. OC timing — if Plug Suit MC, which turn (1/2/3) the Order Change fires
///   3. selfBatteryToT1 — attacker's self-battery on T1 or last NP turn
///   4. concentrateSupport — support single-ally batteries all on T2, or round-robin from T1
///   5. mcBatteryTurn — which turn the MC's battery skill fires (T1/T2/T3, if MC has one)
///   6. incomingSkillSplit — when OC is not the last NP turn, which subset of incoming servant
///      skills fires on the OC turn vs being deferred to the last NP turn (2^N subsets, N ≤ 3)
///
/// Dimension 6 is necessary because deciding which incoming skills belong on which turn requires
/// NP charge tracking (essentially simulation-level reasoning). Enumerating all 2^N splits and
/// letting the HeadlessRunner validate is simpler and more correct than trying to predict
/// analytically. When OC is on the last NP turn, no split is needed (all incoming skills fire
/// on the OC turn, which is also the last NP turn).
///
/// Everything else is derived:
///   - Skill filtering: isSchedulable=false skills (heal, invincible, DEF up, etc.) are omitted
///   - Skill targets: single-ally skills target the NP firer for that turn
///   - Skill timing: driven by the enumerated dimensions above; party-wide / non-battery → T1
///   - Skill ordering: topological sort respecting dependency graph
///   - OC split point: outgoing servant's skills → MC S3 → incoming servant's skills
///
/// Design reference: notes/design_decisions.md §"CandidateTeam → TeamSpec"
library;

import 'package:chaldea/models/models.dart';

import '../roster/roster_to_sim.dart';
import '../roster/user_roster.dart';
import '../search/enumerator.dart';
import '../simulation/headless_runner.dart';
import 'skill_classifier.dart';

// Mystic Code IDs that have Order Change as S3.
// ID 20  = "Mystic Code: Chaldea Combat Uniform" (original Plug Suit)
// ID 210 = "Chaldea Uniform - Decisive Battle" (Decisive Battle variant)
// Both have Order Change at skill index 2 and are functionally equivalent.
const Set<int> _kOrderChangeMcIds = {20, 210};

// MC skill index for Order Change (S3 = index 2).
const int _kOcSkillIndex = 2;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

class CandidateConverter {
  final UserRoster roster;

  CandidateConverter(this.roster);

  /// Converts [candidate] into a list of [TeamSpec]s to simulate.
  ///
  /// Returns an empty list if any required game data is missing.
  /// Callers should feed each returned spec to [HeadlessRunner.run].
  List<TeamSpec> convert(CandidateTeam candidate) {
    // 1. Resolve all 6 servants → internal layout entries
    final layout = _buildLayout(candidate);
    if (layout == null) return [];

    // 2. Convert layout to SlotSpec list (what HeadlessRunner expects)
    final slotSpecs = _toSlotSpecs(candidate, layout);

    // 3. Resolve MC
    MysticCode? mc;
    if (candidate.mysticCodeId != null) {
      mc = db.gameData.mysticCodes[candidate.mysticCodeId!];
    }

    // 4. Enumerate the two variable dimensions
    final hasPlugSuit = candidate.mysticCodeId != null &&
        _kOrderChangeMcIds.contains(candidate.mysticCodeId!);
    final ocOptions = hasPlugSuit ? [1, 2, 3] : <int?>[null];

    // 5. Identify which frontline slots (0-2) are attackers
    final frontlineAttackerSlots = _frontlineAttackerSlots(layout);

    // 6. Profile MC skills once (outside inner loops).
    //    Defensive skills are filtered out; battery skills drive turn enumeration.
    final mcSkillProfiles = _profileMcSkills(
        mc, candidate.mysticCodeLevel, hasPlugSuit);
    final hasMcBattery = mcSkillProfiles.any((e) => e.$2.chargesNp);
    // When the MC has a battery skill, enumerate which turn it fires on.
    // T1 charges the first NP; T2/T3 charge later waves if T1 would overflow.
    // The sim determines which landing turn actually results in a clear.
    final mcBatteryTurnOptions = hasMcBattery ? [1, 2, 3] : [1];

    final results = <TeamSpec>[];

    for (final ocTurn in ocOptions) {
      // Pre-compute the schedulable incoming servant skill refs for this OC turn.
      // When OC is not on the last NP turn (T3), we enumerate all 2^N subsets of
      // those refs to split between firing on the OC turn vs deferring to T3.
      // Determining the optimal split requires NP charge tracking (simulation-level
      // reasoning), so we enumerate all possibilities and let the sim validate.
      const lastNpTurn = 3;
      final schedulableIncoming = _schedulableIncomingRefs(layout, ocTurn);
      final incomingSplits = (ocTurn != null && ocTurn < lastNpTurn)
          ? _allSubsets(schedulableIncoming)
          : [<SkillRef>{}]; // OC on last NP turn → no split; all fire on OC turn

      // NP plan: for each wave (index 0-2), which frontline slot fires NP.
      // After OC on turn T, the newly-arrived servant occupies a frontline slot
      // and may also fire NP — but for now we only enumerate frontline attackers
      // (the swapped-in servant is usually a buffer like Oberon, not an attacker).
      for (final npPlan in _enumerateNpPlans(frontlineAttackerSlots)) {
        // Enumerate variable dimensions for skill timing:
        //
        // selfBatteryToT1:
        //   true  → attacker self-battery on T1 (needed when it's also a
        //            damage buff, e.g. Mélusine S1 "Dragon's Sword")
        //   false → attacker self-battery on last NP turn (loop completion,
        //            e.g. Ibuki S3 NP regen topping off the final wave)
        //
        // concentrateSupport:
        //   true  → all single-ally support batteries → T2 (gives max charge
        //            on one turn; ideal for Buster teams needing 100% combined)
        //   false → round-robin from T1 (first battery → T1, second → T2, …;
        //            ideal for Arts teams where the T1 battery also buffs T1 NP)
        //
        // mcBatteryTurn:
        //   which turn the MC's battery skill fires (if any). T1 is usually
        //   correct; later turns handle the case where T1 would overflow 100%.
        //
        // deferredIncomingRefs (incomingSplits):
        //   which subset of incoming servant skills defers to T3 vs fires on OC
        //   turn. Only meaningful when OC is not on the last NP turn.
        //
        // The sim determines which combination actually clears.
        for (final concentrateSupport in [true, false]) {
          for (final selfBatteryToT1 in [true, false]) {
            for (final mcBatteryTurn in mcBatteryTurnOptions) {
              for (final deferredIncomingRefs in incomingSplits) {
                final turns = _buildTurnActions(layout, npPlan, ocTurn,
                    mc: mc,
                    mcSkillProfiles: mcSkillProfiles,
                    mcBatteryTurn: mcBatteryTurn,
                    hasPlugSuit: hasPlugSuit,
                    selfBatteryToT1: selfBatteryToT1,
                    concentrateSupport: concentrateSupport,
                    deferredIncomingRefs: deferredIncomingRefs);
                if (turns == null) continue;

                results.add(TeamSpec(
                  slots: slotSpecs,
                  mysticCode: mc,
                  mysticCodeLevel: candidate.mysticCodeLevel,
                  turns: turns,
                ));
              }
            }
          }
        }
      }
    }

    return results;
  }

  // ---------------------------------------------------------------------------
  // Layout: 6 servant entries sorted into frontline (0-2) / backline (3-5)
  // ---------------------------------------------------------------------------

  /// Builds the 6-slot layout: [front0, front1, front2, back0, back1, back2].
  ///
  /// Slot assignment respects the order the caller specified in [candidate]:
  ///   - playerSvtIds[0] → slot 0 (main attacker / first listed)
  ///   - playerSvtIds[1] → slot 1  (if provided)
  ///   - supportSvtId   → slot 2  (friend support, always in frontline)
  ///   - playerSvtIds[2+] → slot 3, 4, 5  (backline, for OC swap-in)
  ///
  /// Preserving input order lets the caller express team intent directly
  /// (e.g. Oberon listed last = intended backline buffer for OC teams).
  List<_SvtEntry>? _buildLayout(CandidateTeam candidate) {
    // Resolve player servants in input order
    final playerEntries = <_SvtEntry>[];
    for (int i = 0; i < candidate.playerSvtIds.length; i++) {
      final svtId = candidate.playerSvtIds[i];
      final owned = roster.servants[svtId];
      final svt = db.gameData.servantsById[svtId];
      if (owned == null || svt == null) return null;

      playerEntries.add(_SvtEntry(
        svtId: svtId,
        svt: svt,
        level: owned.level,
        npLevel: owned.npLevel,
        skillLevels: List.of(owned.skillLevels),
        appendLevels: List.of(owned.appendLevels),
        fouAtk: owned.fouAtk,
        fouHp: owned.fouHp,
        limitCount: owned.limitCount,
        ceId: candidate.playerCeIds.length > i ? candidate.playerCeIds[i] : null,
        isSupport: false,
      ));
    }

    // Resolve support servant (generic: max stats assumed)
    final supportSvt = db.gameData.servantsById[candidate.supportSvtId];
    if (supportSvt == null) return null;
    final supportEntry = _SvtEntry(
      svtId: candidate.supportSvtId,
      svt: supportSvt,
      level: 90,
      npLevel: 5,
      skillLevels: [10, 10, 10],
      appendLevels: [0, 0, 0],
      fouAtk: 1000,
      fouHp: 1000,
      limitCount: 4,
      ceId: candidate.supportCeId,
      isSupport: true,
    );

    // Build ordered layout:
    //   slots 0..1 : first two player servants
    //   slot  2    : support servant (always frontline)
    //   slots 3..5 : remaining player servants (backline / OC swap targets)
    final layout = <_SvtEntry>[];
    for (int i = 0; i < playerEntries.length && i < 2; i++) {
      layout.add(playerEntries[i]);
    }
    layout.add(supportEntry);
    for (int i = 2; i < playerEntries.length; i++) {
      layout.add(playerEntries[i]);
    }

    return layout;
  }

  // ---------------------------------------------------------------------------
  // SlotSpec list
  // ---------------------------------------------------------------------------

  List<SlotSpec?> _toSlotSpecs(CandidateTeam candidate, List<_SvtEntry> layout) {
    return layout.map((entry) {
      if (entry.isSupport) {
        return genericSupportSlot(
          svt: entry.svt,
          level: entry.level,
          npLevel: entry.npLevel,
          skillLevels: entry.skillLevels,
          appendLevels: entry.appendLevels,
        );
      }

      OwnedCE? ownedCe;
      CraftEssence? ceObj;
      if (entry.ceId != null) {
        ownedCe = roster.craftEssences[entry.ceId!];
        ceObj = db.gameData.craftEssencesById[entry.ceId!];
      }

      return SlotSpec(
        svt: entry.svt,
        level: entry.level,
        limitCount: entry.limitCount,
        tdLevel: entry.npLevel,
        skillLevels: entry.skillLevels,
        appendLevels: entry.appendLevels,
        atkFou: entry.fouAtk,
        hpFou: entry.fouHp,
        ce: ceObj,
        ceMlb: ownedCe?.mlb ?? false,
        ceLevel: ownedCe?.level ?? 1,
        isSupport: false,
      );
    }).toList();
  }

  // ---------------------------------------------------------------------------
  // Attacker slot identification
  // ---------------------------------------------------------------------------

  /// Returns frontline slot indices (0-2) whose servant has a damaging NP.
  List<int> _frontlineAttackerSlots(List<_SvtEntry> layout) {
    final result = <int>[];
    for (int i = 0; i < 3 && i < layout.length; i++) {
      if (_role(layout[i].svt) != _Role.support) {
        result.add(i);
      }
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // NP plan enumeration
  // ---------------------------------------------------------------------------

  /// Generates all NP plans: for each of the 3 waves, which attacker slot fires NP.
  ///
  /// Each plan is a 3-element list: plan[i] = slot index that fires NP on wave i+1,
  /// or null if no attacker is available for that wave.
  ///
  /// With N attacker slots, produces N^3 plans (covers both solo and split NP).
  Iterable<List<int?>> _enumerateNpPlans(List<int> attackerSlots) sync* {
    final options = attackerSlots.isEmpty
        ? [null]
        : attackerSlots.map<int?>((s) => s).toList();

    for (final w1 in options) {
      for (final w2 in options) {
        for (final w3 in options) {
          yield [w1, w2, w3];
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // TurnActions building
  // ---------------------------------------------------------------------------

  /// Builds the 3-turn action sequence for the given NP plan and OC timing.
  ///
  /// [mcSkillProfiles] contains pre-profiled, pre-filtered MC skills (defensive
  /// skills and the OC skill already excluded). Battery MC skills land on
  /// [mcBatteryTurn]; all other MC skills go to T1.
  ///
  /// Returns null if a dependency cycle is detected (should not occur in practice).
  List<TurnActions>? _buildTurnActions(
      List<_SvtEntry> layout, List<int?> npPlan, int? ocTurn,
      {MysticCode? mc,
      List<(int, SkillProfile)> mcSkillProfiles = const [],
      int mcBatteryTurn = 1,
      bool hasPlugSuit = false,
      bool selfBatteryToT1 = false,
      bool concentrateSupport = true,
      Set<SkillRef> deferredIncomingRefs = const {}}) {
    // Gather skills for frontline servants (slots 0-2)
    final frontlineSkills = _gatherSkills(layout, 0, 3);

    // Classify all frontline skills
    final profiles = <SkillRef, SkillProfile>{};
    for (final (slot, skill, level) in frontlineSkills) {
      final ref = (slot, skill.svt.num - 1);
      profiles[ref] = SkillClassifier.profileSkill(skill, level);
    }

    // Detect dependencies across all frontline skills
    final allDeps = SkillClassifier.detectDependencies(frontlineSkills);

    // For OC turns: gather the incoming (backline slot 0) servant's skills too
    List<(int slot, NiceSkill skill, int level)> incomingSkills = [];
    if (ocTurn != null && layout.length > 3) {
      // Backline slot 0 → will occupy frontline slot 2 after OC.
      // We represent their post-OC skills with slotIndex=2
      // (the slot they'll occupy after the swap).
      // Gather skills from layout[3] using the original layout list so the
      // index-based iteration in _gatherSkills works correctly.
      final rawIncoming = _gatherSkills(layout, 3, 4);
      // Remap slot 3 → slot 2 (they take that slot after OC)
      incomingSkills = rawIncoming
          .map((e) => (2, e.$2, e.$3))
          .toList();

    }

    // Classify incoming servant's skills into a SEPARATE map.
    // The incoming servant occupies the same slot index (2) as the outgoing
    // servant, so their SkillRefs (slot, skillIndex) are identical. Using
    // the shared `profiles` map with ??= would silently reuse the outgoing
    // servant's profiles for the incoming servant's skills (e.g. Oberon S1
    // getting Vitch S1's singleAlly profile instead of partyWide). A separate
    // map avoids the collision entirely.
    final incomingProfiles = <SkillRef, SkillProfile>{};
    for (final (slot, skill, level) in incomingSkills) {
      final ref = (slot, skill.svt.num - 1);
      incomingProfiles[ref] = SkillClassifier.profileSkill(skill, level);
    }

    // Build post-OC profile map (incoming servant replaces outgoing at slot 2).
    // Used for turns after the OC swap so incoming servant's skill targeting is
    // correct (e.g. Oberon S1=partyWide, S2/S3=singleAlly uses the right type).
    final postOcProfiles = ocTurn != null
        ? (Map<SkillRef, SkillProfile>.of(profiles)..addAll(incomingProfiles))
        : profiles;

    // Assign frontline skills to turns based on NP plan
    final turnMap = _assignToTurns(frontlineSkills, profiles, npPlan,
        selfBatteryToT1: selfBatteryToT1,
        concentrateSupport: concentrateSupport);

    // Add MC skills. Defensive skills are already filtered from mcSkillProfiles
    // (and the OC skill is excluded for Plug Suit — it's emitted by _buildOcTurn).
    // Battery skills land on mcBatteryTurn; all other schedulable skills go to T1.
    for (final (sIdx, profile) in mcSkillProfiles) {
      final turn = profile.chargesNp ? mcBatteryTurn : 1;
      turnMap[turn]!.add((-1, sIdx));
    }

    // Double-use: if any support skill reduces ally CDs, re-add attacker skills
    // to T3 whenever CD math shows they'll be available again.
    _scheduleDoubleUse(frontlineSkills, profiles, turnMap, npPlan);

    // Apply incoming skill split: skills in deferredIncomingRefs go to T3;
    // the rest (ocIncoming) fire immediately after the OC swap on the OC turn.
    // This split is determined by the caller, which enumerates all 2^N subsets.
    const lastNpTurn = 3;
    final ocIncoming = <(int, NiceSkill, int)>[];
    if (ocTurn != null) {
      for (final e in incomingSkills) {
        final ref = (e.$1, e.$2.svt.num - 1);
        final profile = incomingProfiles[ref];
        if (profile == null || !profile.isSchedulable) continue;
        if (deferredIncomingRefs.contains(ref)) {
          if (!(turnMap[lastNpTurn]?.contains(ref) ?? false)) {
            turnMap[lastNpTurn]!.add(ref);
          }
        } else {
          ocIncoming.add(e);
        }
      }
    }

    // Build TurnActions for each turn
    final turnActions = <TurnActions>[];
    for (int turn = 1; turn <= 3; turn++) {
      final preSkillRefs = turnMap[turn] ?? [];

      // Determine the NP slot for this turn
      final npSlot = npPlan[turn - 1];
      final npSlots = npSlot != null ? [npSlot] : <int>[];

      // After the OC swap, the incoming servant occupies slot 2. Use the merged
      // postOcProfiles so their skill targeting is resolved correctly (e.g.
      // Oberon S1=partyWide, S2=singleAlly instead of the outgoing servant's profile).
      final currentProfiles =
          (ocTurn != null && turn > ocTurn) ? postOcProfiles : profiles;

      if (ocTurn == turn) {
        // OC turn: pre-swap skills → MC S3 → post-swap skills (ocIncoming only)
        final turnActions_ = _buildOcTurn(
          preSkillRefs: preSkillRefs,
          incomingSkills: ocIncoming,
          profiles: profiles,
          incomingProfiles: incomingProfiles,
          allDeps: allDeps,
          npSlot: npSlot,
          npSlots: npSlots,
        );
        if (turnActions_ == null) return null;
        turnActions.add(turnActions_);
      } else {
        // Normal turn: sort skills, build actions.
        // CD-ordering deps ensure attacker skills precede any CD-reduction skill
        // on the same turn (so the reduction applies to skills already on CD).
        final turnDeps = [
          ..._depsForSet(allDeps, preSkillRefs),
          ..._buildCdOrderingDeps(preSkillRefs, currentProfiles, npSlot),
        ];
        final sorted = SkillClassifier.topoSort(preSkillRefs, turnDeps);
        if (sorted == null) return null; // cycle

        turnActions.add(TurnActions(
          skills: _toSkillActions(sorted, currentProfiles, npSlot),
          npSlots: npSlots,
        ));
      }
    }

    return turnActions;
  }

  /// Builds the TurnActions for the turn that contains an Order Change.
  ///
  /// Structure: [pre-swap skill actions] + [MC S3] + [post-swap skill actions]
  TurnActions? _buildOcTurn({
    required List<SkillRef> preSkillRefs,
    required List<(int slot, NiceSkill skill, int level)> incomingSkills,
    required Map<SkillRef, SkillProfile> profiles,
    required Map<SkillRef, SkillProfile> incomingProfiles,
    required List<SkillDep> allDeps,
    required int? npSlot,
    required List<int> npSlots,
  }) {
    // Sort pre-swap skills respecting deps + CD-ordering constraints.
    final preDeps = [
      ..._depsForSet(allDeps, preSkillRefs),
      ..._buildCdOrderingDeps(preSkillRefs, profiles, npSlot),
    ];
    final preSorted = SkillClassifier.topoSort(preSkillRefs, preDeps);
    if (preSorted == null) return null;

    // Build post-swap skill refs: all incoming servant skills (now in slot 2)
    final postRefs = incomingSkills
        .map<SkillRef>((e) => (e.$1, e.$2.svt.num - 1))
        .toList();
    // No known deps for incoming servant against pre-swap skills (different servant)
    final postSorted = SkillClassifier.topoSort(postRefs, []);
    if (postSorted == null) return null;

    final allActions = <SkillAction>[
      ..._toSkillActions(preSorted, profiles, npSlot),
      // MC S3 = Order Change
      const SkillAction(slotIndex: -1, skillIndex: _kOcSkillIndex),
      ..._toSkillActions(postSorted, incomingProfiles, npSlot),
    ];

    return TurnActions(
      skills: allActions,
      npSlots: npSlots,
      // onFieldSlot=2 swaps out; backlineSlot=0 swaps in.
      // This matches layout[3] (first backline servant) entering at slot 2.
      orderChange: const OrderChangeAction(onFieldSlot: 2, backlineSlot: 0),
    );
  }

  // ---------------------------------------------------------------------------
  // Skill → turn assignment
  // ---------------------------------------------------------------------------

  /// Assigns each frontline skill to a turn based on timing rules.
  ///
  /// Purely defensive skills (isSchedulable=false) are skipped entirely.
  ///
  ///   - chargesNp (battery) AND singleAlly AND from a support slot:
  ///     All go to T2. T1 is already covered by CE start charge (Black Grail /
  ///     Kaleido) + the attacker's own charge skills. Concentrating all support
  ///     batteries on T2 ensures looping attackers (who lack natural NP regen)
  ///     can fire T2 NP with combined support charge (e.g. double Vitch S1 =
  ///     50%+50% = 100%). T3 is then covered by the attacker's self-battery or
  ///     post-OC buffers.
  ///
  ///   - chargesNp AND self AND attacker (ownNpTurn != null):
  ///     Enumerated externally: [selfBatteryToT1=true] → T1 (needed when the
  ///     skill is also a damage buff, e.g. Mélusine "Dragon's Sword");
  ///     [selfBatteryToT1=false] → last NP turn (loop completion, e.g. Ibuki
  ///     S3 NP regen that tops off the final wave). The sim determines which
  ///     version clears.
  ///
  ///   - Everything else: multi-turn buffs (isTimeSensitive=false) → T1 so
  ///     they cover all 3 NPs; 1-turn buffs (isTimeSensitive=true) → T3
  ///     since last-wave enemies have the highest HP on 90++ nodes.
  Map<int, List<SkillRef>> _assignToTurns(
      List<(int slot, NiceSkill skill, int level)> skills,
      Map<SkillRef, SkillProfile> profiles,
      List<int?> npPlan,
      {bool selfBatteryToT1 = false, bool concentrateSupport = true}) {
    final result = <int, List<SkillRef>>{1: [], 2: [], 3: []};

    final npTurns = <int>[
      for (int t = 0; t < 3; t++) if (npPlan[t] != null) t + 1,
    ];
    // When concentrating, all support batteries land on T2 (the second NP turn).
    // When spreading, batteries are round-robined starting from T1 so the first
    // battery lands on T1 and buffs the T1 NP (e.g. Castoria S2 NP dmg up).
    final supportBatteryTurn = npTurns.length >= 2 ? npTurns[1] : 2;
    int supportBatteryIdx = 0; // round-robin counter for spread mode

    for (final (slot, skill, _) in skills) {
      final ref = (slot, skill.svt.num - 1);
      final profile = profiles[ref] ??
          const SkillProfile(
            targeting: SkillTargeting.partyWide,
            isTimeSensitive: false,
          );

      // Skip skills that have no offensive or battery value in a damage context.
      if (!profile.isSchedulable) continue;

      // Does this slot fire NP on any turn?
      int? ownNpTurn;
      for (int t = 0; t < 3; t++) {
        if (npPlan[t] == slot) {
          ownNpTurn = t + 1;
          break;
        }
      }

      if (profile.chargesNp &&
          profile.targeting == SkillTargeting.singleAlly &&
          ownNpTurn == null &&
          npTurns.isNotEmpty) {
        // Single-ally NP charge from a support slot.
        // concentrateSupport=true: all on T2 (100% combined, good for Buster).
        // concentrateSupport=false: round-robin from T1 (first → T1 to buff T1
        //   NP damage, second → T2, …; good for Arts loop teams).
        if (concentrateSupport) {
          result[supportBatteryTurn]!.add(ref);
        } else {
          final turn = npTurns[supportBatteryIdx % npTurns.length];
          supportBatteryIdx++;
          result[turn]!.add(ref);
        }
      } else if (profile.chargesNp &&
          profile.targeting == SkillTargeting.self &&
          ownNpTurn != null) {
        // Attacker's own self-battery: two placements enumerated by the caller.
        if (selfBatteryToT1) {
          result[1]!.add(ref);
        } else {
          final lastNpTurn = npPlan
              .asMap()
              .entries
              .lastWhere((e) => e.value == slot)
              .key + 1;
          result[lastNpTurn]!.add(ref);
        }
      } else {
        // Multi-turn buffs (isTimeSensitive=false) → T1 so they cover all 3 NPs.
        // 1-turn buffs (isTimeSensitive=true, Turn==1 in svals) → T3; last-wave
        // enemies have the highest HP on 90++ nodes so 1-turn buffs are most
        // valuable on the final NP. Note: isTimeSensitive may miss some 1-turn
        // buffs that don't set Turn=1 in svals (they fall through to T1), but it
        // will never falsely move a multi-turn buff to T3.
        result[profile.isTimeSensitive ? 3 : 1]!.add(ref);
      }
    }

    return result;
  }

  // ---------------------------------------------------------------------------
  // SkillAction building
  // ---------------------------------------------------------------------------

  List<SkillAction> _toSkillActions(
      List<SkillRef> sorted, Map<SkillRef, SkillProfile> profiles, int? npSlot) {
    return sorted.map((ref) {
      final (slot, skillIdx) = ref;
      final profile = profiles[ref];

      int? allyTarget;
      if (profile?.targeting == SkillTargeting.singleAlly) {
        // Target the NP firer for this turn; fall back to skill owner
        allyTarget = npSlot ?? slot;
      }

      return SkillAction(
        slotIndex: slot,
        skillIndex: skillIdx,
        allyTarget: allyTarget,
      );
    }).toList();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Profiles MC skills, filtering out defensive ones.
  ///
  /// The OC skill (S3) is excluded for Plug Suit — it's handled by [_buildOcTurn].
  /// Skills with [isSchedulable]=false (heal, invincible, DEF up, etc.) are omitted.
  /// Returns a list of (skillIndex, SkillProfile) for every schedulable MC skill.
  List<(int, SkillProfile)> _profileMcSkills(
      MysticCode? mc, int level, bool hasPlugSuit) {
    if (mc == null) return const [];
    final result = <(int, SkillProfile)>[];
    for (int sIdx = 0; sIdx < mc.skills.length && sIdx < 3; sIdx++) {
      if (hasPlugSuit && sIdx == _kOcSkillIndex) continue;
      final profile = SkillClassifier.profileSkill(mc.skills[sIdx], level);
      if (profile.isSchedulable) result.add((sIdx, profile));
    }
    return result;
  }

  /// Schedules double-use of attacker skills when cooldown math allows.
  ///
  /// For each skill assigned to T1, if the total CD reduction from support skills
  /// (e.g. Vitch S1 reducing ally CDs by 2) plus natural turn ticks is enough to
  /// bring the skill's cooldown to 0 by [reuseTurn] (T3), the skill is added to
  /// T3 as well. This models patterns like Altria using all 3 skills on T1 and
  /// T3 in a double-Vitch team.
  ///
  /// The ordering constraint (attacker skills before CD-reducing skills on the
  /// same turn) is enforced separately by [_buildCdOrderingDeps].
  void _scheduleDoubleUse(
      List<(int slot, NiceSkill skill, int level)> frontlineSkills,
      Map<SkillRef, SkillProfile> profiles,
      Map<int, List<SkillRef>> turnMap,
      List<int?> npPlan) {
    // Build quick lookup: SkillRef → (NiceSkill, level).
    final skillLookup = <SkillRef, (NiceSkill, int)>{};
    for (final (slot, skill, level) in frontlineSkills) {
      skillLookup[(slot, skill.svt.num - 1)] = (skill, level);
    }

    // Collect all CD-reducing support skills and their effects:
    //   (turn, amount, targetSlot) — targetSlot=null means party-wide.
    final cdReductions = <({int turn, int amount, int? targetSlot})>[];
    for (int t = 1; t <= 3; t++) {
      for (final ref in turnMap[t] ?? []) {
        final (slot, _) = ref;
        if (slot < 0) continue; // MC skill
        final profile = profiles[ref];
        if (profile == null ||
            !profile.reducesAllyCd ||
            profile.cdReductionAmount <= 0) {
          continue;
        }
        // For singleAlly, the target is the NP firer for this turn.
        final targetSlot = profile.targeting == SkillTargeting.singleAlly
            ? npPlan[t - 1]
            : null; // null = affects all ally slots
        cdReductions.add(
            (turn: t, amount: profile.cdReductionAmount, targetSlot: targetSlot));
      }
    }

    if (cdReductions.isEmpty) return;

    // For each T1 skill, determine if it becomes available again on T3.
    // CD at start of T3 = baseCd - naturalTicks(T1→T3) - totalReductions(T1..T2).
    // naturalTicks = 2 (end of T1, end of T2).
    const firstUseTurn = 1;
    const reuseTurn = 3;
    const naturalTicks = reuseTurn - firstUseTurn; // = 2

    for (final ref in List.of(turnMap[firstUseTurn] ?? [])) {
      final (slot, _) = ref;
      if (slot < 0) continue; // MC skill, skip

      final profile = profiles[ref];
      if (profile?.isSchedulable != true) continue; // defensive skill, skip

      final entry = skillLookup[ref];
      if (entry == null) continue;
      final (skill, level) = entry;
      if (skill.coolDown.isEmpty) continue;
      final lvIdx = (level - 1).clamp(0, skill.coolDown.length - 1);
      final baseCd = skill.coolDown[lvIdx];
      if (baseCd <= 0) continue; // passive / no cooldown

      // Sum reductions that apply to this slot from turns T1 through T2.
      int totalReduction = 0;
      for (final r in cdReductions) {
        if (r.turn < firstUseTurn || r.turn >= reuseTurn) continue;
        if (r.targetSlot != null && r.targetSlot != slot) continue;
        totalReduction += r.amount;
      }

      // Skill is re-available on T3 if CD drains to 0 in time.
      if (baseCd <= naturalTicks + totalReduction) {
        if (!(turnMap[reuseTurn]?.contains(ref) ?? false)) {
          turnMap[reuseTurn]!.add(ref);
        }
      }
    }
  }

  /// Returns ordering deps ensuring ally skills precede any CD-reducing skill
  /// on the same turn.
  ///
  /// The dependency is: skill B (attacker skill from [npSlot]) must fire
  /// BEFORE skill A (the CD-reducing skill targeting [npSlot]), so that B
  /// is already on cooldown when A reduces it. If A fires first, B's CD is
  /// still 0 (unused) and the reduction is wasted.
  List<SkillDep> _buildCdOrderingDeps(
      List<SkillRef> turnRefs,
      Map<SkillRef, SkillProfile> profiles,
      int? npSlot) {
    final deps = <SkillDep>[];

    for (final cdRef in turnRefs) {
      final (cdSlot, _) = cdRef;
      if (cdSlot < 0) continue; // MC skill
      final profile = profiles[cdRef];
      if (profile == null || !profile.reducesAllyCd) continue;

      // Determine which slot(s) are affected.
      final Set<int> targetSlots;
      if (profile.targeting == SkillTargeting.singleAlly) {
        if (npSlot == null) continue;
        targetSlots = {npSlot};
      } else {
        // Party-wide: all non-MC slots in this turn's ref set.
        targetSlots =
            turnRefs.map((r) => r.$1).where((s) => s >= 0).toSet();
        targetSlots.remove(cdSlot);
      }

      // All skills from the target slot(s) must precede this CD-reducing skill.
      for (final ref in turnRefs) {
        if (ref == cdRef) continue;
        if (!targetSlots.contains(ref.$1)) continue;
        deps.add(SkillDep(ref, cdRef));
      }
    }

    return deps;
  }

  /// Returns the schedulable [SkillRef]s for the first backline servant
  /// (the one that swaps in via Order Change), remapped to slot 2.
  ///
  /// Returns empty if there is no OC ([ocTurn] == null) or no backline servant.
  /// These refs are used by [convert] to enumerate all 2^N split options for
  /// which skills fire on the OC turn vs defer to the last NP turn.
  List<SkillRef> _schedulableIncomingRefs(
      List<_SvtEntry> layout, int? ocTurn) {
    if (ocTurn == null || layout.length <= 3) return const [];
    final rawIncoming = _gatherSkills(layout, 3, 4);
    final result = <SkillRef>[];
    for (final (_, skill, level) in rawIncoming) {
      final ref = (2, skill.svt.num - 1);
      final profile = SkillClassifier.profileSkill(skill, level);
      if (profile.isSchedulable) result.add(ref);
    }
    return result;
  }

  /// Returns all 2^N subsets of [items] as [Set]s.
  ///
  /// The empty set (defer nothing) and the full set (defer everything) are
  /// both included. Used to enumerate all possible splits of incoming servant
  /// skills between the OC turn and the last NP turn.
  List<Set<T>> _allSubsets<T>(List<T> items) {
    final n = items.length;
    final result = <Set<T>>[];
    for (int mask = 0; mask < (1 << n); mask++) {
      final subset = <T>{};
      for (int i = 0; i < n; i++) {
        if ((mask >> i) & 1 != 0) subset.add(items[i]);
      }
      result.add(subset);
    }
    return result;
  }

  /// Returns deps filtered to edges where both endpoints are in [refs].
  List<SkillDep> _depsForSet(List<SkillDep> deps, List<SkillRef> refs) {
    final refSet = refs.toSet();
    return deps
        .where((d) => refSet.contains(d.before) && refSet.contains(d.after))
        .toList();
  }

  /// Gathers (slotIndex, NiceSkill, level) for servants in layout[start..end).
  /// slotIndex = the servant's position in the 6-slot layout.
  List<(int slot, NiceSkill skill, int level)> _gatherSkills(
      List<_SvtEntry> layout, int start, int end) {
    final result = <(int, NiceSkill, int)>[];
    for (int i = start; i < end && i < layout.length; i++) {
      final entry = layout[i];
      final skills = _activeSkillsFor(entry.svt, limitCount: entry.limitCount);
      for (int sIdx = 0; sIdx < skills.length; sIdx++) {
        final skill = skills[sIdx];
        final level = entry.skillLevels.length > sIdx ? entry.skillLevels[sIdx] : 1;
        result.add((i, skill, level));
      }
    }
    return result;
  }

  /// Returns the 3 active skills for a servant in NA region order.
  ///
  /// [limitCount] (0-4) controls which skill variants are eligible: only skills
  /// with condLimitCount <= limitCount are considered. This ensures Mélusine at
  /// Asc2 (limitCount=2) gets her Asc2 skill variants rather than the Asc4 ones
  /// (which have different/additional functions like self NP charge).
  List<NiceSkill> _activeSkillsFor(Servant svt, {int limitCount = 4}) {
    final result = <NiceSkill>[];
    for (final num in [1, 2, 3]) {
      final candidates = svt.groupedActiveSkills[num];
      if (candidates == null || candidates.isEmpty) continue;
      // Filter to skill variants available at this ascension level.
      // Fall back to all candidates if none pass the filter (safety net for
      // servants that don't use condLimitCount gating in their skill data).
      final eligible = candidates
          .where((s) => s.condLimitCount <= limitCount)
          .toList();
      final pool = eligible.isNotEmpty ? eligible : candidates;
      final skill = svt.getDefaultSkill(pool, Region.na);
      if (skill != null) result.add(skill);
    }
    return result;
  }

  /// Classifies a servant as AoE attacker, ST attacker, or support.
  _Role _role(Servant svt) {
    final np = svt.groupedNoblePhantasms[1]?.firstOrNull;
    if (np == null) return _Role.support;
    if (np.damageType == TdEffectFlag.attackEnemyAll) return _Role.aoeAttacker;
    if (np.damageType == TdEffectFlag.attackEnemyOne) return _Role.stAttacker;
    return _Role.support;
  }
}

// ---------------------------------------------------------------------------
// Internal types
// ---------------------------------------------------------------------------

/// All data needed to place one servant in the team.
class _SvtEntry {
  final int svtId;
  final Servant svt;
  final int level;
  final int npLevel;
  final List<int> skillLevels;
  final List<int> appendLevels;
  final int fouAtk;
  final int fouHp;
  final int limitCount;
  final int? ceId;
  final bool isSupport;

  _SvtEntry({
    required this.svtId,
    required this.svt,
    required this.level,
    required this.npLevel,
    required this.skillLevels,
    required this.appendLevels,
    required this.fouAtk,
    required this.fouHp,
    required this.limitCount,
    this.ceId,
    required this.isSupport,
  });
}

/// Servant role for slot ordering purposes.
enum _Role {
  aoeAttacker, // slot priority 0 (frontline first)
  stAttacker, // slot priority 1
  support, // slot priority 2 (backline preferred)
}
