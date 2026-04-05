/// BruteForceDebugTab — shows Brute Force pass results in the Debug tab.
///
/// Displays gate stats, cross-pass dedup breakdown, and either the number
/// of candidates dispatched + clears found (normal run) or the number that
/// would survive dedup (dry run).
library;

import 'package:flutter/material.dart';

import 'run_notifier.dart';

class BruteForceDebugTab extends StatelessWidget {
  const BruteForceDebugTab({super.key});

  @override
  Widget build(BuildContext context) {
    final run = RunScope.of(context);
    final report = run.bruteForceReport;

    if (report == null) {
      String msg;
      if (run.isRunning) {
        msg = 'Brute Force pass running...';
      } else if (!run.enableBruteForcePass) {
        msg = 'Brute Force pass is disabled.\nEnable it in the System tab.';
      } else if (run.specsChecked == 0 && run.candidatesTotal == 0) {
        msg = 'No run data yet.';
      } else {
        msg = 'Brute Force pass has not run yet.';
      }
      return Center(
        child: Text(
          msg,
          style: Theme.of(context).textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (report.isDryRun) _DryRunBanner(),
        const SizedBox(height: 12),
        _Section(
          title: 'Candidate generation',
          rows: [
            _Row('Total before gates', '${report.total}'),
            _Row('Blocked by Gate 1 (NP charge)', '${report.gate1Blocked}',
                faint: true),
            _Row('Blocked by Gate 2 (damage est.)', '${report.gate2Blocked}',
                faint: true),
            _Row('Passed gates', '${report.total - report.gate1Blocked - report.gate2Blocked}',
                bold: true),
          ],
        ),
        const SizedBox(height: 16),
        _Section(
          title: 'Cross-pass deduplication',
          rows: [
            _Row('Skipped — full-team sig already tried',
                '${report.dedupSigHits}', faint: true),
            _Row('Skipped — servant set already cleared',
                '${report.dedupSvtHits}', faint: true),
            _Row(
              report.isDryRun ? 'Would be dispatched' : 'Dispatched',
              '${report.dispatched}',
              bold: true,
              color: report.isDryRun ? Colors.orange : null,
            ),
          ],
        ),
        if (!report.isDryRun) ...[
          const SizedBox(height: 16),
          _Section(
            title: 'Results',
            rows: [
              _Row('Clears found', '${report.clears}',
                  bold: true,
                  color: report.clears > 0 ? Colors.green : null),
            ],
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _DryRunBanner
// ---------------------------------------------------------------------------

class _DryRunBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.science_outlined, size: 16, color: Colors.orange),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Dry run — candidates counted but not simulated.',
              style: const TextStyle(fontSize: 12, color: Colors.orange),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _Section + _Row helpers
// ---------------------------------------------------------------------------

class _Section extends StatelessWidget {
  final String title;
  final List<_Row> rows;

  const _Section({required this.title, required this.rows});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: Theme.of(context).colorScheme.primary)),
        const SizedBox(height: 6),
        ...rows,
      ],
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  final bool bold;
  final bool faint;
  final Color? color;

  const _Row(this.label, this.value,
      {this.bold = false, this.faint = false, this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveColor =
        color ?? (faint ? theme.hintColor : theme.colorScheme.onSurface);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(color: effectiveColor),
            ),
          ),
          Text(
            value,
            style: theme.textTheme.bodySmall?.copyWith(
              color: effectiveColor,
              fontWeight: bold ? FontWeight.bold : null,
            ),
          ),
        ],
      ),
    );
  }
}
