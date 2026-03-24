/// ShareDataConverter — converts a [TeamSpec] (our internal pipeline type)
/// into a [BattleShareData] (Chaldea's canonical share format).
///
/// The produced [BattleShareData] can be:
///   - stored in a [RunRecord] for history / pattern matching
///   - shared as a Chaldea deep link (`chaldea://laplace/share?data=G...`)
///   - replayed via [HeadlessRunner.runFromShareData]
///
/// Mapping summary:
///   SlotSpec       → SvtSaveData     (skill IDs resolved via NA rank-ups)
///   SkillAction    → BattleRecordData.skill  (svt=-1 → null for MC skills)
///   npSlots entry  → BattleRecordData.attack (isTD=true)
///   OrderChangeAction → BattleReplayDelegateData.replaceMemberIndexes
library;

import 'package:chaldea/models/models.dart';

import 'headless_runner.dart';

class ShareDataConverter {
  const ShareDataConverter._();

  /// Converts [spec] to a [BattleShareData] for [quest].
  ///
  /// The resulting share data faithfully encodes the full action sequence
  /// so it can be replayed by [HeadlessRunner.runFromShareData] or loaded
  /// into Chaldea's battle simulator UI.
  static BattleShareData convert(QuestPhase quest, TeamSpec spec) {
    // Collect Order Change swaps for the delegate.
    final delegateData = BattleReplayDelegateData();
    for (final turn in spec.turns) {
      final oc = turn.orderChange;
      if (oc != null) {
        delegateData.replaceMemberIndexes.add([oc.onFieldSlot, oc.backlineSlot]);
      }
    }

    return BattleShareData(
      quest: BattleQuestInfo.quest(quest),
      formation: _buildFormation(spec),
      delegate: delegateData,
      actions: _buildActionLog(spec),
    );
  }

  // ---------------------------------------------------------------------------
  // Formation helpers
  // ---------------------------------------------------------------------------

  static BattleTeamFormation _buildFormation(TeamSpec spec) {
    // slots[0..2] = frontline, slots[3..5] = backline.
    final svts = List<SvtSaveData?>.generate(
      6,
      (i) => i < spec.slots.length ? _buildSvtSaveData(spec.slots[i]) : null,
    );

    return BattleTeamFormation(
      svts: svts,
      mysticCode: MysticCodeSaveData(
        mysticCodeId: spec.mysticCode?.id,
        level: spec.mysticCodeLevel,
      ),
    );
  }

  static SvtSaveData? _buildSvtSaveData(SlotSpec? slot) {
    if (slot == null) return null;
    final svt = slot.svt;

    // Resolve the 3 active skill IDs using NA rank-ups — consistent with how
    // HeadlessRunner._buildPlayerSettings initialises the PlayerSvtData.
    final skillIds = List<int?>.generate(3, (i) {
      final candidates = svt.groupedActiveSkills[i + 1] ?? [];
      return svt.getDefaultSkill(candidates, Region.na)?.id;
    });

    // Resolve NP ID from the servant's first grouped NP (group 1 = base).
    final np = svt.groupedNoblePhantasms[1]?.firstOrNull;

    return SvtSaveData(
      svtId: svt.id,
      lv: slot.level,
      limitCount: slot.limitCount,
      skillIds: skillIds,
      skillLvs: List.of(slot.skillLevels),
      appendLvs: List.of(slot.appendLevels),
      tdId: np?.id ?? 0,
      tdLv: slot.tdLevel,
      atkFou: slot.atkFou,
      hpFou: slot.hpFou,
      equip1: SvtEquipSaveData(
        id: slot.ce?.id,
        limitBreak: slot.ceMlb,
        lv: slot.ceLevel,
      ),
      supportType: slot.isSupport ? SupportSvtType.friend : SupportSvtType.none,
    );
  }

  // ---------------------------------------------------------------------------
  // Action log helpers
  // ---------------------------------------------------------------------------

  static List<BattleRecordData> _buildActionLog(TeamSpec spec) {
    final actions = <BattleRecordData>[];

    for (final turn in spec.turns) {
      // Skill activations (servant skills and MC skills including Order Change).
      for (final skillAction in turn.skills) {
        final isMc = skillAction.slotIndex == -1;
        actions.add(BattleRecordData.skill(
          svt: isMc ? null : skillAction.slotIndex,
          skill: skillAction.skillIndex,
          options: BattleActionOptions(
            enemyTarget: skillAction.enemyTarget,
            // playerTarget: ally target if specified, else skill owner's slot.
            // Clamp to 0 for MC skills (no meaningful ally index).
            playerTarget: skillAction.allyTarget ??
                (isMc ? 0 : skillAction.slotIndex.clamp(0, 2)),
          ),
        ));
      }

      // NP attack — one attack record per NP-firing slot.
      if (turn.npSlots.isNotEmpty) {
        actions.add(BattleRecordData.attack(
          attacks: turn.npSlots
              .map((slot) => BattleAttackRecordData(svt: slot, isTD: true))
              .toList(),
        ));
      }
    }

    return actions;
  }
}
