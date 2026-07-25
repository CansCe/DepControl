import 'dep_node.dart';

/// The result of inspecting a project's dependencies (Phase 1).
class DepReport {
  const DepReport({
    required this.projectId,
    required this.generatedAt,
    required this.nodes,
  });

  final String projectId;
  final DateTime generatedAt;

  /// Flat list of every resolved dependency. Graph edges live on each node's
  /// [DepNode.dependencies].
  final List<DepNode> nodes;

  int get total => nodes.length;
  int get outdated =>
      nodes.where((n) => n.status == DepStatus.outdated).length;
  int get vulnerable =>
      nodes.where((n) => n.status == DepStatus.vulnerable).length;

  factory DepReport.fromJson(Map<String, dynamic> json) {
    return DepReport(
      projectId: json['projectId'] as String,
      generatedAt: DateTime.parse(json['generatedAt'] as String),
      nodes: (json['nodes'] as List)
          .map((e) => DepNode.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'projectId': projectId,
        'generatedAt': generatedAt.toIso8601String(),
        'nodes': nodes.map((n) => n.toJson()).toList(),
      };
}
