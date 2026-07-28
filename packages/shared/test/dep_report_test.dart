import 'package:shared/shared.dart';
import 'package:test/test.dart';

DepNode node(String name, List<AdvisorySeverity> severities) => DepNode(
      name: name,
      kind: DepKind.direct,
      installed: '1.0.0',
      status: severities.isEmpty ? DepStatus.upToDate : DepStatus.vulnerable,
      advisories: [
        for (var i = 0; i < severities.length; i++)
          DepAdvisory(id: 'GHSA-$name-$i', severity: severities[i]),
      ],
    );

DepReport reportOf(List<DepNode> nodes) => DepReport(
      projectId: 'p1',
      generatedAt: DateTime.utc(2026, 1, 1),
      nodes: nodes,
    );

void main() {
  group('advisoryCounts', () {
    test('counts advisories, not packages', () {
      final report = reportOf([
        // One package, two separate pieces of news.
        node('a', [AdvisorySeverity.critical, AdvisorySeverity.low]),
        node('b', [AdvisorySeverity.low]),
      ]);

      expect(report.advisoryCounts, {
        AdvisorySeverity.critical: 1,
        AdvisorySeverity.low: 2,
      });
    });

    test('is ordered worst first', () {
      final report = reportOf([
        node('a', [AdvisorySeverity.low]),
        node('b', [AdvisorySeverity.critical]),
        node('c', [AdvisorySeverity.medium]),
      ]);

      expect(report.advisoryCounts.keys.toList(), [
        AdvisorySeverity.critical,
        AdvisorySeverity.medium,
        AdvisorySeverity.low,
      ]);
    });

    test('omits bands with nothing in them', () {
      final report = reportOf([
        node('a', [AdvisorySeverity.high]),
      ]);

      expect(report.advisoryCounts, {AdvisorySeverity.high: 1});
    });

    test('is empty for a clean report', () {
      expect(reportOf([node('a', [])]).advisoryCounts, isEmpty);
      expect(reportOf([node('a', [])]).worstSeverity, isNull);
    });
  });

  group('affectedNodes', () {
    test('ranks a package by its worst advisory', () {
      final report = reportOf([
        node('mild', [AdvisorySeverity.low, AdvisorySeverity.low]),
        // Ranked critical despite also carrying something trivial.
        node('nasty', [AdvisorySeverity.low, AdvisorySeverity.critical]),
      ]);

      expect(report.affectedNodes.map((n) => n.name), ['nasty', 'mild']);
    });

    test('breaks ties by name, so the order is stable', () {
      final report = reportOf([
        node('zeta', [AdvisorySeverity.high]),
        node('alpha', [AdvisorySeverity.high]),
        node('mid', [AdvisorySeverity.high]),
      ]);

      expect(report.affectedNodes.map((n) => n.name), [
        'alpha',
        'mid',
        'zeta',
      ]);
    });

    test('leaves out packages with no advisories', () {
      final report = reportOf([
        node('clean', []),
        node('affected', [AdvisorySeverity.medium]),
      ]);

      expect(report.affectedNodes.map((n) => n.name), ['affected']);
    });

    // An advisory nobody scored must not push a known critical down the page.
    test('sorts unrated advisories below rated ones', () {
      final report = reportOf([
        node('unrated', [AdvisorySeverity.unknown]),
        node('critical', [AdvisorySeverity.critical]),
        node('low', [AdvisorySeverity.low]),
      ]);

      expect(report.affectedNodes.map((n) => n.name), [
        'critical',
        'low',
        'unrated',
      ]);
    });

    test('does not reorder the report\'s own node list', () {
      final nodes = [
        node('low', [AdvisorySeverity.low]),
        node('critical', [AdvisorySeverity.critical]),
      ];
      final report = reportOf(nodes);

      report.affectedNodes;

      expect(report.nodes.map((n) => n.name), ['low', 'critical']);
    });
  });

  test('worstSeverity reports the worst anywhere in the report', () {
    final report = reportOf([
      node('a', [AdvisorySeverity.medium]),
      node('b', [AdvisorySeverity.critical]),
      node('c', [AdvisorySeverity.low]),
    ]);

    expect(report.worstSeverity, AdvisorySeverity.critical);
  });
}
