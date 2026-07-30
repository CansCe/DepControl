import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/widgets/dep_kind_badge.dart';
import 'package:frontend/widgets/dep_table.dart';
import 'package:shared/shared.dart';

const _nodes = [
  DepNode(
    name: 'http',
    kind: DepKind.direct,
    installed: '1.2.0',
    latest: '1.3.0',
    status: DepStatus.outdated,
  ),
  DepNode(
    name: 'collection',
    kind: DepKind.transitive,
    installed: '1.19.0',
    latest: '1.19.0',
    status: DepStatus.upToDate,
  ),
];

/// [width] under 600 exercises the compact layout, over it the wide table.
///
/// Wrapped in a scroll view because that is where the real screen puts it — the
/// table is one block inside the report's single scroll view, which is exactly
/// why it has to limit how many rows it builds.
Future<void> pump(
  WidgetTester tester, {
  void Function(DepNode)? onSelect,
  double width = 800,
  List<DepNode> nodes = _nodes,
}) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: width,
              child: DepTable(nodes: nodes, onSelect: onSelect),
            ),
          ),
        ),
      ),
    );

void main() {
  group('DepTable', () {
    test('fixture sanity', () => expect(_nodes, hasLength(2)));

    testWidgets('lists every dependency', (tester) async {
      await pump(tester);

      expect(find.text('http'), findsOneWidget);
      expect(find.text('collection'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // Regression: making rows tappable via onSelectChanged turned this into a
    // selectable table, which adds a checkbox per row and a "select all" in the
    // header. That header calls onSelectChanged for every row at once, so a
    // single tap would have opened a detail sheet per dependency.
    testWidgets('has no selection checkboxes', (tester) async {
      await pump(tester, onSelect: (_) {});

      expect(find.byType(Checkbox), findsNothing);
    });

    testWidgets('tapping a row reports that row once', (tester) async {
      final tapped = <String>[];
      await pump(tester, onSelect: (node) => tapped.add(node.name));

      await tester.tap(find.text('http'));
      await tester.pumpAndSettle();

      expect(tapped, ['http']);
    });

    testWidgets('tapping any column reports the same row', (tester) async {
      final tapped = <String>[];
      await pump(tester, onSelect: (node) => tapped.add(node.name));

      // The status chip sits in the last column.
      await tester.tap(find.text('1.19.0').first);
      await tester.pumpAndSettle();

      expect(tapped, ['collection']);
    });

    // On a phone-width screen a five-column table only shows two of them, so
    // the layout stacks instead.
    group('compact layout', () {
      testWidgets('drops the table for a stacked list', (tester) async {
        await pump(tester, width: 400);

        expect(find.byType(DataTable), findsNothing);
        expect(find.text('http'), findsOneWidget);
        expect(find.text('collection'), findsOneWidget);
      });

      testWidgets('shows the kind as a badge, not a column', (tester) async {
        await pump(tester, width: 400);

        expect(find.byType(DepKindBadge), findsNWidgets(2));
        expect(find.text('direct'), findsOneWidget);
        expect(find.text('transitive'), findsOneWidget);
      });

      testWidgets('an up-to-date package shows one version', (tester) async {
        await pump(tester, width: 400, nodes: const [
          DepNode(
            name: 'collection',
            kind: DepKind.transitive,
            installed: '1.19.0',
            latest: '1.19.0',
            status: DepStatus.upToDate,
          ),
        ]);

        expect(find.text('1.19.0'), findsOneWidget);
        expect(find.textContaining('→'), findsNothing);
        expect(find.text('up to date'), findsOneWidget);
      });

      testWidgets('an outdated package shows the move', (tester) async {
        await pump(tester, width: 400, nodes: const [
          DepNode(
            name: 'http',
            kind: DepKind.direct,
            installed: '1.2.0',
            latest: '1.3.0',
            status: DepStatus.outdated,
          ),
        ]);

        expect(find.textContaining('1.2.0'), findsOneWidget);
        expect(find.textContaining('→'), findsOneWidget);
        expect(find.textContaining('1.3.0'), findsOneWidget);
        expect(find.text('outdated'), findsOneWidget);
      });

      testWidgets('rows stay tappable', (tester) async {
        final tapped = <String>[];
        await pump(
          tester,
          width: 400,
          onSelect: (node) => tapped.add(node.name),
        );

        await tester.tap(find.text('http'));
        await tester.pumpAndSettle();

        expect(tapped, ['http']);
      });

      testWidgets('sorting is still reachable', (tester) async {
        await pump(tester, width: 400);

        // No column headers to tap, so a sort control takes their place.
        expect(find.text('Package'), findsOneWidget);
        await tester.tap(find.text('Package'));
        await tester.pumpAndSettle();

        expect(find.text('Status'), findsOneWidget);
        await tester.tap(find.text('Status'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
      });
    });

    // A monorepo resolving well over a thousand packages made the report screen
    // crawl, because the table sits in the report's one scroll view and so
    // every row it holds is a built widget whether or not it is on screen.
    group('long lists', () {
      List<DepNode> manyNodes(int count) => [
            for (var i = 0; i < count; i++)
              DepNode(
                name: 'package_${i.toString().padLeft(4, '0')}',
                kind: DepKind.transitive,
                installed: '1.0.0',
                latest: '1.0.0',
                status: DepStatus.upToDate,
              ),
          ];

      testWidgets('holds back all but the first page', (tester) async {
        await pump(tester, width: 400, nodes: manyNodes(250));

        expect(find.text('package_0000'), findsOneWidget);
        expect(find.text('package_0099'), findsOneWidget);
        expect(find.text('package_0100'), findsNothing);
        // And says so, rather than quietly answering "is it here?" with no.
        expect(find.text('100 of 250 packages'), findsOneWidget);
        expect(find.text('150 more not shown'), findsOneWidget);
      });

      testWidgets('shows more on request', (tester) async {
        await pump(tester, width: 400, nodes: manyNodes(250));

        await tester.ensureVisible(find.text('Show 100 more'));
        await tester.tap(find.text('Show 100 more'));
        await tester.pumpAndSettle();

        expect(find.text('200 of 250 packages'), findsOneWidget);

        await tester.ensureVisible(find.text('Show all'));
        await tester.tap(find.text('Show all'));
        await tester.pumpAndSettle();

        expect(find.text('250 packages'), findsOneWidget);
        expect(find.textContaining('not shown'), findsNothing);
      });

      testWidgets('a filter reaches a package past the first page',
          (tester) async {
        await pump(tester, width: 400, nodes: manyNodes(250));

        expect(find.text('package_0200'), findsNothing);

        // A fragment rather than the whole name: the field's own text is a
        // Text widget too, so filtering by the exact name would match twice
        // and prove nothing about the row.
        await tester.enterText(find.byType(TextField), '_0200');
        await tester.pumpAndSettle();

        expect(find.text('package_0200'), findsOneWidget);
        expect(find.text('1 package'), findsOneWidget);
      });

      testWidgets('says when a filter matches nothing', (tester) async {
        await pump(tester, width: 400, nodes: manyNodes(20));

        await tester.enterText(find.byType(TextField), 'nothing_like_this');
        await tester.pumpAndSettle();

        expect(find.text('No package here matches that.'), findsOneWidget);
      });

      testWidgets('the wide table paginates too', (tester) async {
        await pump(tester, width: 900, nodes: manyNodes(250));

        expect(find.byType(DataTable), findsOneWidget);
        expect(find.text('package_0100'), findsNothing);
        expect(find.text('150 more not shown'), findsOneWidget);
      });

      // A short list should show no sign that any of this exists.
      testWidgets('a short list gets no footer', (tester) async {
        await pump(tester, width: 400);

        expect(find.textContaining('not shown'), findsNothing);
        expect(find.text('2 packages'), findsOneWidget);
      });
    });

    testWidgets('rows are inert without a callback', (tester) async {
      await pump(tester);

      await tester.tap(find.text('http'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(Checkbox), findsNothing);
    });
  });
}
