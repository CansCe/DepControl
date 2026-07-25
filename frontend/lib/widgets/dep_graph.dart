import 'package:flutter/material.dart';
import 'package:graphview/GraphView.dart';
import 'package:shared/shared.dart';

/// Force-directed view of the dependency graph. Each [DepNode]'s
/// `dependencies` become directed edges.
class DepGraph extends StatefulWidget {
  const DepGraph({super.key, required this.nodes});

  final List<DepNode> nodes;

  @override
  State<DepGraph> createState() => _DepGraphState();
}

class _DepGraphState extends State<DepGraph> {
  late final Graph _graph;
  late final Map<String, DepNode> _byName;

  final _builder = FruchtermanReingoldAlgorithm(iterations: 1000);

  @override
  void initState() {
    super.initState();
    _byName = {for (final n in widget.nodes) n.name: n};
    _graph = _buildGraph();
  }

  Graph _buildGraph() {
    final graph = Graph();
    final nodeById = <String, Node>{};
    Node nodeFor(String name) =>
        nodeById.putIfAbsent(name, () => Node.Id(name));

    for (final dep in widget.nodes) {
      final from = nodeFor(dep.name);
      if (dep.dependencies.isEmpty) {
        graph.addNode(from); // keep leaves/roots visible
      }
      for (final child in dep.dependencies) {
        graph.addEdge(from, nodeFor(child));
      }
    }
    return graph;
  }

  @override
  Widget build(BuildContext context) {
    if (_graph.nodeCount() == 0) {
      return const Center(child: Text('No graph edges available.'));
    }
    return InteractiveViewer(
      constrained: false,
      boundaryMargin: const EdgeInsets.all(400),
      minScale: 0.1,
      maxScale: 3,
      child: GraphView(
        graph: _graph,
        algorithm: _builder,
        paint: Paint()
          ..color = Colors.grey.shade400
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke,
        builder: (node) => _nodeChip(node.key!.value as String),
      ),
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
