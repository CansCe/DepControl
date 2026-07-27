import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import 'dep_status_chip.dart';

/// Chains explaining how [package] ends up in the project.
///
/// Each chain starts at a dependency the project declares and ends at
/// [package], e.g. `test -> analyzer -> yaml`. A package the project declares
/// itself returns a single one-element chain.
///
/// Shortest chains come first, since the shortest explanation is the useful
/// one. Cycles are ignored rather than followed.
List<List<String>> dependencyPathsTo(
  String package,
  List<DepNode> nodes, {
  int maxPaths = 3,
}) {
  final byName = {for (final node in nodes) node.name: node};
  final target = byName[package];
  if (target == null) return const [];

  bool isDeclared(DepNode node) =>
      node.kind == DepKind.direct || node.kind == DepKind.dev;

  if (isDeclared(target)) {
    return [
      [package],
    ];
  }

  // Reverse the graph: for each package, who pulls it in.
  final parents = <String, List<String>>{};
  for (final node in nodes) {
    for (final child in node.dependencies) {
      if (!byName.containsKey(child)) continue;
      (parents[child] ??= []).add(node.name);
    }
  }

  // Breadth-first from the target backwards, so chains come out shortest first.
  final results = <List<String>>[];
  final queue = Queue<List<String>>()..add([package]);
  final seen = <String>{package};

  while (queue.isNotEmpty && results.length < maxPaths) {
    final path = queue.removeFirst();

    for (final parent in parents[path.first] ?? const <String>[]) {
      if (path.contains(parent)) continue; // cycle
      final extended = [parent, ...path];

      if (isDeclared(byName[parent]!)) {
        results.add(extended);
        if (results.length >= maxPaths) break;
      } else if (seen.add(parent)) {
        queue.add(extended);
      }
    }
  }

  return results;
}

/// Everything worth knowing about one package: why it is present, and what
/// moving it to the latest version involves.
///
/// The paths replace a whole-graph view, which at real sizes — ~50 packages and
/// ~150 edges — rendered as an illegible cobweb regardless of layout. A chain
/// answers the question people actually bring to a dependency graph, and stays
/// readable because it is only ever a few steps long.
class PackageDetailView extends StatelessWidget {
  const PackageDetailView({
    required this.package,
    required this.nodes,
    this.onLoadImpact,
    super.key,
  });

  final String package;
  final List<DepNode> nodes;

  /// Fetches what the upgrade actually changes. Optional so the view can be
  /// rendered without a backend.
  final Future<UpgradeImpact?> Function()? onLoadImpact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final byName = {for (final node in nodes) node.name: node};
    final node = byName[package];
    final paths = dependencyPathsTo(package, nodes);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Why is $package here?',
                  style: theme.textTheme.titleLarge,
                ),
              ),
              if (node != null) DepStatusChip(status: node.status),
            ],
          ),
          if (node != null) ...[
            const SizedBox(height: 4),
            Text(
              [
                'installed ${node.installed}',
                if (node.latest != null) 'latest ${node.latest}',
                if (node.constraint != null) 'constraint ${node.constraint}',
              ].join('  ·  '),
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (node != null && node.advisories.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Advisories: ${node.advisories.join(', ')}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ],
          if (node != null) ...[
            const SizedBox(height: 20),
            _Upgrade(assessment: assessUpgrade(node)),
            if (onLoadImpact != null &&
                assessUpgrade(node).risk != UpgradeRisk.none &&
                assessUpgrade(node).risk != UpgradeRisk.unknown) ...[
              const SizedBox(height: 12),
              _Impact(load: onLoadImpact!),
            ],
          ],
          const SizedBox(height: 20),
          if (paths.isEmpty)
            Text(
              'No path found. This package is in the report but nothing '
              'declared appears to pull it in.',
              style: theme.textTheme.bodyMedium,
            )
          else if (paths.length == 1 && paths.single.length == 1)
            Text(
              'You declare this directly in pubspec.yaml'
              '${node?.kind == DepKind.dev ? ' (dev_dependencies)' : ''}.',
              style: theme.textTheme.bodyMedium,
            )
          else ...[
            Text(
              paths.length == 1
                  ? 'Pulled in through:'
                  : 'Pulled in through ${paths.length} paths:',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            for (final path in paths) ...[
              _Chain(path: path, byName: byName),
              const SizedBox(height: 12),
            ],
          ],
        ],
      ),
    );
  }
}

/// What upgrading this package to the latest published version involves.
///
/// States plainly that this is derived from semver — what the author declared —
/// and not from any inspection of the project's own code, which would be the
/// only way to know whether it actually breaks.
class _Upgrade extends StatelessWidget {
  const _Upgrade({required this.assessment});

  final UpgradeAssessment assessment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final (label, color) = switch (assessment.risk) {
      UpgradeRisk.breaking => ('Breaking upgrade', Colors.red),
      UpgradeRisk.minor => ('Minor upgrade', Colors.blue),
      UpgradeRisk.patch => ('Patch upgrade', Colors.green),
      UpgradeRisk.none => ('Up to date', Colors.green),
      UpgradeRisk.unknown => ('Unknown', Colors.blueGrey),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        border: Border.all(color: color.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                assessment.needsAttention
                    ? Icons.warning_amber_outlined
                    : Icons.info_outline,
                size: 18,
                color: color.shade700,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: theme.textTheme.titleSmall
                    ?.copyWith(color: color.shade900),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(assessment.summary, style: theme.textTheme.bodyMedium),
          if (assessment.risk != UpgradeRisk.none &&
              assessment.risk != UpgradeRisk.unknown) ...[
            const SizedBox(height: 10),
            Text(
              'This reflects what the author declared through semver. Whether '
              'your own code still compiles is not something this can tell '
              'you — check the changelog:',
              style: theme.textTheme.bodySmall,
            ),
            if (assessment.changelogUrl != null) ...[
              const SizedBox(height: 4),
              SelectableText(
                assessment.changelogUrl!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// The concrete differences between the installed and newest versions.
///
/// Every line here is a fact from published metadata. Nothing paraphrases the
/// changelog, because a tool that summarises prose is a tool that can be
/// confidently wrong about what breaks.
class _Impact extends StatefulWidget {
  const _Impact({required this.load});

  final Future<UpgradeImpact?> Function() load;

  @override
  State<_Impact> createState() => _ImpactState();
}

class _ImpactState extends State<_Impact> {
  late final Future<UpgradeImpact?> _future = widget.load();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return FutureBuilder<UpgradeImpact?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Text('Checking what changes…', style: theme.textTheme.bodySmall),
            ],
          );
        }

        // A failure here costs nothing important — the assessment above still
        // stands — so it is reported quietly rather than as an error state.
        if (snap.hasError) {
          return Text(
            'Could not load the details of this change.',
            style: theme.textTheme.bodySmall,
          );
        }

        final impact = snap.data;
        if (impact == null || !impact.hasFindings) {
          return const SizedBox.shrink();
        }

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            border: Border.all(color: theme.dividerColor),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'What changes between ${impact.from} and ${impact.to}',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 10),
              if (impact.majorVersionsCrossed.isNotEmpty)
                _Finding(
                  icon: Icons.flag_outlined,
                  text: impact.majorVersionsCrossed.length == 1
                      ? 'Crosses one breaking release, '
                          '${impact.majorVersionsCrossed.single}, across '
                          '${impact.releasesBetween} releases.'
                      : 'Crosses ${impact.majorVersionsCrossed.length} '
                          'breaking releases '
                          '(${impact.majorVersionsCrossed.join(', ')}) across '
                          '${impact.releasesBetween} releases.',
                ),
              if (impact.sdkTooNew)
                _Finding(
                  icon: Icons.block_outlined,
                  isBlocking: true,
                  text: 'Needs Dart SDK ${impact.sdkAfter}, but this project '
                      'declares ${impact.projectSdk}. The SDK constraint has '
                      'to be raised first.',
                ),
              for (final change in impact.dependencyChanges)
                _Finding(
                  icon: switch (change.kind) {
                    DependencyDeltaKind.added => Icons.add,
                    DependencyDeltaKind.removed => Icons.remove,
                    DependencyDeltaKind.changed => Icons.swap_horiz,
                  },
                  text: switch (change.kind) {
                    DependencyDeltaKind.added =>
                      'Starts requiring ${change.package} ${change.after}.',
                    DependencyDeltaKind.removed =>
                      'No longer requires ${change.package}.',
                    DependencyDeltaKind.changed =>
                      '${change.package}: ${change.before} → ${change.after}.',
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Finding extends StatelessWidget {
  const _Finding({
    required this.icon,
    required this.text,
    this.isBlocking = false,
  });

  final IconData icon;
  final String text;
  final bool isBlocking;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isBlocking ? theme.colorScheme.error : null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: color ?? theme.textTheme.bodySmall?.color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// One chain, rendered as steps separated by arrows.
class _Chain extends StatelessWidget {
  const _Chain({required this.path, required this.byName});

  final List<String> path;
  final Map<String, DepNode> byName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var i = 0; i < path.length; i++) ...[
          if (i > 0)
            Icon(
              Icons.arrow_forward,
              size: 14,
              color: theme.textTheme.bodySmall?.color,
            ),
          _Step(
            node: byName[path[i]],
            name: path[i],
            isLast: i == path.length - 1,
          ),
        ],
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.node, required this.name, required this.isLast});

  final DepNode? node;
  final String name;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (node?.status) {
      DepStatus.vulnerable => Colors.red,
      DepStatus.outdated => Colors.orange,
      DepStatus.upToDate => Colors.green,
      _ => Colors.blueGrey,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isLast ? 0.18 : 0.08),
        border: Border.all(color: color.withValues(alpha: isLast ? 1 : 0.5)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        node?.installed != null ? '$name ${node!.installed}' : name,
        style: theme.textTheme.bodySmall?.copyWith(
          color: color.shade900,
          fontWeight: isLast ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
    );
  }
}
