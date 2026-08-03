import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/project_index.dart';
import 'package:frontend/platform/breakpoints.dart';
import 'package:frontend/routing/app_route.dart';
import 'package:frontend/routing/app_router.dart';
import 'package:frontend/screens/report_screen.dart';
import 'package:frontend/theme.dart';
import 'package:frontend/widgets/console_shell.dart';
import 'package:frontend/widgets/project_card.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';

const _nodes = [
  DepNode(
    name: 'a',
    kind: DepKind.direct,
    installed: '1.0.0',
    latest: '2.0.0',
    status: DepStatus.outdated,
  ),
  DepNode(
    name: 'b',
    kind: DepKind.transitive,
    installed: '2.0.0',
    status: DepStatus.upToDate,
  ),
];

final _project = Project(
  id: 'p1',
  gitUrl: 'https://github.com/owner/repo',
  name: 'repo',
  lastCheckedAt: DateTime.now().subtract(const Duration(hours: 2)),
);

ApiClient _api() => ApiClient(
      baseUrl: 'http://test',
      accessToken: () async => 'token',
      client: MockClient((request) async {
        // The registry, for the sidebar.
        if (request.url.path.endsWith('/projects')) {
          return http.Response(
            jsonEncode([_project.toJson()]),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        // `GET /projects/<id>` answers with both halves; the report screen
        // reads one of them.
        return http.Response(
          jsonEncode({
            'project': _project.toJson(),
            'report': DepReport(
              projectId: 'p1',
              generatedAt: DateTime.now(),
              nodes: _nodes,
            ).toJson(),
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

/// Sizes the window and cleans up after itself.
void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Widget _app(Widget home, {bool console = true}) => MaterialApp(
      theme: console ? buildConsoleTheme() : buildTheme(),
      home: home,
    );

void main() {
  group('which skin a window gets', () {
    test('the console needs a genuinely wide window, not merely a wide one', () {
      // A half-width browser window is `medium`, and 240 pixels of rail there
      // costs more than the layout it would replace.
      expect(Layout.forWidth(800).isWide, isTrue);
      expect(Layout.forWidth(800).isConsole, isFalse);
      expect(Layout.forWidth(1099).isConsole, isFalse);
      expect(Layout.forWidth(1100).isConsole, isTrue);
      expect(Layout.forWidth(400).isConsole, isFalse);
    });

    testWidgets('a narrow window keeps the layout the app already had',
        (tester) async {
      _size(tester, const Size(800, 900));

      await tester.pumpWidget(
        _app(
          console: false,
          const ConsoleFrame(
            console: Text('console'),
            compact: Text('compact'),
          ),
        ),
      );

      expect(find.text('compact'), findsOneWidget);
      expect(find.text('console'), findsNothing);
    });

    testWidgets('a wide window gets the console body', (tester) async {
      _size(tester, const Size(1500, 950));

      await tester.pumpWidget(
        _app(
          const ConsoleFrame(
            console: Text('console'),
            compact: Text('compact'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('console'), findsOneWidget);
      expect(find.text('compact'), findsNothing);
    });
  });

  // Every other case here mounts the shell under `MaterialApp(home:)`, which
  // puts it *below* the Navigator and therefore below an Overlay. Production
  // does the opposite — `main.dart` mounts it in `MaterialApp.builder`, above
  // the Navigator, so the chrome survives the navigation it drives — and that
  // is the arrangement in which a tooltip in the bar has nowhere to go.
  //
  // So this group mounts it the way the app does. Without an Overlay of the
  // shell's own it throws on the first frame, and in a release build that
  // surfaced as `RenderBox was not laid out` against a minified frame, which
  // names neither the tooltip nor the Overlay.
  group('mounted above the Navigator, as the app mounts it', () {
    Widget asTheAppMountsIt({ProjectIndex? index}) => MaterialApp(
          theme: buildConsoleTheme(),
          builder: (context, child) => ConsoleShell(
            router: AppRouterDelegate(api: _api()),
            index: index ?? (ProjectIndex()..adopt([_project])),
            email: 'someone@example.com',
            child: child ?? const SizedBox(),
          ),
          home: const Text('routed content'),
        );

    testWidgets('builds without an Overlay lookup failure', (tester) async {
      _size(tester, const Size(1500, 950));

      await tester.pumpWidget(asTheAppMountsIt());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('routed content'), findsOneWidget);
    });

    // The specific widget that failed, named so a future change to the bar
    // cannot quietly reintroduce it.
    testWidgets('the top bar can hold a tooltip', (tester) async {
      _size(tester, const Size(1500, 950));

      await tester.pumpWidget(asTheAppMountsIt());
      await tester.pumpAndSettle();

      expect(find.byType(Tooltip), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });

  group('the sidebar', () {
    testWidgets('lists the tracked projects and marks the open one',
        (tester) async {
      _size(tester, const Size(1500, 950));
      final index = ProjectIndex()..adopt([_project]);

      await tester.pumpWidget(
        _app(
          ConsoleShell(
            router: AppRouterDelegate(api: _api())
              ..go(const AppRoute.report('p1')),
            api: _api(),
            email: 'someone@example.com',
            index: index,
            child: const Text('body'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('DepControl'), findsOneWidget);
      expect(find.text('TRACKED PROJECTS'), findsOneWidget);
      // Once in the rail. The body is a stub here, so there is nothing else on
      // screen that would name it.
      expect(find.text('repo'), findsOneWidget);
      expect(find.text('Archived'), findsOneWidget);
      expect(find.text('someone@example.com'), findsOneWidget);
    });

    testWidgets('drops its labels when the window is only just wide enough',
        (tester) async {
      _size(tester, const Size(1150, 900));

      await tester.pumpWidget(
        _app(
          ConsoleShell(
            router: AppRouterDelegate(api: _api()),
            api: _api(),
            index: ProjectIndex()..adopt([_project]),
            child: const Text('body'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The rail is icons only, so neither the wordmark nor the section
      // headings are set — but the destinations are all still reachable.
      expect(find.text('DepControl'), findsNothing);
      expect(find.text('DC'), findsOneWidget);
      expect(find.text('TRACKED PROJECTS'), findsNothing);
      expect(find.byIcon(Icons.inventory_2_outlined), findsOneWidget);
    });

    testWidgets('says the search field does not work yet rather than eating '
        'what is typed into it', (tester) async {
      _size(tester, const Size(1500, 950));

      await tester.pumpWidget(
        _app(
          ConsoleShell(
            router: AppRouterDelegate(api: _api()),
            api: _api(),
            index: ProjectIndex(),
            child: const Text('body'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Rendered, but not a field: a box that accepted a query and did nothing
      // with it would be worse than one that plainly cannot be typed in.
      expect(find.text('Search registry…'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });
  });

  group('the registry grid', () {
    testWidgets('a card carries only what the registry actually knows',
        (tester) async {
      _size(tester, const Size(1500, 950));

      await tester.pumpWidget(
        _app(
          Scaffold(
            body: SizedBox(
              width: 560,
              height: 152,
              child: ProjectCard(
                project: _project,
                onOpen: () {},
                onArchive: () {},
                onDelete: () async {},
              ),
            ),
          ),
        ),
      );

      expect(find.text('repo'), findsOneWidget);
      expect(find.text('https://github.com/owner/repo'), findsOneWidget);
      expect(find.text('HEAD'), findsOneWidget);
      expect(find.text('2h ago'), findsOneWidget);
      // No status word and no version: both are facts about a report the
      // registry never loaded.
      expect(find.text('STABLE'), findsNothing);
    });
  });

  group('the report', () {
    testWidgets('splits into tabs and keeps the totals above them',
        (tester) async {
      _size(tester, const Size(1500, 950));
      ProjectIndex.instance.reset();

      await tester.pumpWidget(
        // Wrapped in a Scaffold because a console body is deliberately bare —
        // the shell above the Navigator is what normally supplies the Material
        // its tabs and rows ink onto.
        _app(Scaffold(body: ReportScreen(project: _project, api: _api()))),
      );
      await tester.pumpAndSettle();

      expect(find.text('PACKAGES'), findsOneWidget);
      expect(find.text('ADVISORIES'), findsOneWidget);
      expect(find.text('LICENSES'), findsOneWidget);
      expect(find.text('TREE'), findsOneWidget);

      // The header carries the counts, so switching tab never loses them.
      expect(find.text('DEPENDENCIES'), findsOneWidget);
      expect(find.text('OUTDATED'), findsOneWidget);
      expect(find.text('VULNERABLE'), findsOneWidget);
    });

    testWidgets('an advisories tab with nothing in it says so', (tester) async {
      _size(tester, const Size(1500, 950));
      ProjectIndex.instance.reset();

      await tester.pumpWidget(
        // Wrapped in a Scaffold because a console body is deliberately bare —
        // the shell above the Navigator is what normally supplies the Material
        // its tabs and rows ink onto.
        _app(Scaffold(body: ReportScreen(project: _project, api: _api()))),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('ADVISORIES'));
      await tester.pumpAndSettle();

      // An empty tab reads as a failure to load; the all-clear does not.
      expect(find.text('No known vulnerabilities.'), findsOneWidget);
    });
  });

  group('moving between projects', () {
    testWidgets('swaps the content and leaves the shell standing',
        (tester) async {
      _size(tester, const Size(1500, 950));

      final router = AppRouterDelegate(api: _api());
      final index = ProjectIndex()
        ..adopt([
          _project,
          Project(id: 'p2', gitUrl: 'https://github.com/owner/other',
              name: 'other'),
        ]);

      await tester.pumpWidget(
        _app(
          ConsoleShell(
            router: router,
            api: _api(),
            index: index,
            child: const Text('body'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The State object identity is the assertion: if the rail were rebuilt on
      // navigation — which is what made opening a project read as a full page
      // load — this would be a different one afterwards.
      final before = tester.state(find.byType(ConsoleShell));

      router.go(const AppRoute.report('p1'));
      await tester.pumpAndSettle();
      router.go(const AppRoute.report('p2'));
      await tester.pumpAndSettle();

      expect(tester.state(find.byType(ConsoleShell)), same(before));
    });

    testWidgets('lights the project the route is on', (tester) async {
      _size(tester, const Size(1500, 950));

      final router = AppRouterDelegate(api: _api());
      await tester.pumpWidget(
        _app(
          ConsoleShell(
            router: router,
            api: _api(),
            index: ProjectIndex()..adopt([_project]),
            child: const Text('body'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The rail reads the route rather than being told by whichever screen
      // happens to be mounted, so it cannot disagree with the address bar.
      router.go(const AppRoute.registry(archived: true));
      await tester.pumpAndSettle();

      final archived = tester.widget<Icon>(
        find.byIcon(Icons.inventory_2_outlined),
      );
      expect(archived.color, Surfaces.dark.accent);
    });
  });

  group('the two skins agree about what a colour means', () {
    test('breaking never collapses into the advisory red', () {
      // The whole reason MAJOR is not drawn in red: red already means
      // "vulnerable" here, and a major bump is work rather than danger.
      expect(Surfaces.light.major, isNot(Surfaces.light.alarm));
      expect(Surfaces.dark.major, isNot(Surfaces.dark.alarm));
    });

    test('each skin sets its own faces', () {
      expect(Surfaces.light.faces.mono, 'IBM Plex Mono');
      expect(Surfaces.dark.faces.mono, 'JetBrains Mono');
    });
  });
}
