import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import '../api/api_client.dart';
import '../widgets/dep_status_chip.dart';
import '../widgets/dep_table.dart';
import '../widgets/dependency_path.dart';
import '../widgets/remediation_panel.dart';
import '../widgets/severity_chip.dart';

/// The dependency report for one project: a summary, a sortable table, and the
/// dependency graph.
class ReportScreen extends StatefulWidget {
  const ReportScreen({
    required this.project,
    required this.api,
    super.key,
  });

  final Project project;
  final ApiClient api;

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  late Future<DepReport?> _report;
  late Project _project;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _project = widget.project;
    _report = widget.api.report(_project.id);
  }

  void _reload() {
    setState(() => _report = widget.api.report(_project.id));
  }

  /// Re-fetches the repository and re-analyzes it, rather than re-reading the
  /// stored report.
  Future<void> _reanalyze() async {
    setState(() => _refreshing = true);
    try {
      final (project, report) = await widget.api.refreshProject(_project.id);
      if (!mounted) return;
      setState(() {
        _project = project;
        _report = Future.value(report);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Re-analyzed ${report.total} dependencies.')),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  /// Shows how a package ends up in the project.
  void _explain(DepNode node, DepReport report) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => SingleChildScrollView(
        child: PackageDetailView(
          package: node.name,
          nodes: report.nodes,
          selected: node,
          showCurrency: !_project.isArchived,
          // No loader for an archived project: the sheet then explains why the
          // package is present without asking what upgrading it would involve.
          onLoadDetails: _project.isArchived
              ? null
              : () => widget.api.upgradeDetails(_project.id, node.name),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (context) => Scaffold(
        appBar: AppBar(
          title: Text(_project.name),
          actions: [
            // An archived project is a snapshot; the server refuses to
            // re-analyze it, so offering the button would be a dead end.
            if (_project.isArchived)
              const SizedBox.shrink()
            else if (_refreshing)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else
              TextButton.icon(
                onPressed: _reanalyze,
                icon: const Icon(Icons.sync),
                label: const Text('Re-analyze'),
              ),
          ],
        ),
        body: FutureBuilder<DepReport?>(
          future: _report,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return _Message(
                icon: Icons.error_outline,
                text: snap.error is ApiException
                    ? (snap.error! as ApiException).message
                    : 'Could not load the report.',
                isError: true,
                onRetry: _reload,
              );
            }

            final report = snap.data;
            if (report == null || report.nodes.isEmpty) {
              return const _Message(
                icon: Icons.inbox_outlined,
                text: 'No dependency report for this project yet.',
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Summary(project: _project, report: report),
                const Divider(height: 1),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Advisories are facts about the versions in the
                        // snapshot, so they stay. Planning a fix is not — it
                        // re-fetches the repository, which archiving opted out
                        // of — so an archived project gets no remediation.
                        if (report.vulnerable > 0) ...[
                          _Advisories(
                            report: report,
                            onLoadRemediation: _project.isArchived
                                ? null
                                : () => widget.api.remediation(_project.id),
                          ),
                          const SizedBox(height: 16),
                        ],
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            _project.isArchived
                                ? 'Select a package to see why it is here.'
                                : 'Select a package to see why it is here and '
                                    'what upgrading it involves.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        DepTable(
                          nodes: report.nodes,
                          showCurrency: !_project.isArchived,
                          onSelect: (node) => _explain(node, report),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.project, required this.report});

  final Project project;
  final DepReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unknown =
        report.nodes.where((n) => n.status == DepStatus.unknown).length;
    final inferred =
        report.nodes.where((n) => n.source == DepSource.constraint).length;

    // Split the available upgrades by whether the author declared them
    // breaking, since that is what decides whether a human has to read
    // anything before taking them.
    final assessments = report.nodes.map(assessUpgrade).toList();
    final breaking =
        assessments.where((a) => a.risk == UpgradeRisk.breaking).length;
    final routine = assessments
        .where((a) =>
            a.risk == UpgradeRisk.minor || a.risk == UpgradeRisk.patch)
        .length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${project.gitUrl} @ ${project.ref}',
            style: theme.textTheme.bodySmall,
          ),
          Text(
            project.isArchived
                ? 'Archived ${_ago(project.archivedAt!)} — a snapshot of what '
                    'this depended on, not kept up to date.'
                : project.lastCheckedAt != null
                    ? 'Last analyzed ${_ago(project.lastCheckedAt!)}'
                    : 'Analyzed when added',
            style: theme.textTheme.bodySmall?.copyWith(
              color: project.isArchived ? Colors.blueGrey.shade700 : null,
              fontWeight: project.isArchived ? FontWeight.w600 : null,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 20,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _Stat(label: 'dependencies', value: report.total),
              // "Outdated" and the upgrade counts are comparisons against
              // pub.dev as it is now, which is what archiving stepped away
              // from. Advisories are facts about the snapshot, so they stay.
              if (!project.isArchived)
                _Stat(
                  label: 'outdated',
                  value: report.outdated,
                  color: report.outdated > 0 ? Colors.orange : null,
                ),
              _Stat(
                label: 'vulnerable',
                value: report.vulnerable,
                color: report.vulnerable > 0 ? Colors.red : null,
              ),
              if (unknown > 0 && !project.isArchived)
                _Stat(label: 'unknown', value: unknown),
            ],
          ),
          if (!project.isArchived && (breaking > 0 || routine > 0)) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 20,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (breaking > 0)
                  _Stat(
                    label: 'breaking upgrades',
                    value: breaking,
                    color: Colors.red,
                  ),
                if (routine > 0)
                  _Stat(label: 'routine upgrades', value: routine),
              ],
            ),
          ],
          if (report.manifests.length > 1) ...[
            const SizedBox(height: 8),
            _Note(
              icon: Icons.folder_copy_outlined,
              // The count is of distinct name+version pairs, so a package
              // resolved at two versions is genuinely two of them.
              text: 'Covers ${report.manifests.length} pubspecs in this '
                  'repository (${report.manifests.join(', ')}). A package '
                  'resolved at two versions is counted once per version.',
            ),
          ],
          if (report.coverageNote != null) ...[
            const SizedBox(height: 8),
            _Note(
              icon: Icons.warning_amber_outlined,
              text: report.coverageNote!,
              isWarning: true,
            ),
          ],
          if (inferred > 0) ...[
            const SizedBox(height: 8),
            _Note(
              icon: Icons.info_outline,
              text: 'This repository has no pubspec.lock, so versions were '
                  'inferred by resolving its constraints — what a fresh '
                  'pub get would install today.',
            ),
          ],
        ],
      ),
    );
  }
}

/// A line of context under the summary: what the report covers, or what it
/// could not.
class _Note extends StatelessWidget {
  const _Note({
    required this.icon,
    required this.text,
    this.isWarning = false,
  });

  final IconData icon;
  final String text;
  final bool isWarning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color =
        isWarning ? Colors.orange.shade800 : theme.textTheme.bodySmall?.color;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: isWarning ? color : null,
            ),
          ),
        ),
      ],
    );
  }
}

/// Coarse relative time — a report's age only matters in broad strokes.
String _ago(DateTime time) {
  final delta = DateTime.now().toUtc().difference(time.toUtc());
  if (delta.inMinutes < 1) return 'just now';
  if (delta.inHours < 1) return '${delta.inMinutes}m ago';
  if (delta.inDays < 1) return '${delta.inHours}h ago';
  return '${delta.inDays}d ago';
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.color});

  final String label;
  final int value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          '$value',
          style: theme.textTheme.titleLarge?.copyWith(
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: theme.textTheme.bodyMedium),
      ],
    );
  }
}

/// Lists the packages carrying advisories that apply to the installed version,
/// worst first.
class _Advisories extends StatelessWidget {
  const _Advisories({required this.report, this.onLoadRemediation});

  final DepReport report;

  /// Fetches verified fixes. Optional so the card renders without a backend.
  final Future<RemediationPlan> Function()? onLoadRemediation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final affected = report.affectedNodes;
    if (affected.isEmpty) return const SizedBox.shrink();

    final worst = report.worstSeverity ?? AdvisorySeverity.unknown;
    final accent = severityColor(worst, theme);
    final counts = report.advisoryCounts;

    return Card(
      color: accent.withValues(alpha: 0.06),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: accent.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.gpp_maybe_outlined, color: accent),
                const SizedBox(width: 8),
                Text(
                  'Security advisories',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(width: 12),
                // The breakdown, so the headline is the shape of the problem
                // rather than a single count that treats every finding alike.
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final entry in counts.entries)
                        _SeverityCount(
                          severity: entry.key,
                          count: entry.value,
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            for (final node in affected) ...[
              _AffectedPackage(node: node, nodes: report.nodes),
              const SizedBox(height: 14),
            ],
            if (onLoadRemediation != null) ...[
              const Divider(height: 8),
              const SizedBox(height: 8),
              RemediationPanel(load: onLoadRemediation!),
            ],
          ],
        ),
      ),
    );
  }
}

/// `3 critical` in that band's colour.
class _SeverityCount extends StatelessWidget {
  const _SeverityCount({required this.severity, required this.count});

  final AdvisorySeverity severity;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = severityColor(severity, theme);

    return Text(
      '$count ${severityLabel(severity).toLowerCase()}',
      style: theme.textTheme.labelMedium
          ?.copyWith(color: color, fontWeight: FontWeight.w700),
    );
  }
}

/// One vulnerable package: what is wrong, what fixes it, and — when the project
/// does not declare it — what would have to be bumped to get the fix.
class _AffectedPackage extends StatelessWidget {
  const _AffectedPackage({required this.node, required this.nodes});

  final DepNode node;

  /// The whole report, needed to trace a transitive package back to a
  /// dependency the project actually declares.
  final List<DepNode> nodes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: node.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    TextSpan(text: ' ${node.installed}'),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            DepStatusChip(status: node.status),
          ],
        ),
        for (final advisory in node.advisories) ...[
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SeverityChip(
                      severity: advisory.severity,
                      score: advisory.cvssScore,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        [advisory.id, ...advisory.aliases].join('  ·  '),
                        style: theme.textTheme.bodySmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                if (advisory.summary != null)
                  Text(advisory.summary!, style: theme.textTheme.bodySmall),
                Text(
                  // A missing fix version means the advisory did not say, not
                  // that the package is unfixable — worth the extra words.
                  advisory.fixedIn != null
                      ? 'Fixed in ${advisory.fixedIn}.'
                      : 'No fixed version is published in this advisory.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: advisory.fixedIn != null
                        ? Colors.green.shade800
                        : theme.textTheme.bodySmall?.color,
                    fontWeight:
                        advisory.fixedIn != null ? FontWeight.w600 : null,
                  ),
                ),
              ],
            ),
          ),
        ],
        ..._blame(context),
      ],
    );
  }

  /// For a package the project does not declare, names what does pull it in.
  ///
  /// Bumping the vulnerable package itself is not an option here — nothing in
  /// `pubspec.yaml` mentions it. The fix has to come through whatever depends
  /// on it, so that is the useful thing to print.
  List<Widget> _blame(BuildContext context) {
    if (node.kind != DepKind.transitive) return const [];

    final culprits = {
      for (final path in dependencyPathsTo(node.name, nodes))
        if (path.length > 1) path.first,
    };
    if (culprits.isEmpty) return const [];

    final theme = Theme.of(context);
    return [
      const SizedBox(height: 4),
      Text(
        culprits.length == 1
            ? 'You do not depend on ${node.name} directly — it arrives through '
                '${culprits.single}, which is what has to move.'
            : 'You do not depend on ${node.name} directly — it arrives through '
                '${culprits.join(' and ')}.',
        style: theme.textTheme.bodySmall,
      ),
    ];
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.text,
    this.isError = false,
    this.onRetry,
  });

  final IconData icon;
  final String text;
  final bool isError;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 40,
              color: isError ? theme.colorScheme.error : null,
            ),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isError ? theme.colorScheme.error : null,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
