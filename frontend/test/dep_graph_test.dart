import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/screens/report_screen.dart';
import 'package:frontend/widgets/dep_graph.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';

/// `b` is both a leaf and the target of an edge from `a` — the shape that used
/// to be inserted into the graph twice. `lonely` has no edges at all.
const _nodes = [
  DepNode(
    name: 'a',
    kind: DepKind.direct,
    installed: '1.0.0',
    status: DepStatus.upToDate,
    dependencies: ['b'],
  ),
  DepNode(
    name: 'b',
    kind: DepKind.transitive,
    installed: '2.0.0',
    status: DepStatus.outdated,
  ),
  DepNode(
    name: 'lonely',
    kind: DepKind.dev,
    installed: '3.0.0',
    status: DepStatus.unknown,
  ),
];

void main() {
  // The widget renders nodes lazily, so structure is asserted on the graph
  // itself rather than through the widget tree.
  group('buildDependencyGraph', () {
    // Regression: Graph.addNode does not deduplicate, so a leaf that an edge
    // had already introduced was added a second time. The layout then built
    // two children for one node and corrupted the widget tree.
    test('adds each package exactly once', () {
      final graph = buildDependencyGraph(_nodes);

      expect(graph.nodeCount(), 3);
      expect(
        graph.nodes.map((n) => n.key!.value as String).toList()..sort(),
        ['a', 'b', 'lonely'],
      );
    });

    test('creates one edge per declared dependency', () {
      final graph = buildDependencyGraph(_nodes);

      expect(graph.edges, hasLength(1));
      expect(graph.edges.single.source.key!.value, 'a');
      expect(graph.edges.single.destination.key!.value, 'b');
    });

    test('keeps a package that has no edges', () {
      final graph = buildDependencyGraph(_nodes);
      final names = graph.nodes.map((n) => n.key!.value).toList();

      expect(names, contains('lonely'));
    });

    test('ignores self-edges', () {
      final graph = buildDependencyGraph(const [
        DepNode(
          name: 'a',
          kind: DepKind.direct,
          installed: '1.0.0',
          dependencies: ['a'],
        ),
      ]);

      expect(graph.nodeCount(), 1);
      expect(graph.edges, isEmpty);
    });

    // A lockfile can name a dependency the report doesn't include; an edge to
    // it would introduce a node with no data behind it.
    test('ignores edges pointing outside the report', () {
      final graph = buildDependencyGraph(const [
        DepNode(
          name: 'a',
          kind: DepKind.direct,
          installed: '1.0.0',
          dependencies: ['not_in_report'],
        ),
      ]);

      expect(graph.nodeCount(), 1);
      expect(graph.edges, isEmpty);
    });

    test('an empty report yields an empty graph', () {
      expect(buildDependencyGraph(const []).nodeCount(), 0);
    });
  });

  group('DepGraph widget', () {
    testWidgets('lays out without error', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: DepGraph(nodes: _nodes))),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty node list does not blow up', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: DepGraph(nodes: []))),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('No dependency graph'), findsOneWidget);
    });

    testWidgets('rebuilds when given a new node list', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: DepGraph(nodes: _nodes))),
      );
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: DepGraph(nodes: []))),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('No dependency graph'), findsOneWidget);
    });
  });

  group('ReportScreen', () {
    ApiClient apiReturning(DepReport report) => ApiClient(
          accessToken: () async => 'token',
          client: MockClient((_) async => http.Response(
                jsonEncode({
                  'project': <String, dynamic>{},
                  'report': report.toJson(),
                }),
                200,
                headers: {'content-type': 'application/json'},
              )),
        );

    final project = Project(
      id: 'p1',
      gitUrl: 'https://github.com/acme/demo.git',
      name: 'demo',
      ownerId: 'u1',
    );

    final report = DepReport(
      projectId: 'p1',
      generatedAt: DateTime.utc(2026, 1, 1),
      nodes: _nodes,
    );

    // Regression: opening the graph tab and navigating back asserted inside
    // GraphView's layout, because an unconstrained InteractiveViewer gave it
    // infinite constraints and it could not compute a size.
    testWidgets('survives opening the graph tab and going back',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ReportScreen(
                      project: project,
                      api: apiReturning(report),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('demo'), findsOneWidget);

      await tester.tap(find.text('Graph'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // ...and back out again, which is what used to crash.
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('shows the dependency summary', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ReportScreen(project: project, api: apiReturning(report)),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('dependencies'), findsOneWidget);
      // "outdated" appears both as a summary label and as a row's status chip.
      expect(find.text('outdated'), findsWidgets);
      expect(find.text('vulnerable'), findsOneWidget);
    });
  });
}
