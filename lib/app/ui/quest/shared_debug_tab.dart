/// SharedDebugTab — shows Shared Pass results in the Debug tab.
///
/// Displays each community team that was tried (player owns all servants and
/// MC), and whether it produced a clear.
library;

import 'package:flutter/material.dart';

import 'package:chaldea/models/models.dart';

import 'run_notifier.dart';

class SharedDebugTab extends StatelessWidget {
  const SharedDebugTab({super.key});

  @override
  Widget build(BuildContext context) {
    final run = RunScope.of(context);
    final teams = run.sharedPassTeams;

    final hasRunData = run.specsChecked > 0 || run.candidatesTotal > 0 ||
        run.sharedPassFetched > 0;

    if (teams.isEmpty) {
      String msg;
      if (run.isRunning) {
        msg = 'Shared Pass running...';
      } else if (!hasRunData) {
        msg = 'No run data yet.';
      } else if (run.sharedPassFetched == 0) {
        msg = 'No community teams found for this quest.';
      } else {
        // fetched > 0 but all skipped
        msg = 'Community teams found: ${run.sharedPassFetched}, '
            'but none are fieldable with your roster.';
      }
      return Center(
        child: Text(msg, style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center),
      );
    }

    final clears = teams.where((t) => t.cleared).length;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Text(
                'Fetched: ${run.sharedPassFetched}'
                '  •  Skipped: ${run.sharedPassSkipped}'
                '  •  Tried: ${teams.length}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(width: 12),
              if (clears > 0) _ClearChip(count: clears),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: teams.length,
            separatorBuilder: (_, _) =>
                const Divider(height: 1, indent: 16, endIndent: 16),
            itemBuilder: (context, i) => _TeamRow(team: teams[i]),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _TeamRow — one tried community team
// ---------------------------------------------------------------------------

class _TeamRow extends StatelessWidget {
  final SharedTriedTeam team;

  const _TeamRow({required this.team});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final supportName = _svtName(team.supportId);
    final playerNames = team.playerIds.map(_svtName).join(', ');
    final mcName = team.mcId != null
        ? (db.gameData.mysticCodes[team.mcId]?.lName.l ?? 'MC #${team.mcId}')
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            team.cleared
                ? Icons.check_circle_outline
                : Icons.radio_button_unchecked,
            size: 16,
            color: team.cleared ? Colors.green : theme.disabledColor,
          ),
          const SizedBox(width: 8),
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
// _ClearChip
// ---------------------------------------------------------------------------

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
