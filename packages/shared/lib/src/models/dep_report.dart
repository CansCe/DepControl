import 'dep_advisory.dart';
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

  /// How many advisories fall in each band, worst first and skipping bands
  /// with none.
  ///
  /// Counts advisories rather than packages: one package carrying a critical
  /// and a low is two different pieces of news, and collapsing them to a single
  /// "vulnerable package" hides the one that matters.
  Map<AdvisorySeverity, int> get advisoryCounts {
    final counts = <AdvisorySeverity, int>{};
    for (final node in nodes) {
      for (final advisory in node.advisories) {
        counts.update(advisory.severity, (n) => n + 1, ifAbsent: () => 1);
      }
    }

    return {
      for (final severity in AdvisorySeverity.values)
        if (counts[severity] != null) severity: counts[severity]!,
    };
  }

  /// The worst advisory anywhere in the report, or null when there are none.
  AdvisorySeverity? get worstSeverity {
    final counted = advisoryCounts.keys;
    return counted.isEmpty ? null : counted.first;
  }

  /// Packages carrying at least one advisory, worst first, then by name.
  ///
  /// Ordering is the whole value of a list like this: the reader deals with the
  /// top of it and runs out of time somewhere further down.
  List<DepNode> get affectedNodes {
    final affected =
        nodes.where((n) => n.advisories.isNotEmpty).toList(growable: false);

    int rank(DepNode node) => node.advisories
        .map((a) => AdvisorySeverity.values.indexOf(a.severity))
        .reduce((a, b) => a < b ? a : b);

    return affected.toList()
      ..sort((a, b) {
        final bySeverity = rank(a).compareTo(rank(b));
        return bySeverity != 0 ? bySeverity : a.name.compareTo(b.name);
      });
  }

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
