import 'dart:convert';

import 'package:backend/src/ecosystem/ecosystems.dart';
import 'package:backend/src/services/pub_api_client.dart';
import 'package:backend/src/services/remediation_planner.dart';
import 'package:backend/src/services/resolver.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

/// A fake pub.dev: package name -> {version -> {dependency -> constraint}}.
typedef Registry = Map<String, Map<String, Map<String, String>>>;

RemediationPlanner plannerFor(Registry registry) {
  final client = MockClient((request) async {
    final name = request.url.pathSegments.last;
    final package = registry[name];
    if (package == null) return http.Response('{}', 404);

    return http.Response(
      jsonEncode({
        'name': name,
        'latest': {'version': package.keys.last},
        'versions': [
          for (final entry in package.entries)
            {
              'version': entry.key,
              'pubspec': {'dependencies': entry.value},
            },
        ],
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });

  return RemediationPlanner(
    Resolver(
      const DartEcosystem(),
      DartRegistry(
        PubApiClient(client: client),
        osv: OsvClient(client: client),
      ),
    ),
  );
}

DepNode node(
  String name, {
  required String installed,
  DepKind kind = DepKind.transitive,
  String? constraint,
  String? latest,
  List<String> dependencies = const [],
  List<DepAdvisory> advisories = const [],
}) =>
    DepNode(
      name: name,
      kind: kind,
      installed: installed,
      constraint: constraint,
      latest: latest,
      status: advisories.isEmpty ? DepStatus.outdated : DepStatus.vulnerable,
      dependencies: dependencies,
      advisories: advisories,
    );

DepReport reportOf(List<DepNode> nodes) => DepReport(
      projectId: 'p1',
      generatedAt: DateTime.utc(2026, 1, 1),
      nodes: nodes,
    );

DepAdvisory advisory({
  String id = 'GHSA-test',
  String? fixedIn,
  AdvisorySeverity severity = AdvisorySeverity.high,
}) =>
    DepAdvisory(id: id, fixedIn: fixedIn, severity: severity);

void main() {
  group('a package the project declares', () {
    const pubspec = '''
name: demo
environment:
  sdk: ^3.6.0
dependencies:
  http: ^0.13.0
''';

    test('raises the constraint to the fixed version', () async {
      final planner = plannerFor({
        'http': {'0.13.0': {}, '0.13.3': {}},
      });

      final plan = await planner.plan(
        reportOf([
          node(
            'http',
            kind: DepKind.direct,
            installed: '0.13.0',
            constraint: '^0.13.0',
            latest: '0.13.3',
            advisories: [advisory(fixedIn: '0.13.3')],
          ),
        ]),
        const ManifestFiles(manifest: pubspec),
      );

      final fix = plan.remediations.single;
      expect(fix.isActionable, isTrue);
      expect(fix.kind, RemediationKind.raiseConstraint);
      expect(fix.editPackage, 'http');
      expect(fix.fromConstraint, '^0.13.0');
      expect(fix.toConstraint, '^0.13.3');
      expect(fix.diffLine, '  http: ^0.13.3');
    });

    test('proves the fixed version is what actually resolves', () async {
      final planner = plannerFor({
        'http': {'0.13.0': {}, '0.13.3': {}},
      });

      final plan = await planner.plan(
        reportOf([
          node(
            'http',
            kind: DepKind.direct,
            installed: '0.13.0',
            constraint: '^0.13.0',
            advisories: [advisory(fixedIn: '0.13.3')],
          ),
        ]),
        const ManifestFiles(manifest: pubspec),
      );

      expect(plan.remediations.single.resolvedVersion, '0.13.3');
    });

    test('warns when the fix is a breaking upgrade', () async {
      final planner = plannerFor({
        'http': {'0.13.0': {}, '1.0.0': {}},
      });

      final plan = await planner.plan(
        reportOf([
          node(
            'http',
            kind: DepKind.direct,
            installed: '0.13.0',
            constraint: '^0.13.0',
            advisories: [advisory(fixedIn: '1.0.0')],
          ),
        ]),
        const ManifestFiles(manifest: pubspec),
      );

      expect(plan.remediations.single.caveat, contains('breaking upgrade'));
    });

    // Fixing one advisory and leaving another open is not a fix.
    test('clears every advisory on the package at once', () async {
      final planner = plannerFor({
        'http': {'0.13.0': {}, '0.13.3': {}, '0.13.6': {}},
      });

      final plan = await planner.plan(
        reportOf([
          node(
            'http',
            kind: DepKind.direct,
            installed: '0.13.0',
            constraint: '^0.13.0',
            advisories: [
              advisory(id: 'GHSA-a', fixedIn: '0.13.3'),
              advisory(id: 'GHSA-b', fixedIn: '0.13.6'),
            ],
          ),
        ]),
        const ManifestFiles(manifest: pubspec),
      );

      final fix = plan.remediations.single;
      expect(fix.toConstraint, '^0.13.6');
      expect(fix.advisoryIds, ['GHSA-a', 'GHSA-b']);
    });
  });

  group('a transitive package', () {
    const pubspec = '''
name: demo
environment:
  sdk: ^3.6.0
dependencies:
  wrapper: ^1.0.0
''';

    test('bumps the dependency that pulls it in', () async {
      final planner = plannerFor({
        // wrapper 2.0.0 is the release that moved onto a fixed archive.
        'wrapper': {
          '1.0.0': {'archive': '^3.3.0'},
          '2.0.0': {'archive': '^3.4.10'},
        },
        'archive': {'3.3.0': {}, '3.4.10': {}},
      });

      final plan = await planner.plan(
        reportOf([
          node(
            'wrapper',
            kind: DepKind.direct,
            installed: '1.0.0',
            constraint: '^1.0.0',
            latest: '2.0.0',
            dependencies: ['archive'],
          ),
          node(
            'archive',
            installed: '3.3.0',
            advisories: [advisory(fixedIn: '3.4.10')],
          ),
        ]),
        const ManifestFiles(manifest: pubspec),
      );

      final fix = plan.remediations.single;
      expect(fix.package, 'archive');
      expect(fix.kind, RemediationKind.bumpParent);
      // The edit lands on the thing the project actually declares.
      expect(fix.editPackage, 'wrapper');
      expect(fix.toConstraint, '^2.0.0');
      expect(fix.resolvedVersion, '3.4.10');
    });

    // Buried deeper than the project's own dependencies: nothing declared
    // names it, so there is no parent constraint to raise. Declaring it with a
    // floor is the remaining option.
    test('promotes it to a direct dependency when nothing declared owns it',
        () async {
      final planner = plannerFor({
        'wrapper': {
          '1.0.0': {'mid': '^1.0.0'},
        },
        'mid': {
          '1.0.0': {'archive': '^3.3.0'},
        },
        'archive': {'3.3.0': {}, '3.4.10': {}},
      });

      final plan = await planner.plan(
        reportOf([
          node(
            'wrapper',
            kind: DepKind.direct,
            installed: '1.0.0',
            constraint: '^1.0.0',
            latest: '1.0.0',
            dependencies: ['mid'],
          ),
          node('mid', installed: '1.0.0', dependencies: ['archive']),
          node(
            'archive',
            installed: '3.3.0',
            advisories: [advisory(fixedIn: '3.4.10')],
          ),
        ]),
        const ManifestFiles(manifest: pubspec),
      );

      final fix = plan.remediations.single;
      expect(fix.kind, RemediationKind.promoteToDirect);
      expect(fix.editPackage, 'archive');
      expect(fix.resolvedVersion, '3.4.10');
      // It works, and someone has to remember to undo it.
      expect(fix.caveat, contains('should come out'));
    });

    // When something in the tree pins the vulnerable package below its fix,
    // no edit to this pubspec reaches it. Offering one anyway would send the
    // reader to a resolution failure.
    test('reports unreachable when a dependency pins below the fix', () async {
      final planner = plannerFor({
        'wrapper': {
          '1.0.0': {'archive': '>=3.3.0 <3.4.0'},
        },
        'archive': {'3.3.0': {}, '3.4.10': {}},
      });

      final plan = await planner.plan(
        reportOf([
          node(
            'wrapper',
            kind: DepKind.direct,
            installed: '1.0.0',
            constraint: '^1.0.0',
            latest: '1.0.0',
            dependencies: ['archive'],
          ),
          node(
            'archive',
            installed: '3.3.0',
            advisories: [advisory(fixedIn: '3.4.10')],
          ),
        ]),
        const ManifestFiles(manifest: pubspec),
      );

      final fix = plan.remediations.single;
      expect(fix.isActionable, isFalse);
      expect(fix.blocker, RemediationBlocker.unreachable);
    });
  });

  group('when there is nothing to offer', () {
    const pubspec = '''
name: demo
environment:
  sdk: ^3.6.0
dependencies:
  http: ^0.13.0
''';

    test('says so when the advisory names no fix', () async {
      final planner = plannerFor({
        'http': {'0.13.0': {}},
      });

      final plan = await planner.plan(
        reportOf([
          node(
            'http',
            kind: DepKind.direct,
            installed: '0.13.0',
            constraint: '^0.13.0',
            advisories: [advisory()],
          ),
        ]),
        const ManifestFiles(manifest: pubspec),
      );

      final fix = plan.remediations.single;
      expect(fix.isActionable, isFalse);
      expect(fix.blocker, RemediationBlocker.noFixPublished);
      expect(plan.actionable, isEmpty);
      expect(plan.blocked, hasLength(1));
    });

    // The check that matters: a resolution can succeed while leaving the
    // vulnerable package exactly where it was.
    test('refuses to offer a change that does not reach the fix', () async {
      final planner = plannerFor({
        // The fixed version simply is not published.
        'http': {'0.13.0': {}, '0.13.1': {}},
      });

      final plan = await planner.plan(
        reportOf([
          node(
            'http',
            kind: DepKind.direct,
            installed: '0.13.0',
            constraint: '^0.13.0',
            advisories: [advisory(fixedIn: '0.13.3')],
          ),
        ]),
        const ManifestFiles(manifest: pubspec),
      );

      expect(plan.remediations.single.blocker, RemediationBlocker.unreachable);
    });

    test('a clean report plans nothing', () async {
      final planner = plannerFor({
        'http': {'0.13.0': {}},
      });

      final plan = await planner.plan(
        reportOf([
          node('http', kind: DepKind.direct, installed: '0.13.0'),
        ]),
        const ManifestFiles(manifest: pubspec),
      );

      expect(plan.remediations, isEmpty);
      expect(plan.worstSeverity, isNull);
    });
  });

  test('plans the worst package first', () async {
    const pubspec = '''
name: demo
environment:
  sdk: ^3.6.0
dependencies:
  http: ^0.13.0
  yaml: ^3.1.0
''';
    final planner = plannerFor({
      'http': {'0.13.0': {}, '0.13.3': {}},
      'yaml': {'3.1.0': {}, '3.1.3': {}},
    });

    final plan = await planner.plan(
      reportOf([
        node(
          'http',
          kind: DepKind.direct,
          installed: '0.13.0',
          constraint: '^0.13.0',
          advisories: [
            advisory(fixedIn: '0.13.3', severity: AdvisorySeverity.low),
          ],
        ),
        node(
          'yaml',
          kind: DepKind.direct,
          installed: '3.1.0',
          constraint: '^3.1.0',
          advisories: [
            advisory(fixedIn: '3.1.3', severity: AdvisorySeverity.critical),
          ],
        ),
      ]),
      const ManifestFiles(manifest: pubspec),
    );

    expect(plan.remediations.map((r) => r.package), ['yaml', 'http']);
    expect(plan.worstSeverity, AdvisorySeverity.critical);
  });
}
