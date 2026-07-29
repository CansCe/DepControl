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

  group('what the source imports', () {
    DepNode used(String name, DepKind kind, {bool? imported}) => DepNode(
          name: name,
          kind: kind,
          installed: '1.0.0',
          imported: imported,
        );

    test('a transitive package the source imports is undeclared', () {
      final report = reportOf([
        used('http', DepKind.direct, imported: true),
        used('meta', DepKind.transitive, imported: true),
        used('path', DepKind.transitive, imported: false),
      ]);

      expect(report.undeclaredImports.map((n) => n.name), ['meta']);
    });

    test('a declared package nothing imports is a candidate to drop', () {
      final report = reportOf([
        used('http', DepKind.direct, imported: true),
        used('crypto', DepKind.direct, imported: false),
        used('mocktail', DepKind.dev, imported: false),
      ]);

      expect(
        report.unimportedDeclarations.map((n) => n.name),
        ['crypto', 'mocktail'],
      );
    });

    // The exclusion that keeps the finding credible: every one of these is
    // used, just never through an import.
    test('does not call build tooling unused', () {
      final report = reportOf([
        used('build_runner', DepKind.dev, imported: false),
        used('lints', DepKind.dev, imported: false),
        used('json_serializable', DepKind.dev, imported: false),
        used('freezed_annotation', DepKind.direct, imported: false),
      ]);

      // freezed_annotation is genuinely imported by generated code, so it is
      // not on the list — the suffix rules cover the generators themselves.
      expect(
        report.unimportedDeclarations.map((n) => n.name),
        ['freezed_annotation'],
      );
    });

    test('excludes generators by their naming convention', () {
      for (final name in [
        'retrofit_generator',
        'go_router_builder',
        'envied_generator',
        'pigeon_gen',
      ]) {
        expect(
          DepReport.usedWithoutImporting(name),
          isTrue,
          reason: '$name is build tooling',
        );
      }
      expect(DepReport.usedWithoutImporting('http'), isFalse);
    });

    // Null is "nobody looked". Reading it as false would accuse every
    // dependency in every report generated before scanning existed.
    test('an unscanned report reports nothing either way', () {
      final report = reportOf([
        used('http', DepKind.direct),
        used('meta', DepKind.transitive),
      ]);

      expect(report.scannedImports, isFalse);
      expect(report.undeclaredImports, isEmpty);
      expect(report.unimportedDeclarations, isEmpty);
    });
  });

  group('serialization', () {
    test('round-trips whether a package is imported', () {
      for (final imported in [true, false]) {
        final node = DepNode(
          name: 'http',
          kind: DepKind.direct,
          installed: '1.0.0',
          imported: imported,
        );

        expect(DepNode.fromJson(node.toJson()).imported, imported);
      }
    });

    // A report stored before scanning existed has no `imported` key at all, and
    // must read back as unknown rather than as "nothing is imported".
    test('a report stored before scanning reads back as unscanned', () {
      const node = DepNode(
        name: 'http',
        kind: DepKind.direct,
        installed: '1.0.0',
      );

      expect(node.toJson().containsKey('imported'), isFalse);
      expect(DepNode.fromJson(node.toJson()).imported, isNull);
    });
  });
}
