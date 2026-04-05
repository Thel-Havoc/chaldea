/// PatternDebugTab — shows Pattern Pass results in the Debug tab.
///
/// Displays which source quests were matched as similar, which teams were
/// tried from each, and which of those teams produced a clear.
library;

import 'package:flutter/material.dart';

import 'package:chaldea/models/models.dart';

import '../../optimizer/roster/run_history.dart';
import 'run_notifier.dart';

class PatternDebugTab extends StatelessWidget {
  const PatternDebugTab({super.key});

  @override
  Widget build(BuildContext context) {
    final run = RunScope.of(context);
    final matches = run.patternPassMatches;

    if (matches.isEmpty) {
      return Center(
        child: Text(
          run.isRunning
              ? 'Pattern Pass running...'
              : run.specsChecked == 0 && run.candidatesTotal == 0
                  ? 'No run data yet.'
                  : 'No similar quests found by Pattern Pass.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }

    // Index Pattern Pass clears by sourceQuestId for quick lookup.
    final clearsBySource = <int, List<RunRecord>>{};
    for (final record in run.clears) {
      if (record.passName == 'Pattern' && record.sourceQuestId != null) {
        clearsBySource.putIfAbsent(record.sourceQuestId!, () => []).add(record);
      }
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: matches.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 16, endIndent: 16),
      itemBuilder: (context, i) {
        final match = matches[i];
        final clears = clearsBySource[match.sourceQuestId] ?? [];
        return _MatchCard(match: match, clears: clears);
      },
    );
  }
}

// ---------------------------------------------------------------------------
// _MatchCard — one source quest with its tried teams
// ---------------------------------------------------------------------------

class _MatchCard extends StatelessWidget {
  final PatternQuestMatch match;
  final List<RunRecord> clears;

  const _MatchCard({required this.match, required this.clears});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final questName = db.gameData.quests[match.sourceQuestId]?.lName.l
        ?? 'Quest #${match.sourceQuestId}';
    final scoreStr = (match.score * 100).toStringAsFixed(1);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row: quest name + score chip + clear count
          Row(
            children: [
              Expanded(
                child: Text(
                  questName,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              _ScoreChip(score: match.score, label: '$scoreStr%'),
              if (clears.isNotEmpty) ...[
                const SizedBox(width: 8),
                _ClearChip(count: clears.length),
              ],
            ],
          ),
          const SizedBox(height: 6),
          // Teams tried
          ...match.triedTeams.map((team) {
            // A team cleared if there's a Pattern clear from this source whose
            // servant set overlaps — best we can tell without a per-team ID.
            // We mark all teams as cleared when at least one clear came from
            // this source, since we can't match individual tried↔cleared teams.
            final cleared = clears.isNotEmpty;
            return _TeamRow(team: team, cleared: cleared);
          }),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _TeamRow — one tried team
// ---------------------------------------------------------------------------

class _TeamRow extends StatelessWidget {
  final TriedTeam team;
  final bool cleared;

  const _TeamRow({required this.team, required this.cleared});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final supportName = _svtName(team.supportId);
    final playerNames = team.playerIds.map(_svtName).join(', ');
    final mcName = team.mcId != null
        ? (db.gameData.mysticCodes[team.mcId]?.lName.l ?? 'MC #${team.mcId}')
        : null;

    return Padding(
      padding: const EdgeInsets.only(top: 4, left: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            cleared ? Icons.check_circle_outline : Icons.radio_button_unchecked,
            size: 14,
            color: cleared ? Colors.green : theme.disabledColor,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: theme.textTheme.bodySmall,
                children: [
                  TextSpan(text: playerNames),
                  TextSpan(
                    text: '  +  $supportName (support)',
                    style: TextStyle(color: theme.hintColor),
                  ),
                  if (mcName != null)
                    TextSpan(
                      text: '  |  $mcName',
                      style: TextStyle(color: theme.hintColor),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _svtName(int id) =>
      db.gameData.servantsById[id]?.lName.l ?? 'Servant #$id';
}

// ---------------------------------------------------------------------------
// Small chips
// ---------------------------------------------------------------------------

class _ScoreChip extends StatelessWidget {
  final double score;
  final String label;

  const _ScoreChip({required this.score, required this.label});

  @override
  Widget build(BuildContext context) {
    final color = score >= 0.8
        ? Colors.green
        : score >= 0.65
            ? Colors.orange
            : Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _ClearChip extends StatelessWidget {
  final int count;

  const _ClearChip({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.green.withValues(alpha: 0.5)),
      ),
      child: Text(
        '$count clear${count == 1 ? '' : 's'}',
        style: const TextStyle(
            fontSize: 11, color: Colors.green, fontWeight: FontWeight.w600),
      ),
    );
  }
}
