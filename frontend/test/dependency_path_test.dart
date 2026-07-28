import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/widgets/dependency_path.dart';
import 'package:shared/shared.dart';

DepNode node(
  String name, {
  DepKind kind = DepKind.transitive,
  List<String> deps = const [],
  String installed = '1.0.0',
  DepStatus status = DepStatus.upToDate,
  List<DepAdvisory> advisories = const [],
  String? latest,
  String? constraint,
}) =>
    DepNode(
      name: name,
      kind: kind,
      installed: installed,
      latest: latest,
      constraint: constraint,
      status: status,
      advisories: advisories,
      dependencies: deps,
    );

void main() {
  group('dependencyPathsTo', () {
    test('a declared package reports itself', () {
      final nodes = [node('http', kind: DepKind.direct)];

      expect(dependencyPathsTo('http', nodes), [
        ['http'],
      ]);
    });

    test('traces a chain back to the dependency that pulls it in', () {
      final nodes = [
        node('test', kind: DepKind.dev, deps: ['analyzer']),
        node('analyzer', deps: ['yaml']),
        node('yaml'),
      ];

      expect(dependencyPathsTo('yaml', nodes), [
        ['test', 'analyzer', 'yaml'],
      ]);
    });

    test('prefers the shortest explanation', () {
      final nodes = [
        // Reaches `target` directly and also the long way round.
        node('root', kind: DepKind.direct, deps: ['target', 'middle']),
        node('middle', deps: ['deeper']),
        node('deeper', deps: ['target']),
        node('target'),
      ];

      final paths = dependencyPathsTo('target', nodes);

      expect(paths.first, ['root', 'target']);
      expect(paths.first.length, lessThanOrEqualTo(paths.last.length));
    });

    test('reports more than one route when they exist', () {
      final nodes = [
        node('alpha', kind: DepKind.direct, deps: ['shared']),
        node('beta', kind: DepKind.direct, deps: ['shared']),
        node('shared'),
      ];

      final paths = dependencyPathsTo('shared', nodes);

      expect(paths, hasLength(2));
      expect(paths.map((p) => p.first), containsAll(['alpha', 'beta']));
    });

    test('caps how many routes are returned', () {
      final nodes = [
        for (var i = 0; i < 6; i++)
          node('root$i', kind: DepKind.direct, deps: ['shared']),
        node('shared'),
      ];

      expect(dependencyPathsTo('shared', nodes, maxPaths: 2), hasLength(2));
    });

    test('does not loop on a cycle', () {
      final nodes = [
        node('root', kind: DepKind.direct, deps: ['a']),
        node('a', deps: ['b']),
        node('b', deps: ['a', 'target']),
        node('target'),
      ];

      final paths = dependencyPathsTo('target', nodes);

      expect(paths, isNotEmpty);
      expect(paths.first.first, 'root');
      // A cycle must not appear as a repeated step.
      expect(paths.first.toSet().length, paths.first.length);
    });

    test('an unknown package has no paths', () {
      expect(dependencyPathsTo('ghost', [node('http')]), isEmpty);
    });

    test('an orphan with no declared ancestor has no paths', () {
      final nodes = [
        node('root', kind: DepKind.direct),
        node('orphan'),
      ];

      expect(dependencyPathsTo('orphan', nodes), isEmpty);
    });

    test('ignores edges to packages outside the report', () {
      final nodes = [
        node('root', kind: DepKind.direct, deps: ['missing', 'target']),
        node('target'),
      ];

      expect(dependencyPathsTo('target', nodes), [
        ['root', 'target'],
      ]);
    });
  });

  group('PackageDetailView', () {
    Future<void> pump(WidgetTester tester, String package, List<DepNode> nodes) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PackageDetailView(package: package, nodes: nodes),
            ),
          ),
        );

    testWidgets('says so when the project declares the package', (tester) async {
      await pump(tester, 'http', [
        node('http', kind: DepKind.direct),
      ]);

      expect(find.textContaining('Why is http here?'), findsOneWidget);
      expect(find.textContaining('declare this directly'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders every step of the chain', (tester) async {
      await pump(tester, 'yaml', [
        node('test', kind: DepKind.dev, deps: ['analyzer'], installed: '1.25.0'),
        node('analyzer', deps: ['yaml'], installed: '14.1.0'),
        node('yaml', installed: '3.1.2'),
      ]);

      expect(find.textContaining('test 1.25.0'), findsOneWidget);
      expect(find.textContaining('analyzer 14.1.0'), findsOneWidget);
      expect(find.textContaining('yaml 3.1.2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('surfaces advisories for the selected package',
        (tester) async {
      await pump(tester, 'http', [
        node(
          'http',
          kind: DepKind.direct,
          status: DepStatus.vulnerable,
          advisories: const [
            DepAdvisory(
              id: 'GHSA-1234',
              aliases: ['CVE-2026-0001'],
              summary: 'Header injection through unvalidated input.',
              fixedIn: '1.4.2',
            ),
          ],
        ),
      ]);

      // Once in the heading, once in the link to read it.
      expect(find.textContaining('GHSA-1234'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('leads an advisory with the version that fixes it',
        (tester) async {
      await pump(tester, 'http', [
        node(
          'http',
          kind: DepKind.direct,
          installed: '1.2.0',
          status: DepStatus.vulnerable,
          advisories: const [
            DepAdvisory(
              id: 'GHSA-1234',
              aliases: ['CVE-2026-0001'],
              summary: 'Header injection through unvalidated input.',
              fixedIn: '1.4.2',
            ),
          ],
        ),
      ]);

      expect(find.text('GHSA-1234  ·  CVE-2026-0001'), findsOneWidget);
      expect(find.textContaining('Header injection'), findsOneWidget);
      expect(find.text('Fixed in 1.4.2.'), findsOneWidget);
      expect(
        find.textContaining('osv.dev/vulnerability/GHSA-1234'),
        findsOneWidget,
      );
    });

    // "No fix listed" must not read as "upgrading clears it".
    testWidgets('says when an advisory names no fixed version', (tester) async {
      await pump(tester, 'http', [
        node(
          'http',
          kind: DepKind.direct,
          installed: '1.2.0',
          status: DepStatus.vulnerable,
          advisories: const [DepAdvisory(id: 'GHSA-unfixed')],
        ),
      ]);

      expect(find.textContaining('names no fixed version'), findsOneWidget);
      expect(find.textContaining('Fixed in'), findsNothing);
    });

    testWidgets('warns when the upgrade is breaking', (tester) async {
      await pump(tester, 'http', [
        node(
          'http',
          kind: DepKind.direct,
          installed: '1.2.0',
          latest: '2.0.0',
          constraint: '^1.0.0',
        ),
      ]);

      expect(find.text('Breaking upgrade'), findsOneWidget);
      // Mentioned by the risk summary and by the "you declare this" line.
      expect(find.textContaining('pubspec.yaml'), findsWidgets);
      expect(find.textContaining('widened deliberately'), findsOneWidget);
      // The claim must stay honest about what semver can and cannot tell us.
      expect(find.textContaining('your own code'), findsOneWidget);
      expect(find.textContaining('pub.dev/packages/http/changelog'),
          findsOneWidget);
    });

    testWidgets('calls a routine bump out as such', (tester) async {
      await pump(tester, 'http', [
        node(
          'http',
          kind: DepKind.direct,
          installed: '1.2.0',
          latest: '1.4.0',
          constraint: '^1.0.0',
        ),
      ]);

      expect(find.text('Minor upgrade'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('says nothing to do when already latest', (tester) async {
      await pump(tester, 'http', [
        node(
          'http',
          kind: DepKind.direct,
          installed: '2.0.0',
          latest: '2.0.0',
          constraint: '^2.0.0',
        ),
      ]);

      expect(find.text('Up to date'), findsOneWidget);
      // No changelog nagging when there is nothing to read about.
      expect(find.textContaining('changelog'), findsNothing);
    });

    testWidgets('lists the concrete changes behind a breaking upgrade',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PackageDetailView(
              package: 'http',
              nodes: [
                node(
                  'http',
                  kind: DepKind.direct,
                  installed: '1.0.0',
                  latest: '3.0.0',
                  constraint: '^1.0.0',
                ),
              ],
              onLoadDetails: () async => const UpgradeDetails(
                impact: UpgradeImpact(
                  package: 'http',
                  from: '1.0.0',
                  to: '3.0.0',
                  majorVersionsCrossed: ['2.0.0', '3.0.0'],
                  releasesBetween: 7,
                  sdkAfter: '^3.8.0',
                  projectSdk: '^3.6.0',
                  sdkTooNew: true,
                  dependencyChanges: [
                    DependencyDelta(
                      package: 'meta',
                      kind: DependencyDeltaKind.changed,
                      before: '^1.0.0',
                      after: '^2.0.0',
                    ),
                    DependencyDelta(
                      package: 'path',
                      kind: DependencyDeltaKind.added,
                      after: '^1.9.0',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('2 breaking releases'), findsOneWidget);
      expect(find.textContaining('7 releases'), findsOneWidget);
      expect(find.textContaining('Needs Dart SDK ^3.8.0'), findsOneWidget);
      expect(find.textContaining('meta: ^1.0.0 → ^2.0.0'), findsOneWidget);
      expect(find.textContaining('Starts requiring path'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    /// Pumps the sheet for a breaking upgrade of `http`, with [apiDiff] as the
    /// stored public-API comparison.
    Future<void> pumpWithDiff(WidgetTester tester, ApiDiff? apiDiff) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PackageDetailView(
                package: 'http',
                nodes: [
                  node(
                    'http',
                    kind: DepKind.direct,
                    installed: '1.0.0',
                    latest: '2.0.0',
                    constraint: '^1.0.0',
                  ),
                ],
                onLoadDetails: () async => UpgradeDetails(
                  impact: const UpgradeImpact(
                    package: 'http',
                    from: '1.0.0',
                    to: '2.0.0',
                    majorVersionsCrossed: ['2.0.0'],
                    releasesBetween: 3,
                  ),
                  apiDiff: apiDiff,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('names the declarations an upgrade removes', (tester) async {
      await pumpWithDiff(
        tester,
        const ApiDiff(
          package: 'http',
          from: '1.0.0',
          to: '2.0.0',
          changes: [
            ApiChange(
              kind: ApiChangeKind.removed,
              declaration: 'Client.send',
              before: 'Future<Response> (Request request)',
            ),
            ApiChange(
              kind: ApiChangeKind.changed,
              declaration: 'Response.url',
              before: 'String',
              after: 'Uri',
            ),
          ],
        ),
      );

      expect(find.textContaining('1 declaration removed'), findsOneWidget);
      expect(find.textContaining('1 changed signature'), findsOneWidget);
      expect(find.text('Client.send'), findsOneWidget);
      expect(find.text('Response.url'), findsOneWidget);
      expect(find.text('String'), findsOneWidget);
      expect(find.text('→ Uri'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('does not claim to know whether this project breaks',
        (tester) async {
      await pumpWithDiff(
        tester,
        const ApiDiff(
          package: 'http',
          from: '1.0.0',
          to: '2.0.0',
          changes: [
            ApiChange(
              kind: ApiChangeKind.removed,
              declaration: 'Client.send',
              before: 'Future<Response> (Request request)',
            ),
          ],
        ),
      );

      expect(find.textContaining('is not checked'), findsOneWidget);
    });

    testWidgets('caps a long list and counts the rest', (tester) async {
      await pumpWithDiff(
        tester,
        ApiDiff(
          package: 'http',
          from: '1.0.0',
          to: '2.0.0',
          changes: [
            for (var i = 0; i < 11; i++)
              ApiChange(
                kind: ApiChangeKind.removed,
                declaration: 'Client.gone$i',
                before: 'void ()',
              ),
          ],
        ),
      );

      expect(find.text('Client.gone0'), findsOneWidget);
      expect(find.text('Client.gone7'), findsOneWidget);
      expect(find.text('Client.gone8'), findsNothing);
      expect(find.textContaining('and 3 more'), findsOneWidget);
    });

    testWidgets('says so when the public API is unchanged', (tester) async {
      await pumpWithDiff(
        tester,
        const ApiDiff(
          package: 'http',
          from: '1.0.0',
          to: '2.0.0',
          changes: [
            ApiChange(
              kind: ApiChangeKind.added,
              declaration: 'Client.head',
              after: 'Future<Response> (Uri url)',
            ),
          ],
        ),
      );

      expect(
        find.textContaining('Nothing was removed or changed'),
        findsOneWidget,
      );
      expect(find.textContaining('1 addition only'), findsOneWidget);
    });

    // "Not computed" and "nothing changed" are different answers, and reading
    // the first as the second is exactly the mistake that would matter.
    testWidgets('distinguishes an uncomputed diff from an empty one',
        (tester) async {
      await pumpWithDiff(tester, null);

      expect(find.textContaining('have not been compared yet'), findsOneWidget);
      expect(find.textContaining('Nothing changed'), findsNothing);
    });

    testWidgets('stays quiet when the impact cannot be loaded',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PackageDetailView(
              package: 'http',
              nodes: [
                node(
                  'http',
                  kind: DepKind.direct,
                  installed: '1.0.0',
                  latest: '2.0.0',
                  constraint: '^1.0.0',
                ),
              ],
              onLoadDetails: () async => throw Exception('offline'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The semver assessment still stands on its own.
      expect(find.text('Breaking upgrade'), findsOneWidget);
      expect(find.textContaining('Could not load'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // A repository with more than one pubspec can hold the same package at two
    // versions; looking it up by name alone would show whichever came last.
    testWidgets('shows the row that was tapped, not one with the same name',
        (tester) async {
      const older = DepNode(
        name: 'analyzer',
        kind: DepKind.direct,
        installed: '7.7.1',
        manifests: ['tools/api_differ'],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PackageDetailView(
              package: 'analyzer',
              selected: older,
              nodes: const [
                DepNode(
                  name: 'analyzer',
                  kind: DepKind.direct,
                  installed: '12.1.0',
                  manifests: ['repository root'],
                ),
                older,
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('installed 7.7.1'), findsOneWidget);
      expect(find.text('From tools/api_differ'), findsOneWidget);
    });

    testWidgets('says nothing about manifests in a single-package repo',
        (tester) async {
      await pump(tester, 'http', [
        node('http', kind: DepKind.direct),
      ]);

      expect(find.textContaining('From '), findsNothing);
    });

    testWidgets('explains when nothing pulls the package in', (tester) async {
      await pump(tester, 'orphan', [
        node('root', kind: DepKind.direct),
        node('orphan'),
      ]);

      expect(find.textContaining('No path found'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
