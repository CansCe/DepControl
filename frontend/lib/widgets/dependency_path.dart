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

/// Explains why a single package is present, as one or more chains.
///
/// This replaces a whole-graph view, which at real sizes — ~50 packages and
/// ~150 edges — rendered as an illegible cobweb regardless of layout. A chain
/// answers the question people actually bring to a dependency graph, and stays
/// readable because it is only ever a few steps long.
class DependencyPathView extends StatelessWidget {
  const DependencyPathView({
    required this.package,
    required this.nodes,
    super.key,
  });

  final String package;
  final List<DepNode> nodes;

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
