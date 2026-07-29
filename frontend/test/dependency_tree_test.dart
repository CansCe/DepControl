import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/widgets/dependency_tree.dart';
import 'package:shared/shared.dart';

DepNode node(
  String name, {
  DepKind kind = DepKind.transitive,
  List<String> deps = const [],
  String installed = '1.0.0',
  List<String> manifests = const [],
  List<DepAdvisory> advisories = const [],
}) =>
    DepNode(
      name: name,
      kind: kind,
      installed: installed,
      dependencies: deps,
      manifests: manifests,
      advisories: advisories,
      status: advisories.isEmpty ? DepStatus.upToDate : DepStatus.vulnerable,
    );

DepReport report(List<DepNode> nodes, {List<String> manifests = const []}) =>
    DepReport(
      projectId: 'p1',
      generatedAt: DateTime.utc(2026),
      nodes: nodes,
      manifests: manifests,
    );

Future<void> pump(
  WidgetTester tester,
  DepReport data, {
  void Function(DepNode)? onSelect,
  bool showCurrency = true,
}) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 800,
              child: DependencyTree(
                report: data,
                onSelect: onSelect,
                showCurrency: showCurrency,
              ),
            ),
          ),
        ),
      ),
    );

/// Opens the disclosure control on the row showing [name].
Future<void> expand(WidgetTester tester, String name) async {
  final row = find.ancestor(of: find.text(name), matching: find.byType(Row));
  await tester.tap(
    find.descendant(of: row.first, matching: find.byType(IconButton)).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  group('DependencyTree', () {
    testWidgets('starts at what the project declares, collapsed', (
      tester,
    ) async {
      await pump(
        tester,
        report([
          node('http', kind: DepKind.direct, deps: ['meta']),
          node('meta'),
        ]),
      );

      expect(find.text('http'), findsOneWidget);
      // The transitive package is behind a disclosure, not on screen yet.
      expect(find.text('meta'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('expanding a branch shows what it pulls in', (tester) async {
      await pump(
        tester,
        report([
          node('http', kind: DepKind.direct, deps: ['meta', 'async']),
          node('async', deps: ['collection']),
          node('meta'),
          node('collection'),
        ]),
      );

      await expand(tester, 'http');
      expect(find.text('meta'), findsOneWidget);
      expect(find.text('async'), findsOneWidget);
      // One level only — the grandchild waits for its own branch to open.
      expect(find.text('collection'), findsNothing);

      await expand(tester, 'async');
      expect(find.text('collection'), findsOneWidget);
    });

    testWidgets('tapping a package reports it', (tester) async {
      DepNode? selected;
      await pump(
        tester,
        report([node('http', kind: DepKind.direct)]),
        onSelect: (n) => selected = n,
      );

      await tester.tap(find.text('http'));
      await tester.pump();

      expect(selected?.name, 'http');
    });

    testWidgets('a loop stops the branch instead of recursing', (tester) async {
      await pump(
        tester,
        report([
          node('a', kind: DepKind.direct, deps: ['b']),
          node('b', deps: ['a']),
        ]),
      );

      await expand(tester, 'a');
      await expand(tester, 'b');

      expect(
        find.textContaining('already above this', findRichText: true),
        findsOneWidget,
      );
      // The walk stopped: `a` is still on screen exactly once, as the root.
      expect(find.text('a'), findsOneWidget);
    });

    testWidgets('states the loop before anyone opens a branch', (tester) async {
      await pump(
        tester,
        report([
          node('a', kind: DepKind.direct, deps: ['b']),
          node('b', deps: ['a']),
        ]),
      );

      expect(find.text('1 dependency loop'), findsOneWidget);
      expect(find.text('a → b → a'), findsOneWidget);
    });

    testWidgets('flags a package held at two versions', (tester) async {
      await pump(
        tester,
        report(
          [
            node('app', kind: DepKind.direct, deps: ['meta'], manifests: ['.']),
            node(
              'tool',
              kind: DepKind.direct,
              deps: ['meta'],
              manifests: ['tools/'],
            ),
            node('meta', installed: '1.9.0', manifests: ['.']),
            node('meta', installed: '1.16.0', manifests: ['tools/']),
          ],
          manifests: ['.', 'tools/'],
        ),
      );

      expect(find.text('1 package at two versions'), findsOneWidget);
      expect(find.text('from .'), findsOneWidget);
      expect(find.text('from tools/'), findsOneWidget);

      // In the tree, each branch resolves to the version its own pubspec did,
      // and both rows say there is another one.
      await expand(tester, 'app');
      expect(find.text('1.9.0'), findsNWidgets(2)); // panel and tree row
      expect(find.text('2 versions'), findsOneWidget);

      await expand(tester, 'tool');
      expect(find.text('1.16.0'), findsNWidgets(2));
      expect(find.text('2 versions'), findsNWidgets(2));
    });

    testWidgets('says so when the shape is clean', (tester) async {
      await pump(
        tester,
        report([
          node('http', kind: DepKind.direct, deps: ['meta']),
          node('meta'),
        ]),
      );

      expect(
        find.textContaining('No package appears at two versions'),
        findsOneWidget,
      );
    });

    testWidgets('names packages the tree cannot reach', (tester) async {
      await pump(
        tester,
        report([
          node('flutter', kind: DepKind.direct),
          node('sky_engine'),
        ]),
      );

      expect(find.text('1 package sits outside the tree'), findsOneWidget);
      expect(find.textContaining('sky_engine'), findsOneWidget);
    });

    testWidgets('renders without a root to start from', (tester) async {
      await pump(tester, report([node('meta')]));

      expect(find.textContaining('no root to grow a tree from'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
