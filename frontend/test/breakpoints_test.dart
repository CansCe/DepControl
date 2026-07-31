import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/platform/breakpoints.dart';

void main() {
  group('choosing a layout', () {
    test('is decided by width, at the documented edges', () {
      expect(Layout.forWidth(360), Layout.compact);
      expect(Layout.forWidth(719), Layout.compact);
      expect(Layout.forWidth(720), Layout.medium);
      expect(Layout.forWidth(1099), Layout.medium);
      expect(Layout.forWidth(1100), Layout.expanded);
      expect(Layout.forWidth(2560), Layout.expanded);
    });

    test('gives a wide window more columns', () {
      expect(Layout.compact.registryColumns, 1);
      expect(Layout.medium.registryColumns, 2);
      expect(Layout.expanded.registryColumns, 3);
    });

    test('a browser dragged narrow is the same as a phone', () {
      // A width question, never a platform one — nothing here asks which build
      // it is, so a narrow browser window gets the phone's layout.
      expect(Layout.forWidth(400), Layout.compact);
      expect(Layout.forWidth(400).isCompact, isTrue);
      expect(Layout.forWidth(1400).isWide, isTrue);
    });
  });

  group('BoundedWidth', () {
    testWidgets('caps the child on a wide screen', (tester) async {
      tester.view.physicalSize = const Size(2560, 1440);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const MaterialApp(
          home: BoundedWidth(
            max: 1000,
            child: SizedBox(height: 10, key: Key('content')),
          ),
        ),
      );

      // Not 2560: a row that wide puts the project name at one end of the desk
      // and its menu at the other.
      expect(tester.getSize(find.byKey(const Key('content'))).width, 1000);
    });

    testWidgets('leaves a narrow screen alone', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const MaterialApp(
          home: BoundedWidth(
            max: 1000,
            child: SizedBox(height: 10, key: Key('content')),
          ),
        ),
      );

      expect(tester.getSize(find.byKey(const Key('content'))).width, 400);
    });
  });
}
