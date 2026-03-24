/// HeadlessRunner — drives Chaldea's BattleData programmatically with no UI.
///
/// This is the core of the optimizer: given a fully-specified team (servants,
/// CEs, MC) and a quest, it runs the battle and reports whether the team
/// cleared in ≤3 turns. It is designed to be instantiated fresh for each
/// candidate team and called from an Isolate.
///
/// Usage:
///   final runner = HeadlessRunner(quest: questPhase);
///   final result = await runner.run(spec: spec);
///   if (result.cleared && result.totalTurns <= 3) { ... }
library;

import 'dart:developer' as dev;

import 'package:tuple/tuple.dart';

import 'package:chaldea/app/battle/interactions/_delegate.dart';
import 'package:chaldea/app/battle/models/battle.dart';
import 'package:chaldea/models/models.dart';
import 'package:chaldea/utils/extension.dart';

// ---------------------------------------------------------------------------
// Data types the caller fills in
// ---------------------------------------------------------------------------

/// One servant slot in the team (may be null = empty slot).
class SlotSpec {
  final Servant svt;
  final int level;
  final int limitCount; // ascension (0-4)
  final int tdLevel; // 1-5
  final List<int> skillLevels; // [s1, s2, s3], each 1-10
  final List<int> appendLevels; // [a1, a2, a3], each 0-10
  final int atkFou; // 0-2000
  final int hpFou; // 0-2000
  final CraftEssence? ce; // null = no CE
  final bool ceMlb;
  final int ceLevel;
  final bool isSupport; // true = borrowed support servant

  const SlotSpec({
    required this.svt,
    required this.level,
    this.limitCount = 4,
    this.tdLevel = 5,
    required this.skillLevels,
    this.appendLevels = const [0, 0, 0],
    this.atkFou = 1000,
    this.hpFou = 1000,
    this.ce,
    this.ceMlb = false,
    this.ceLevel = 1,
    this.isSupport = false,
  });
}

/// The full team specification passed to [HeadlessRunner.run].
///
/// [slots] has up to 6 entries: slots 0-2 are the starting frontline,
/// slots 3-5 are the backline. Pass null for an empty slot.
class TeamSpec {
  final List<SlotSpec?> slots; // length 1-6, null = empty
  final MysticCode? mysticCode;
  final int mysticCodeLevel;

  /// The skill/MC activation sequence for each turn, executed before
  /// the NP attack. Each entry in [turns] is the list of actions for
  /// one turn (before the NP fire).
  final List<TurnActions> turns;

  const TeamSpec({
    required this.slots,
    this.mysticCode,
    this.mysticCodeLevel = 10,
    required this.turns,
  });
}

/// Actions to perform on a single turn before firing NPs.
class TurnActions {
  /// Ordered list of skill activations for this turn.
  final List<SkillAction> skills;

  /// Which servants fire their NP this turn (by slot index 0-2).
  /// Usually just one for 3-turn farming, but can be multiple.
  final List<int> npSlots;

  /// Optional: Order Change swap to execute this turn.
  /// Provide the on-field slot index and the backline slot index.
  final OrderChangeAction? orderChange;

  const TurnActions({
    this.skills = const [],
    required this.npSlots,
    this.orderChange,
  });
}

/// A single skill activation: which servant (slot 0-2 for active servants,
/// or -1 for MC) and which skill (0-2).
class SkillAction {
  /// Slot index 0-2 for servant skills, or -1 for mystic code.
  final int slotIndex;

  /// Skill index 0-2.
  final int skillIndex;

  /// For single-target skills: which enemy slot to target (0-2).
  /// Defaults to 0 (the first/only enemy for most farming waves).
  final int enemyTarget;

  /// For targeted ally skills: which ally slot to target (0-2).
  /// Defaults to the skill owner's slot.
  final int? allyTarget;

  const SkillAction({
    required this.slotIndex,
    required this.skillIndex,
    this.enemyTarget = 0,
    this.allyTarget,
  });
}

/// Order Change: swap a frontline servant out for a backline servant.
class OrderChangeAction {
  /// On-field slot index (0-2) to swap out.
  final int onFieldSlot;

  /// Backline slot index (0-2, relative to backupAllyServants list) to swap in.
  final int backlineSlot;

  const OrderChangeAction({required this.onFieldSlot, required this.backlineSlot});
}

// ---------------------------------------------------------------------------
// Result
// ---------------------------------------------------------------------------

enum SimulationOutcome {
  /// All waves cleared within the turn limit.
  cleared,

  /// Battle ran but did not win within maxTurns.
  notCleared,

  /// An exception was thrown during simulation.
  error,
}

class SimulationResult {
  final SimulationOutcome outcome;
  final int totalTurns;
  final String? errorMessage;

  bool get cleared => outcome == SimulationOutcome.cleared;

  const SimulationResult._({
    required this.outcome,
    required this.totalTurns,
    this.errorMessage,
  });

  factory SimulationResult.cleared(int turns) =>
      SimulationResult._(outcome: SimulationOutcome.cleared, totalTurns: turns);

  factory SimulationResult.notCleared(int turns) =>
      SimulationResult._(outcome: SimulationOutcome.notCleared, totalTurns: turns);

  factory SimulationResult.error(String msg) =>
      SimulationResult._(outcome: SimulationOutcome.error, totalTurns: -1, errorMessage: msg);

  @override
  String toString() => 'SimulationResult($outcome, turns=$totalTurns'
      '${errorMessage != null ? ", error=$errorMessage" : ""})';
}

// ---------------------------------------------------------------------------
// HeadlessRunner
// ---------------------------------------------------------------------------

/// Maximum turns we simulate before declaring a failure.
const int _kMaxTurns = 3;

class HeadlessRunner {
  final QuestPhase quest;

  HeadlessRunner({required this.quest});

  /// Runs the simulation for the given [spec]. Returns immediately
  /// (async but CPU-bound — run this inside a Dart Isolate for parallelism).
  ///
  /// [pessimistic] switches damage RNG to the minimum value instead of the
  /// maximum. Use this to check whether a spec is a *guaranteed* clear (no
  /// RNG required) after confirming it clears at max damage.
  Future<SimulationResult> run(TeamSpec spec, {bool pessimistic = false}) async {
    try {
      return await _simulate(spec, pessimistic: pessimistic);
    } catch (e, st) {
      return SimulationResult.error('$e\n$st');
    }
  }

  /// Replays a [BattleShareData] record and returns the simulation result.
  ///
  /// Uses [BattleReplayDelegate] to faithfully reproduce the action sequence
  /// stored in [shareData.actions]. This mirrors the pattern used by
  /// [BattleSimulationState.replay] in Chaldea's main UI.
  ///
  /// Typical uses:
  ///   - Verify a [RunRecord.battleData] still clears after a game data update.
  ///   - Replay community share links directly without converting to [TeamSpec].
  Future<SimulationResult> runFromShareData(BattleShareData shareData) async {
    try {
      return await _simulateFromShareData(shareData);
    } catch (e, st) {
      return SimulationResult.error('$e\n$st');
    }
  }

  Future<SimulationResult> _simulate(TeamSpec spec, {bool pessimistic = false}) async {
    // --- 1. Build PlayerSvtData list ---
    final playerSettings = _buildPlayerSettings(spec);

    // --- 2. Build MysticCodeData ---
    final mcData = _buildMysticCodeData(spec);

    // --- 3. Set up BattleData ---
    final battleData = BattleData();
    // context is null by default → mounted = false → no UI dialogs
    // options.manualAllySkillTarget is false by default → _acquireTarget is a no-op
    // options.tailoredExecution = false (don't wait for tailored execution confirm)

    // Inject a delegate to handle Order Change and randomness deterministically.
    // damageRandom = max value gives us the upper-bound damage estimate (optimistic).
    // pessimistic=true uses min to check whether a clear is guaranteed (no RNG needed).
    battleData.delegate = _buildDelegate(spec, pessimistic: pessimistic);

    dev.Timeline.startSync('BattleData.init');
    await battleData.init(quest, playerSettings, mcData);
    dev.Timeline.finishSync(); // BattleData.init
    // Snapshots are taken before each action for undo support. We never undo
    // in headless mode, so clear after init to avoid carrying stale copies.
    battleData.snapshots.clear();

    // --- 4. Execute turn sequence ---
    dev.Timeline.startSync('BattleData.turns');
    for (int turnIndex = 0; turnIndex < spec.turns.length; turnIndex++) {
      if (battleData.isBattleWin) break;
      if (battleData.isBattleFinished) break;

      final turnActions = spec.turns[turnIndex];

      // Activate skills in order
      for (final skillAction in turnActions.skills) {
        if (skillAction.slotIndex == -1) {
          // Mystic Code skill
          await battleData.activateMysticCodeSkill(skillAction.skillIndex);
        } else {
          // Set target indices before activation for targeted skills
          battleData.enemyTargetIndex = skillAction.enemyTarget;
          if (skillAction.allyTarget != null) {
            battleData.playerTargetIndex = skillAction.allyTarget!;
          }
          await battleData.activateSvtSkill(skillAction.slotIndex, skillAction.skillIndex);
        }
        // Discard the undo snapshot and battle records — we never replay or
        // display anything in headless mode, so keeping these is pure waste.
        // Clearing between actions means each snapshot only copies a tiny recorder.
        battleData.snapshots.clear();
        battleData.recorder.records.clear();
      }

      // Build NP CombatActions
      final actions = <CombatAction>[];
      for (final npSlot in turnActions.npSlots) {
        final svt = battleData.onFieldAllyServants.getOrNull(npSlot);
        if (svt == null) continue;
        final npCard = svt.getNPCard();
        if (npCard == null) continue;
        if (svt.canNP()) {
          actions.add(CombatAction(svt, npCard));
        }
      }

      if (actions.isNotEmpty) {
        await battleData.playerTurn(actions, allowSkip: false);
      } else if (turnActions.npSlots.isEmpty) {
        // A pure skill-only turn with no NP (uncommon in farming)
        await battleData.playerTurn([], allowSkip: true);
      }
      // If we expected NPs but none were ready, that's a failure path —
      // fall through and let isBattleWin = false handle it.
      battleData.snapshots.clear();
      battleData.recorder.records.clear();

      if (battleData.isBattleWin) break;
    }
    dev.Timeline.finishSync(); // BattleData.turns

    // --- 5. Report result ---
    final turns = battleData.totalTurnCount;
    if (battleData.isBattleWin && turns <= _kMaxTurns) {
      return SimulationResult.cleared(turns);
    }
    return SimulationResult.notCleared(turns);
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  List<PlayerSvtData?> _buildPlayerSettings(TeamSpec spec) {
    return spec.slots.map((slot) {
      if (slot == null) return null;

      final data = PlayerSvtData.svt(slot.svt)
        ..lv = slot.level
        ..limitCount = slot.limitCount
        ..tdLv = slot.tdLevel
        ..skillLvs = List.of(slot.skillLevels)
        ..appendLvs = List.of(slot.appendLevels)
        ..atkFou = slot.atkFou
        ..hpFou = slot.hpFou
        ..supportType = slot.isSupport ? SupportSvtType.friend : SupportSvtType.none
        // Use NA region so we only apply rank-ups available on NA.
        // NA players can't access JP-only interludes/strengthening quests yet.
        ..updateRankUps(region: Region.na);

      if (slot.ce != null) {
        data.equip1
          ..ce = slot.ce
          ..limitBreak = slot.ceMlb
          ..lv = slot.ceLevel;
      }

      return data;
    }).toList();
  }

  MysticCodeData? _buildMysticCodeData(TeamSpec spec) {
    if (spec.mysticCode == null) return null;
    return MysticCodeData()
      ..mysticCode = spec.mysticCode
      ..level = spec.mysticCodeLevel;
  }

  BattleDelegate _buildDelegate(TeamSpec spec, {bool pessimistic = false}) {
    final delegate = BattleDelegate();

    // Deterministic damage: optimistic (max) by default to find all possible clears.
    // pessimistic (min) is used to check whether a clear is guaranteed with no RNG.
    delegate.damageRandom = (curRandom) async {
      return pessimistic
          ? ConstData.constants.attackRateRandomMin
          : ConstData.constants.attackRateRandomMax;
    };

    // Skills that have activation rates (< 100%) — force them to activate.
    // This models "assume skills work" for farming purposes.
    delegate.canActivate = (curResult) async => true;

    // Order Change: fulfilled from the spec's TurnActions.
    // We store pending swaps in a queue derived from the spec.
    final swapQueue = <OrderChangeAction>[];
    for (final turn in spec.turns) {
      if (turn.orderChange != null) swapQueue.add(turn.orderChange!);
    }
    if (swapQueue.isNotEmpty) {
      delegate.replaceMember = (onFieldSvts, backupSvts) async {
        if (swapQueue.isEmpty) return null;
        final swap = swapQueue.removeAt(0);
        final onField = onFieldSvts.getOrNull(swap.onFieldSlot);
        final backup = backupSvts.getOrNull(swap.backlineSlot);
        if (onField == null || backup == null) return null;
        return Tuple2(onField, backup);
      };
    }

    return delegate;
  }

  // -------------------------------------------------------------------------
  // runFromShareData implementation
  // -------------------------------------------------------------------------

  Future<SimulationResult> _simulateFromShareData(BattleShareData shareData) async {
    final playerSettings =
        shareData.formation.svts.map(_buildPlayerSettingsFromSaveData).toList();
    final mcData = _buildMysticCodeDataFromSaveData(shareData.formation.mysticCode);

    final battleData = BattleData();
    battleData.delegate =
        BattleReplayDelegate(shareData.delegate ?? BattleReplayDelegateData());

    await battleData.init(quest, playerSettings, mcData);
    battleData.snapshots.clear();

    for (final action in shareData.actions) {
      battleData.playerTargetIndex = action.options.playerTarget;
      battleData.enemyTargetIndex = action.options.enemyTarget;

      if (action.type == BattleRecordDataType.skill) {
        if (action.skill == null) continue;
        if (action.svt == null) {
          await battleData.activateMysticCodeSkill(action.skill!);
        } else {
          await battleData.activateSvtSkill(action.svt!, action.skill!);
        }
        battleData.snapshots.clear();
      } else if (action.type == BattleRecordDataType.attack) {
        if (action.attacks == null) continue;
        final combatActions = <CombatAction>[];
        for (final attackRecord in action.attacks!) {
          final svt = battleData.onFieldAllyServants.getOrNull(attackRecord.svt);
          if (svt == null) continue;
          CommandCardData? card;
          if (attackRecord.isTD) {
            card = svt.getNPCard();
          } else if (attackRecord.card != null) {
            final cards = svt.getCards();
            final idx = attackRecord.card!;
            if (idx >= 0 && idx < cards.length) card = cards[idx];
          }
          if (card == null) continue;
          card.critical = attackRecord.critical;
          combatActions.add(CombatAction(svt, card));
        }
        if (combatActions.isNotEmpty) {
          await battleData.playerTurn(combatActions);
          battleData.snapshots.clear();
        }
      }

      if (battleData.isBattleWin || battleData.isBattleFinished) break;
    }

    final turns = battleData.totalTurnCount;
    if (battleData.isBattleWin && turns <= _kMaxTurns) {
      return SimulationResult.cleared(turns);
    }
    return SimulationResult.notCleared(turns);
  }

  PlayerSvtData? _buildPlayerSettingsFromSaveData(SvtSaveData? saveData) {
    if (saveData == null || saveData.svtId == null) return null;
    final svt = db.gameData.servantsById[saveData.svtId!];
    if (svt == null) return null;

    final data = PlayerSvtData.svt(svt)
      ..lv = saveData.lv
      ..limitCount = saveData.limitCount
      ..tdLv = saveData.tdLv
      ..skillLvs = List.of(saveData.skillLvs)
      ..appendLvs = List.of(saveData.appendLvs)
      ..atkFou = saveData.atkFou
      ..hpFou = saveData.hpFou
      ..supportType = saveData.supportType
      ..updateRankUps(region: Region.na);

    if (saveData.equip1.id != null) {
      final ce = db.gameData.craftEssencesById[saveData.equip1.id!];
      if (ce != null) {
        data.equip1
          ..ce = ce
          ..limitBreak = saveData.equip1.limitBreak
          ..lv = saveData.equip1.lv;
      }
    }

    return data;
  }

  MysticCodeData? _buildMysticCodeDataFromSaveData(MysticCodeSaveData saveData) {
    final mcId = saveData.mysticCodeId;
    if (mcId == null || mcId == 0) return null;
    final mc = db.gameData.mysticCodes[mcId];
    if (mc == null) return null;
    return MysticCodeData()
      ..mysticCode = mc
      ..level = saveData.level;
  }
}

