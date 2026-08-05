import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import '../platform/relative_time.dart';
import '../theme.dart';
import '../widgets/console_shell.dart';
import '../widgets/dependency_spectrum.dart';
import '../widgets/project_card.dart';
import 'registry_console.dart';

/// One tab of the report, and what fills it.
class ReportTab {
  const ReportTab({required this.label, required this.body});

  final String label;

  /// Built lazily, so the three tabs nobody has opened do not each mount a
  /// table and a tree behind the one that is showing.
  final Widget Function() body;
}

/// The report, laid out for the console.
///
/// The one real departure from the compact layout: that screen is a single
/// scroll — summary, advisories, licenses, tree, table, in that order — and
/// this one splits the same content across tabs under a header that stays put.
///
/// The split is what the width is for. On a phone the sections are read in
/// sequence and the scroll *is* the navigation; on a monitor the reader is
/// usually here for one of the four and has to scroll past the other three to
/// reach it. What does not change is that the header keeps the numbers all four
/// tabs are judged against, so switching tab never loses the totals.
class ReportConsole extends StatefulWidget {
  const ReportConsole({
    required this.project,
    required this.report,
    required this.tabs,
    required this.onReanalyze,
    required this.isScanning,
    this.onExport,
    super.key,
  });

  final Project project;
  final DepReport report;
  final List<ReportTab> tabs;

  final VoidCallback onReanalyze;
  final bool isScanning;

  /// Null where a file cannot go anywhere, or before there is a report to
  /// write. Takes true for CSV.
  final void Function({required bool asCsv})? onExport;

  @override
  State<ReportConsole> createState() => _ReportConsoleState();
}

class _ReportConsoleState extends State<ReportConsole> {
  int _tab = 0;

  @override
  void didUpdateWidget(ReportConsole old) {
    super.didUpdateWidget(old);
    // A re-analysis can land while a tab is open, and the tab list is rebuilt
    // with it. Keep the selection in range rather than trusting it.
    if (_tab >= widget.tabs.length) _tab = 0;
  }

  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          project: widget.project,
          report: widget.report,
          onReanalyze: widget.onReanalyze,
          isScanning: widget.isScanning,
          onExport: widget.onExport,
        ),
        _TabBar(
          tabs: [for (final tab in widget.tabs) tab.label],
          selected: _tab,
          onSelect: (i) => setState(() => _tab = i),
        ),
        Expanded(
          child: Container(
            color: surfaces.page,
            child: ConsolePage(
              // Keyed so switching tab starts the new one at the top rather
              // than inheriting the scroll offset of the one before it.
              key: ValueKey(_tab),
              child: widget.tabs[_tab].body(),
            ),
          ),
        ),
      ],
    );
  }
}

/// What the project is, what it weighs, and the two things you can do to it.
class _Header extends StatelessWidget {
  const _Header({
    required this.project,
    required this.report,
    required this.onReanalyze,
    required this.isScanning,
    required this.onExport,
  });

  final Project project;
  final DepReport report;
  final VoidCallback onReanalyze;
  final bool isScanning;
  final void Function({required bool asCsv})? onExport;

  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);
    final theme = Theme.of(context);
    final graph = DependencyGraph.of(report);
    final weight = graph.weight;

    return Container(
      padding: const EdgeInsets.fromLTRB(40, 30, 40, 26),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: surfaces.hairline)),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                project.name,
                                overflow: TextOverflow.ellipsis,
                                style: displayOf(
                                    context, theme.textTheme.headlineSmall),
                              ),
                            ),
                            const SizedBox(width: 12),
                            // A ref names a commit somebody can go and look at.
                            // A local project's does not, so it says what it
                            // actually is instead.
                            ConsoleTag(
                              label: project.isLocal ? 'Local' : project.ref,
                            ),
                            if (project.isArchived) ...[
                              const SizedBox(width: 8),
                              ConsoleTag(
                                label: 'Archived',
                                tint: surfaces.minor,
                                filled: true,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          // A local project has no URL and is not meant to: a
                          // URL is the one thing about a private repository
                          // that would let a hosted service try to reach it.
                          project.gitUrl ?? 'uploaded with depcontrol collect',
                          style: monoOf(
                            context,
                            theme.textTheme.bodySmall,
                            color: surfaces.muted,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _age,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: project.isArchived
                                ? surfaces.minor
                                : surfaces.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 20),
                  _Actions(
                    // An archived project is a snapshot; the server refuses to
                    // re-analyze it, so offering the button would be a dead end.
                    onReanalyze: project.isArchived ? null : onReanalyze,
                    isScanning: isScanning,
                    onExport: onExport,
                  ),
                ],
              ),
              const SizedBox(height: 26),
              _Stats(project: project, report: report, weight: weight),
              const SizedBox(height: 22),
              _SemverBar(
                nodes: report.nodes,
                showCurrency: !project.isArchived,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get _age {
    if (project.archivedAt case final at?) {
      return 'Archived ${relativeAge(at)} — a snapshot of what this depended '
          'on, not kept up to date.';
    }

    // A local project has two ages and they mean different things. Its
    // advisories and licences are re-checked here on the ordinary schedule, but
    // its *dependency list* is as old as the last `depcontrol collect` — the
    // repository is somewhere this server has never been. Showing only the
    // server's timestamp would present a six-month-old dependency list as
    // though it had been read this morning.
    if (project.isLocal) {
      final collected = project.bundleCollectedAt;
      if (collected == null) return 'Collected on your own machine';
      if (collected.isAfter(DateTime.now().toUtc())) {
        // Self-reported by a client, so a future timestamp says the clock is
        // wrong rather than that the bundle is fresh.
        return 'Collected at a time this machine has not reached yet — the '
            'collecting machine\'s clock may be wrong.';
      }
      return 'Dependencies collected ${relativeAge(collected)}; advisories '
          're-checked here since.';
    }

    if (project.lastCheckedAt case final at?) {
      return 'Last analyzed ${relativeAge(at)}';
    }
    return 'Analyzed when added';
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.onReanalyze,
    required this.isScanning,
    required this.onExport,
  });

  final VoidCallback? onReanalyze;
  final bool isScanning;
  final void Function({required bool asCsv})? onExport;

  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);

    // Both controls are pinned to one height rather than each sizing to its own
    // content. They sit side by side and read as a pair, and a button that is
    // two pixels shorter than the one next to it looks like a mistake even when
    // nobody can say which of the two is wrong.
    return SizedBox(
      height: _actionHeight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isScanning)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 18),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (onReanalyze != null)
            OutlinedButton.icon(
              onPressed: onReanalyze,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Re-analyze'),
              style: OutlinedButton.styleFrom(
                // The theme's vertical padding would otherwise decide the
                // height, and it is set for buttons that stand alone.
                padding: const EdgeInsets.symmetric(horizontal: 16),
                minimumSize: const Size(0, _actionHeight),
              ),
            ),
          if (onExport != null) ...[
            const SizedBox(width: 10),
            PopupMenuButton<String>(
              tooltip: 'Export',
              onSelected: (choice) => onExport!(asCsv: choice == 'csv'),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'csv', child: Text('Download CSV')),
                PopupMenuItem(value: 'json', child: Text('Download JSON')),
              ],
              child: Container(
                height: _actionHeight,
                width: _actionHeight,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: surfaces.raised,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: surfaces.hairline),
                ),
                child: Icon(Icons.download_outlined,
                    size: 19, color: surfaces.text),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The height every control in the report header is drawn at.
const _actionHeight = 40.0;

/// The four figures the whole report is judged against.
class _Stats extends StatelessWidget {
  const _Stats({
    required this.project,
    required this.report,
    required this.weight,
  });

  final Project project;
  final DepReport report;
  final SizeTally weight;

  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);

    final cards = <Widget>[
      _StatCard(label: 'Dependencies', figure: '${report.total}'),
      // "Outdated" is a comparison against pub.dev as it is now, which is what
      // archiving stepped away from. Advisories are facts about the snapshot,
      // so they stay.
      if (!project.isArchived)
        _StatCard(
          label: 'Outdated',
          figure: '${report.outdated}',
          tint: report.outdated > 0 ? surfaces.minor : null,
        ),
      _StatCard(
        label: 'Vulnerable',
        figure: '${report.vulnerable}',
        tint: report.vulnerable > 0 ? surfaces.alarm : null,
      ),
      // Shown only where the repository is one ecosystem and there is therefore
      // one scale to report it on. Where it holds both, the two figures do not
      // belong side by side pretending to be one number.
      if (weight.bases.length == 1)
        _StatCard(
          label: weight.bases.single.label,
          figure: PackageSize.formatBytes(weight.bytesOn(weight.bases.single)),
        ),
    ];

    // Intrinsic height rather than a bare stretch: the header sits in a column
    // with no height of its own, so `stretch` alone hands the cards an infinite
    // constraint. This measures the tallest and levels the rest to it, which is
    // the equal-height row the stretch was reaching for.
    //
    // Gaps go between the cards rather than after each, so the row ends flush
    // with the header above it instead of eighteen pixels short.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            if (i > 0) const SizedBox(width: 18),
            cards[i],
          ],
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.figure, this.tint});

  final String label;
  final String figure;

  /// Set only where the figure is a finding. A dependency count is not.
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);
    final theme = Theme.of(context);

    return Expanded(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        decoration: BoxDecoration(
          color: surfaces.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: surfaces.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label.toUpperCase(),
              style: monoOf(
                context,
                theme.textTheme.labelSmall,
                color: surfaces.muted,
              ).copyWith(letterSpacing: 0.8, fontSize: 10),
            ),
            const SizedBox(height: 6),
            Text(
              figure,
              style: displayOf(
                context,
                theme.textTheme.headlineSmall,
                color: tint,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The tree as one proportional bar, worst first.
///
/// The compact layout draws a tick per package instead, and that remains the
/// better picture — it says *eighteen out of a hundred and fifty* rather than
/// a ratio. This is the header of a page whose tabs carry the detail, and at
/// this size the shape is what has to survive; the counts are spelled out
/// underneath so nothing rests on reading a width.
class _SemverBar extends StatelessWidget {
  const _SemverBar({required this.nodes, required this.showCurrency});

  final List<DepNode> nodes;
  final bool showCurrency;

  @override
  Widget build(BuildContext context) {
    if (nodes.isEmpty) return const SizedBox.shrink();

    final surfaces = Surfaces.of(context);
    final theme = Theme.of(context);
    final counts = DepBand.tally(nodes, showCurrency: showCurrency);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(
            height: 8,
            child: Row(
              children: [
                for (final entry in counts.entries)
                  Expanded(
                    flex: entry.value,
                    child: Container(
                      margin: const EdgeInsets.only(right: 2),
                      color: entry.key.colorOn(surfaces),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 22,
          runSpacing: 8,
          children: [
            for (final entry in counts.entries)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: entry.key.colorOn(surfaces),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    '${entry.value} ${entry.key.label}',
                    style: monoOf(
                      context,
                      theme.textTheme.labelSmall,
                      color: surfaces.muted,
                    ).copyWith(letterSpacing: 0.6, fontSize: 10.5),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

/// The row of tabs under the header.
class _TabBar extends StatelessWidget {
  const _TabBar({
    required this.tabs,
    required this.selected,
    required this.onSelect,
  });

  final List<String> tabs;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: surfaces.isDark
            ? Console.sidebar.withValues(alpha: 0.5)
            : surfaces.card,
        border: Border(bottom: BorderSide(color: surfaces.hairline)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: Row(
            children: [
              for (var i = 0; i < tabs.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 30),
                  child: InkWell(
                    onTap: () => onSelect(i),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            width: 2,
                            color: i == selected
                                ? surfaces.accent
                                : Colors.transparent,
                          ),
                        ),
                      ),
                      child: Text(
                        tabs[i].toUpperCase(),
                        style: monoOf(
                          context,
                          theme.textTheme.labelMedium,
                          color:
                              i == selected ? surfaces.text : surfaces.muted,
                          weight: i == selected
                              ? FontWeight.w700
                              : FontWeight.w400,
                        ).copyWith(letterSpacing: 0.8, fontSize: 11),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A titled card in the console's content column.
class ConsoleCard extends StatelessWidget {
  const ConsoleCard({
    required this.child,
    this.eyebrow,
    this.subtitle,
    this.padding = const EdgeInsets.fromLTRB(22, 20, 22, 20),
    super.key,
  });

  final Widget child;
  final String? eyebrow;
  final String? subtitle;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);
    final theme = Theme.of(context);

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: surfaces.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: surfaces.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (eyebrow != null) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: ConsoleEyebrow(eyebrow!),
            ),
            const SizedBox(height: 12),
          ],
          if (subtitle != null) ...[
            Text(
              subtitle!,
              style: theme.textTheme.bodySmall?.copyWith(color: surfaces.muted),
            ),
            const SizedBox(height: 12),
          ],
          child,
        ],
      ),
    );
  }
}
