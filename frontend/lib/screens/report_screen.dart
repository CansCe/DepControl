import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import '../api/api_client.dart';
import '../widgets/dep_graph.dart';
import '../widgets/dep_status_chip.dart';
import '../widgets/dep_table.dart';

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

  @override
  void initState() {
    super.initState();
    _report = widget.api.report(widget.project.id);
  }

  void _reload() {
    setState(() => _report = widget.api.report(widget.project.id));
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.project.name),
          actions: [
            IconButton(
              tooltip: 'Reload',
              icon: const Icon(Icons.refresh),
              onPressed: _reload,
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.table_rows_outlined), text: 'Table'),
              Tab(icon: Icon(Icons.hub_outlined), text: 'Graph'),
            ],
          ),
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
                _Summary(project: widget.project, report: report),
                const Divider(height: 1),
                Expanded(
                  child: TabBarView(
                    children: [
                      SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (report.vulnerable > 0) ...[
                              _Advisories(nodes: report.nodes),
                              const SizedBox(height: 16),
                            ],
                            DepTable(nodes: report.nodes),
                          ],
                        ),
                      ),
                      DepGraph(nodes: report.nodes),
                    ],
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

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${project.gitUrl} @ ${project.ref}',
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
          if (unknown == report.total && report.total > 0) ...[
            const SizedBox(height: 8),
            Text(
              'Versions are unknown because this repository has no '
              'pubspec.lock, so only the declared constraints are visible.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
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
