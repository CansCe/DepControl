import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import '../api/api_client.dart';
import '../widgets/dep_status_chip.dart';
import '../widgets/dep_table.dart';
import '../widgets/dependency_path.dart';

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
          onLoadImpact: () =>
              widget.api.upgradeImpact(_project.id, node.name),
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
            if (_refreshing)
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
                        if (report.vulnerable > 0) ...[
                          _Advisories(nodes: report.nodes),
                          const SizedBox(height: 16),
                        ],
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            'Select a package to see why it is here and what '
                            'upgrading it involves.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        DepTable(
                          nodes: report.nodes,
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
            project.lastCheckedAt != null
                ? 'Last analyzed ${_ago(project.lastCheckedAt!)}'
                : 'Analyzed when added',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 20,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _Stat(label: 'dependencies', value: report.total),
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
              if (unknown > 0) _Stat(label: 'unknown', value: unknown),
            ],
          ),
          if (breaking > 0 || routine > 0) ...[
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
          if (inferred > 0) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 15,
                  color: theme.textTheme.bodySmall?.color,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'This repository has no pubspec.lock, so versions were '
                    'inferred by resolving its constraints — what a fresh '
                    'pub get would install today.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
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

/// Lists the packages carrying advisories that apply to the installed version.
class _Advisories extends StatelessWidget {
  const _Advisories({required this.nodes});

  final List<DepNode> nodes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final affected =
        nodes.where((n) => n.advisories.isNotEmpty).toList(growable: false);
    if (affected.isEmpty) return const SizedBox.shrink();

    return Card(
      color: Colors.red.withValues(alpha: 0.06),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.red.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.gpp_maybe_outlined, color: Colors.red),
                const SizedBox(width: 8),
                Text(
                  'Security advisories',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),
            for (final node in affected) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: node.name,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          TextSpan(text: ' ${node.installed}'),
                          TextSpan(
                            text: '  —  ${node.advisories.join(', ')}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  DepStatusChip(status: node.status),
                ],
              ),
              const SizedBox(height: 6),
            ],
          ],
        ),
      ),
    );
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
