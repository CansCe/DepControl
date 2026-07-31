import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/main.dart';
import 'package:frontend/platform/app_surface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';

/// Records what the registry actually sent, so a test can tell an optimistic
/// row removal apart from a real archive or delete.
class _Recorder {
  final calls = <String>[];

  ApiClient client({List<Project> projects = const [], bool fail = false}) {
    return ApiClient(
      accessToken: () async => 'token',
      client: MockClient((request) async {
        calls.add('${request.method} ${request.url.path}'
            '${request.url.query.isEmpty ? '' : '?${request.url.query}'}');

        if (fail) {
          return http.Response(jsonEncode({'error': 'nope'}), 500);
        }

        return switch (request.method) {
          'DELETE' => http.Response('', 204),
          'PATCH' => http.Response(
              jsonEncode({
                'project': Project(
                  id: 'p1',
                  gitUrl: 'https://github.com/acme/one.git',
                  name: 'one',
                  ownerId: 'u1',
                  archivedAt:
                      jsonDecode(request.body)['archived'] as bool == true
                          ? DateTime.utc(2026, 1, 1)
                          : null,
                ).toJson(),
              }),
              200,
              headers: {'content-type': 'application/json'},
            ),
          _ => http.Response(
              jsonEncode({
                'projects': projects.map((p) => p.toJson()).toList(),
              }),
              200,
              headers: {'content-type': 'application/json'},
            ),
        };
      }),
    );
  }
}

final _projects = [
  Project(
    id: 'p1',
    gitUrl: 'https://github.com/acme/one.git',
    name: 'one',
    ownerId: 'u1',
    addedAt: DateTime.utc(2026, 1, 2),
  ),
  Project(
    id: 'p2',
    gitUrl: 'https://github.com/acme/two.git',
    name: 'two',
    ownerId: 'u1',
    addedAt: DateTime.utc(2026, 1, 1),
  ),
];

Future<void> pumpList(
  WidgetTester tester,
  ApiClient api, {
  bool archived = false,
  List<Project>? projects,
  // The app build, where the swipe exists. A test that wants the browser says
  // so; see the `on the browser build` group.
  AppSurface surface = AppSurface.app,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ProjectList(
          future: Future.value(projects ?? _projects),
          api: api,
          archived: archived,
          surface: surface,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Swipes the row showing [name] in [direction] and settles.
Future<void> swipe(
  WidgetTester tester,
  String name, {
  required bool right,
}) async {
  await tester.drag(
    find.text(name),
    Offset(right ? 600 : -600, 0),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('swipe left to archive', () {
    testWidgets('archives without asking, since it can be undone',
        (tester) async {
      final recorder = _Recorder();
      await pumpList(tester, recorder.client(projects: _projects));

      await swipe(tester, 'one', right: false);

      expect(recorder.calls, contains('PATCH /projects/p1'));
      expect(find.text('one'), findsNothing);
      expect(find.text('two'), findsOneWidget);
    });

    testWidgets('offers an undo', (tester) async {
      final recorder = _Recorder();
      await pumpList(tester, recorder.client(projects: _projects));

      await swipe(tester, 'one', right: false);

      expect(find.textContaining('one archived'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);
    });

    testWidgets('undo restores the row and the project', (tester) async {
      final recorder = _Recorder();
      await pumpList(tester, recorder.client(projects: _projects));

      await swipe(tester, 'one', right: false);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(find.text('one'), findsOneWidget);
      // Archived, then un-archived.
      expect(
        recorder.calls.where((c) => c == 'PATCH /projects/p1').length,
        2,
      );
    });

    testWidgets('puts the row back when the server refuses', (tester) async {
      final recorder = _Recorder();
      await pumpList(tester, recorder.client(fail: true));

      await swipe(tester, 'one', right: false);

      expect(find.text('one'), findsOneWidget);
      expect(find.text('nope'), findsOneWidget);
    });
  });

  group('swipe right to delete', () {
    // Deleting takes the report with it and the server keeps no copy, so an
    // "undo" would be a lie. It asks instead.
    testWidgets('asks before deleting anything', (tester) async {
      final recorder = _Recorder();
      await pumpList(tester, recorder.client(projects: _projects));

      await swipe(tester, 'one', right: true);

      expect(find.textContaining('Delete one?'), findsOneWidget);
      expect(find.textContaining('cannot be undone'), findsOneWidget);
      expect(recorder.calls.any((c) => c.startsWith('DELETE')), isFalse);
    });

    testWidgets('cancelling keeps the project', (tester) async {
      final recorder = _Recorder();
      await pumpList(tester, recorder.client(projects: _projects));

      await swipe(tester, 'one', right: true);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('one'), findsOneWidget);
      expect(recorder.calls.any((c) => c.startsWith('DELETE')), isFalse);
    });

    testWidgets('confirming deletes it', (tester) async {
      final recorder = _Recorder();
      await pumpList(tester, recorder.client(projects: _projects));

      await swipe(tester, 'one', right: true);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(recorder.calls, contains('DELETE /projects/p1'));
      expect(find.text('one'), findsNothing);
      expect(find.textContaining('one deleted'), findsOneWidget);
    });
  });

  group('the archived view', () {
    testWidgets('swiping left restores instead of archiving', (tester) async {
      final recorder = _Recorder();
      await pumpList(
        tester,
        recorder.client(projects: _projects),
        archived: true,
      );

      await swipe(tester, 'one', right: false);

      expect(recorder.calls, contains('PATCH /projects/p1'));
      expect(find.textContaining('one restored'), findsOneWidget);
    });

    testWidgets('says so when nothing is archived', (tester) async {
      final recorder = _Recorder();
      await pumpList(
        tester,
        recorder.client(),
        archived: true,
        projects: const [],
      );

      expect(find.text('Nothing archived.'), findsOneWidget);
    });
  });

  group('on the browser build', () {
    testWidgets('rows cannot be swiped', (tester) async {
      final recorder = _Recorder();
      await pumpList(
        tester,
        recorder.client(projects: _projects),
        surface: AppSurface.browser,
      );

      expect(find.byType(Dismissible), findsNothing);
    });

    testWidgets('a drag across a row deletes nothing', (tester) async {
      // The gesture is not merely hidden — it must not fire. A mouse drag
      // across a list is an ordinary thing to do by accident, and on the old
      // build a rightward one deleted a project.
      final recorder = _Recorder();
      await pumpList(
        tester,
        recorder.client(projects: _projects),
        surface: AppSurface.browser,
      );

      await swipe(tester, 'one', right: true);

      expect(find.text('one'), findsOneWidget);
      expect(recorder.calls, isNot(contains('DELETE /projects/p1')));
    });

    testWidgets('the menu still carries both actions', (tester) async {
      // Removing the gesture removes nothing, because this was always the
      // discoverable path to the same two actions.
      final recorder = _Recorder();
      await pumpList(
        tester,
        recorder.client(projects: _projects),
        surface: AppSurface.browser,
      );

      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();

      expect(find.text('Archive'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('the app build keeps its swipe', (tester) async {
      final recorder = _Recorder();
      await pumpList(tester, recorder.client(projects: _projects));

      expect(find.byType(Dismissible), findsWidgets);
    });
  });

  testWidgets('the same actions are reachable from a menu', (tester) async {
    final recorder = _Recorder();
    await pumpList(tester, recorder.client(projects: _projects));

    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();

    expect(find.text('Archive'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);

    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();

    expect(recorder.calls, contains('PATCH /projects/p1'));
  });

  group('on a wide screen', () {
    testWidgets('lays projects out in columns instead of one long list',
        (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final recorder = _Recorder();
      await pumpList(
        tester,
        recorder.client(projects: _projects),
        surface: AppSurface.browser,
      );

      expect(find.byType(GridView), findsOneWidget);
      expect(find.byType(ListView), findsNothing);
    });

    testWidgets('a narrow window keeps the single-column list', (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final recorder = _Recorder();
      await pumpList(
        tester,
        recorder.client(projects: _projects),
        surface: AppSurface.browser,
      );

      // A grid forces every cell to one height; a single column of rows should
      // keep sizing to its content.
      expect(find.byType(ListView), findsOneWidget);
      expect(find.byType(GridView), findsNothing);
    });
  });
}
