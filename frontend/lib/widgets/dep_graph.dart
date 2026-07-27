import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:graphview/GraphView.dart';
import 'package:shared/shared.dart';

/// Builds the [Graph] shown by [DepGraph]: one node per package, one edge per
/// declared dependency.
///
/// Exposed so the structure can be asserted directly, rather than inferred from
/// whichever node chips happen to be laid out on screen.
Graph buildDependencyGraph(List<DepNode> deps) {
  final graph = Graph();
  final nodeById = <String, Node>{};
  Node nodeFor(String name) => nodeById.putIfAbsent(name, () => Node.Id(name));

  // `addEdge` inserts both endpoints itself and skips ones already present,
  // but `addNode` does NOT guard against duplicates — adding a node that an
  // edge already introduced puts the same instance in the graph twice, which
  // makes the layout build two children for one node and corrupts the tree.
  // So track what is already in, and only add genuinely isolated nodes.
  final inGraph = <String>{};
  final known = {for (final d in deps) d.name};

  for (final dep in deps) {
    for (final child in dep.dependencies) {
      // Skip self-edges and edges to packages outside the report; both only
      // confuse the force layout.
      if (child == dep.name || !known.contains(child)) continue;
      graph.addEdge(nodeFor(dep.name), nodeFor(child));
      inGraph
        ..add(dep.name)
        ..add(child);
    }
  }

  for (final dep in deps) {
    if (inGraph.add(dep.name)) graph.addNode(nodeFor(dep.name));
  }

  return graph;
}

/// Force-directed view of the dependency graph. Each [DepNode]'s
/// `dependencies` become directed edges.
class DepGraph extends StatefulWidget {
  const DepGraph({super.key, required this.nodes});

  final List<DepNode> nodes;

  @override
  State<DepGraph> createState() => _DepGraphState();
}

class _DepGraphState extends State<DepGraph> {
  late Graph _graph;
  late Map<String, DepNode> _byName;
  late FruchtermanReingoldAlgorithm _builder;

  @override
  void initState() {
    super.initState();
    _rebuild();
  }

  @override
  void didUpdateWidget(DepGraph oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reloading a report hands us a new node list; without this the graph
    // would keep showing the previous one.
    if (!identical(oldWidget.nodes, widget.nodes)) _rebuild();
  }

  void _rebuild() {
    _byName = {for (final n in widget.nodes) n.name: n};
    _graph = buildDependencyGraph(widget.nodes);
    // The algorithm carries per-run state, so it cannot be shared across graphs.
    _builder = FruchtermanReingoldAlgorithm(iterations: 500);
  }

  /// Side length of the canvas the layout is given.
  ///
  /// Grows with the node count so a large graph isn't crammed, and is clamped
  /// so a tiny one isn't lost in empty space.
  double _canvasSide(int nodeCount) =>
      (math.sqrt(nodeCount) * 240).clamp(600, 3000).toDouble();

  @override
  Widget build(BuildContext context) {
    if (_graph.nodeCount() == 0) {
      return const Center(child: Text('No dependency graph available.'));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // GraphView sizes itself from `constraints.biggest`. Inside an
        // unconstrained InteractiveViewer that is infinite, so it cannot
        // compute a size and layout asserts. Bound it to a finite canvas —
        // loosely, since GraphView picks its own size from the laid-out nodes
        // and a tight box would force it to fill exactly and fail its
        // constraints.
        final side = _canvasSide(_graph.nodeCount());
        final width = math.max(side, constraints.maxWidth);
        final height = math.max(side, constraints.maxHeight);

        return InteractiveViewer(
          constrained: false,
          boundaryMargin: const EdgeInsets.all(200),
          minScale: 0.1,
          maxScale: 3,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: width,
              maxHeight: height,
            ),
            child: GraphView(
              graph: _graph,
              algorithm: _builder,
              paint: Paint()
                ..color = Colors.grey.shade400
                ..strokeWidth = 1
                ..style = PaintingStyle.stroke,
              builder: (node) => _nodeChip(node.key!.value as String),
            ),
          ),
        );
      },
    );
  }

  Widget _nodeChip(String name) {
    final dep = _byName[name];
    final color = switch (dep?.status) {
      DepStatus.vulnerable => Colors.red,
      DepStatus.outdated => Colors.orange,
      DepStatus.upToDate => Colors.green,
      _ => Colors.blueGrey,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(name, style: const TextStyle(fontSize: 12)),
    );
  }
}
