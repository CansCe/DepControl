import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

Future<void> pump(
  WidgetTester tester, {
  void Function(DepNode)? onSelect,
}) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DepTable(nodes: _nodes, onSelect: onSelect),
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

    testWidgets('rows are inert without a callback', (tester) async {
      await pump(tester);

      await tester.tap(find.text('http'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(Checkbox), findsNothing);
    });
  });
}
