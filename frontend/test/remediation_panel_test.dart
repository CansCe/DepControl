import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/widgets/remediation_panel.dart';
import 'package:shared/shared.dart';

Future<void> pump(WidgetTester tester, RemediationPlan plan) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: RemediationPanel(load: () async => plan),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Taps the button that starts the (deliberately on-demand) load.
Future<void> reveal(WidgetTester tester) async {
  await tester.tap(find.textContaining('Work out how to fix'));
  await tester.pumpAndSettle();
}

void main() {
  // Each suggestion costs a full resolution on the server, and most visits to
  // a report are not about fixing anything.
  testWidgets('does not fetch anything until asked', (tester) async {
    var loaded = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RemediationPanel(
            load: () async {
              loaded = true;
              return const RemediationPlan(projectId: 'p1');
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(loaded, isFalse);
    expect(find.textContaining('Work out how to fix'), findsOneWidget);
  });

  testWidgets('shows the pubspec line to change', (tester) async {
    await pump(
      tester,
      const RemediationPlan(
        projectId: 'p1',
        remediations: [
          Remediation(
            package: 'http',
            advisoryIds: ['GHSA-demo'],
            kind: RemediationKind.raiseConstraint,
            editPackage: 'http',
            fromConstraint: '^0.13.0',
            toConstraint: '^0.13.3',
            resolves: [
              VersionChange(package: 'http', from: '0.13.0', to: '0.13.3'),
            ],
          ),
        ],
      ),
    );
    await reveal(tester);

    expect(find.text('- http: ^0.13.0'), findsOneWidget);
    expect(find.text('+ http: ^0.13.3'), findsOneWidget);
    expect(find.textContaining('Resolves http to 0.13.3'), findsOneWidget);
  });

  testWidgets('names the parent when the fix is a transitive one',
      (tester) async {
    await pump(
      tester,
      const RemediationPlan(
        projectId: 'p1',
        remediations: [
          Remediation(
            package: 'archive',
            advisoryIds: ['GHSA-demo'],
            kind: RemediationKind.bumpParent,
            editPackage: 'wrapper',
            fromConstraint: '^1.0.0',
            toConstraint: '^2.0.0',
            resolves: [
              VersionChange(package: 'wrapper', from: '1.0.0', to: '2.0.0'),
              VersionChange(package: 'archive', from: '3.3.0', to: '3.4.10'),
            ],
          ),
        ],
      ),
    );
    await reveal(tester);

    // The edit lands on the declared package, not the vulnerable one.
    expect(find.text('+ wrapper: ^2.0.0'), findsOneWidget);
    expect(find.textContaining('Bump wrapper'), findsOneWidget);
    expect(find.textContaining('Resolves archive to 3.4.10'), findsOneWidget);
  });

  testWidgets('reports the knock-on cost of a fix', (tester) async {
    await pump(
      tester,
      const RemediationPlan(
        projectId: 'p1',
        remediations: [
          Remediation(
            package: 'http',
            advisoryIds: ['GHSA-demo'],
            kind: RemediationKind.raiseConstraint,
            editPackage: 'http',
            toConstraint: '^1.0.0',
            resolves: [
              VersionChange(package: 'http', from: '0.13.0', to: '1.0.0'),
              VersionChange(package: 'meta', from: '1.8.0', to: '1.9.0'),
              VersionChange(package: 'path', from: '1.8.0', to: '1.9.0'),
            ],
          ),
        ],
      ),
    );
    await reveal(tester);

    expect(find.textContaining('moves 2 other packages'), findsOneWidget);
    expect(find.textContaining('meta 1.8.0 → 1.9.0'), findsOneWidget);
  });

  testWidgets('carries a caveat about a breaking fix', (tester) async {
    await pump(
      tester,
      const RemediationPlan(
        projectId: 'p1',
        remediations: [
          Remediation(
            package: 'http',
            advisoryIds: ['GHSA-demo'],
            kind: RemediationKind.raiseConstraint,
            editPackage: 'http',
            toConstraint: '^1.0.0',
            resolves: [
              VersionChange(package: 'http', from: '0.13.0', to: '1.0.0'),
            ],
            caveat: 'This is a breaking upgrade of http (0.13.0 to 1.0.0).',
          ),
        ],
      ),
    );
    await reveal(tester);

    expect(find.textContaining('breaking upgrade'), findsOneWidget);
  });

  group('when there is no fix', () {
    // "We have no suggestion" and "there is no fix" are different situations,
    // and the difference decides whether someone keeps looking.
    testWidgets('distinguishes an unpublished fix from an unreachable one',
        (tester) async {
      await pump(
        tester,
        const RemediationPlan(
          projectId: 'p1',
          remediations: [
            Remediation(
              package: 'abandoned',
              advisoryIds: ['GHSA-a'],
              blocker: RemediationBlocker.noFixPublished,
            ),
            Remediation(
              package: 'pinned',
              advisoryIds: ['GHSA-b'],
              blocker: RemediationBlocker.unreachable,
            ),
          ],
        ),
      );
      await reveal(tester);

      expect(
        find.textContaining('No fixed version has been published'),
        findsOneWidget,
      );
      expect(
        find.textContaining('holds it below the fix'),
        findsOneWidget,
      );
    });

    testWidgets('a blocked package offers no pubspec line', (tester) async {
      await pump(
        tester,
        const RemediationPlan(
          projectId: 'p1',
          remediations: [
            Remediation(
              package: 'abandoned',
              advisoryIds: ['GHSA-a'],
              blocker: RemediationBlocker.noFixPublished,
            ),
          ],
        ),
      );
      await reveal(tester);

      expect(find.textContaining('dependencies:'), findsNothing);
    });
  });

  testWidgets('reports a failure quietly', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RemediationPanel(load: () async => throw Exception('offline')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await reveal(tester);

    expect(find.textContaining('Could not work out fixes'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
