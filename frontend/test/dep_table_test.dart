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
Future<void> pump(
  WidgetTester tester, {
  void Function(DepNode)? onSelect,
  double width = 800,
  List<DepNode> nodes = _nodes,
}) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: width,
            child: DepTable(nodes: nodes, onSelect: onSelect),
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

    testWidgets('rows are inert without a callback', (tester) async {
      await pump(tester);

      await tester.tap(find.text('http'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(Checkbox), findsNothing);
    });
  });
}
