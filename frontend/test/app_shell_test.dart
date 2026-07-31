import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/routing/app_route.dart';
import 'package:frontend/routing/app_router.dart';
import 'package:frontend/scans/scan_queue.dart';
import 'package:frontend/shell/app_shell.dart';
import 'package:frontend/shell/project_rail.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';

final _projects = [
  Project(
    id: 'p1',
    gitUrl: 'https://github.com/acme/one.git',
    name: 'one',
    ownerId: 'u1',
  ),
  Project(
    id: 'p2',
    gitUrl: 'https://github.com/acme/two.git',
    name: 'two',
    ownerId: 'u1',
  ),
];

ApiClient _api({List<Project> active = const [], List<Project> archived = const []}) =>
    ApiClient(
      accessToken: () async => 'token',
      client: MockClient((request) async {
        final wantsArchived = request.url.query.contains('archived=true');
        return http.Response(
          jsonEncode({
            'projects': [
              for (final p in wantsArchived ? archived : active) p.toJson(),
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

/// The shell around a stand-in page, with a real router so the rail can drive
/// navigation.
Future<AppRouterDelegateProbe> pumpShell(
  WidgetTester tester, {
  required ApiClient api,
  Size size = const Size(1400, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final probe = AppRouterDelegateProbe(api: api);
  await tester.pumpWidget(
    MaterialApp.router(
      routerDelegate: probe,
      routeInformationParser: const AppRouteParser(),
      builder: (context, child) => AppShell(
        router: probe,
        api: api,
        scans: ScanQueue(successLinger: Duration.zero),
        child: child ?? const SizedBox(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return probe;
}

/// Scoped to the rail, because the registry page lists projects too — the rail
/// navigates between them and the page manages them, so both showing a name is
/// the design rather than a duplicate.
Finder inRail(String text) => find.descendant(
      of: find.byType(ProjectRail),
      matching: find.text(text),
    );

void main() {
  group('the project rail', () {
    testWidgets('stays on screen beside the page on a wide window',
        (tester) async {
      // The point of the whole shell: opening a report no longer replaces the
      // list, so switching projects is one click rather than back-then-pick.
      await pumpShell(tester, api: _api(active: _projects));

      expect(find.byType(ProjectRail), findsOneWidget);
      expect(inRail('one'), findsOneWidget);
      expect(inRail('two'), findsOneWidget);
    });

    testWidgets('is behind a menu button on a narrow window', (tester) async {
      await pumpShell(
        tester,
        api: _api(active: _projects),
        size: const Size(420, 900),
      );

      // Not on screen, but reachable — one list, in a drawer.
      expect(find.byType(ProjectRail), findsNothing);
      expect(find.byIcon(Icons.menu), findsOneWidget);
      // The word gives way to the mark; the sections stay reachable.
      expect(find.text('DepControl'), findsNothing);

      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();

      expect(find.byType(ProjectRail), findsOneWidget);
      expect(inRail('one'), findsOneWidget);
    });

    testWidgets('has no menu button when the rail is already showing',
        (tester) async {
      // A button that reveals something visible is a button that does nothing.
      await pumpShell(tester, api: _api(active: _projects));

      expect(find.byIcon(Icons.menu), findsNothing);
    });

    testWidgets('picking a project routes to its report', (tester) async {
      final probe = await pumpShell(tester, api: _api(active: _projects));

      await tester.tap(inRail('two'));
      await tester.pumpAndSettle();

      expect(probe.currentConfiguration, const AppRoute.report('p2'));
      // And the rail is still there, which is the whole point.
      expect(find.byType(ProjectRail), findsOneWidget);
    });

    testWidgets('switching projects replaces rather than stacks',
        (tester) async {
      // The rail makes projects siblings: clicking three in a row is browsing,
      // not descending, and back should not have to walk all three.
      final probe = await pumpShell(tester, api: _api(active: _projects));

      await tester.tap(inRail('one'));
      await tester.pumpAndSettle();
      await tester.tap(inRail('two'));
      await tester.pumpAndSettle();

      expect(probe.stack.length, 2);
      expect(probe.currentConfiguration, const AppRoute.report('p2'));
    });

    testWidgets('shows archived projects under their own heading',
        (tester) async {
      await pumpShell(
        tester,
        api: _api(
          active: [_projects.first],
          archived: [
            Project(
              id: 'p9',
              gitUrl: 'https://github.com/acme/old.git',
              name: 'old-thing',
              ownerId: 'u1',
              archivedAt: DateTime.utc(2026, 1, 1),
            ),
          ],
        ),
      );

      expect(inRail('Archived'), findsOneWidget);
      expect(inRail('old-thing'), findsOneWidget);
    });

    testWidgets('invites the first project rather than reporting emptiness',
        (tester) async {
      await pumpShell(tester, api: _api());

      expect(
        find.descendant(
          of: find.byType(ProjectRail),
          matching: find.textContaining('Add a repository by its Git URL'),
        ),
        findsOneWidget,
      );
    });
  });

  group('the header', () {
    testWidgets('names the product and both sections, on every route',
        (tester) async {
      await pumpShell(tester, api: _api(active: _projects));

      expect(find.text('DepControl'), findsOneWidget);
      expect(find.text('Projects'), findsWidgets);
      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('keeps its sections after navigating into a report',
        (tester) async {
      // An AppBar would have been replaced by the report's own; a header is
      // part of the page and stays.
      await pumpShell(tester, api: _api(active: _projects));

      await tester.tap(inRail('one'));
      await tester.pumpAndSettle();

      expect(find.text('DepControl'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
    });
  });
}

/// The real delegate, with its stack exposed so a test can assert on history.
class AppRouterDelegateProbe extends AppRouterDelegate {
  AppRouterDelegateProbe({required super.api});
}
