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
  List<String> advisories = const [],
}) =>
    DepNode(
      name: name,
      kind: kind,
      installed: installed,
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

  group('DependencyPathView', () {
    Future<void> pump(WidgetTester tester, String package, List<DepNode> nodes) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DependencyPathView(package: package, nodes: nodes),
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
          advisories: ['GHSA-1234'],
        ),
      ]);

      expect(find.textContaining('GHSA-1234'), findsOneWidget);
      expect(tester.takeException(), isNull);
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
