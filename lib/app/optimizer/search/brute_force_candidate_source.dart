/// BruteForcePassCandidateSource — candidate generation strategy for the
/// Brute Force Pass.
///
/// Currently a stub: uses the same [Enumerator] + [Pruner] logic as
/// [RulesPassCandidateSource]. Cross-pass deduplication in the engine
/// means candidates already dispatched by the Rules Pass are skipped,
/// so including BruteForce in the active pass list is safe but produces
/// no extra work until this source's logic diverges from RulesPass.
///
/// Future: will be updated to use broader CE selection (including
/// OC-boosting CEs such as Duke of Flame), and potentially different
/// servant ordering to cover compositions that RulesPass deprioritises.
library;

import 'package:chaldea/models/models.dart';

import '../roster/user_roster.dart';
import 'candidate_source.dart';
import 'enumerator.dart';
import 'pruner.dart';

class BruteForcePassCandidateSource implements CandidateSource {
  @override
  final List<CandidateTeam> candidates;

  @override
  final int total;

  @override
  final int gate1Blocked;

  @override
  final int gate2Blocked;

  BruteForcePassCandidateSource._({
    required this.candidates,
    required this.total,
    required this.gate1Blocked,
    required this.gate2Blocked,
  });

  // ignore: unused_element
  factory BruteForcePassCandidateSource(QuestPhase quest, UserRoster roster) {
    // Stub — same logic as RulesPassCandidateSource until BruteForce
    // CE/servant selection is implemented.
    final enumerator = Enumerator(roster: roster, quest: quest);
    final pruner = Pruner(quest: quest, roster: roster);
    final passed = enumerator.candidates().where(pruner.passes).toList();
    return BruteForcePassCandidateSource._(
      candidates: passed,
      total: passed.length + pruner.gate1Blocked + pruner.gate2Blocked,
      gate1Blocked: pruner.gate1Blocked,
      gate2Blocked: pruner.gate2Blocked,
    );
  }
}
