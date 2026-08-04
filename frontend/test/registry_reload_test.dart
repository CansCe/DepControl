import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/main.dart';
import 'package:frontend/scans/scan_overlay.dart';
import 'package:frontend/scans/scan_queue.dart';
import 'package:frontend/theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';

Project _project(String name) => Project(
      id: 'p-$name',
      gitUrl: 'https://github.com/acme/$name',
      name: name,
      ownerId: 'u1',
    );

final _report = DepReport(
  projectId: 'p1',
  generatedAt: DateTime.utc(2026, 1, 1),
  nodes: const [
    DepNode(
      name: 'http',
      kind: DepKind.direct,
      installed: '1.2.0',
      status: DepStatus.upToDate,
    ),
  ],
);

/// A backend whose project list only starts returning the project once the scan
/// has finished — so a screen that never re-reads the list keeps showing
/// nothing, exactly as reported.
///
/// Speaks the queued-scan protocol: the POST is answered at once with a job
/// that is merely written down, and [finishAdd] is what a worker on the other
/// side eventually does to it.
({ApiClient api, void Function() finishAdd, int Function() listCalls})
    _backend() {
  var added = false;
  var listCalls = 0;
  String? scanId;

  http.Response json(Object body, [int status = 200]) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
      );

  ScanProgress progress(ScanPhase phase) => ScanProgress(
        phase: phase,
        startedAt: DateTime.utc(2026, 1, 1),
        phaseStartedAt: DateTime.utc(2026, 1, 1),
      );

  final api = ApiClient(
    accessToken: () async => 'token',
    client: MockClient((request) async {
      final path = request.url.path;

      if (request.method == 'POST') {
        scanId = (jsonDecode(request.body) as Map)['scanId'] as String;
        return json(
          ScanStatus(
            scanId: scanId!,
            state: ScanJobState.queued,
            progress: progress(ScanPhase.queued),
            gitUrl: 'https://github.com/acme/demo',
          ).toJson(),
          202,
        );
      }

      if (path == '/scans') return json({'scans': <Object>[]});

      if (path.startsWith('/scans/')) {
        if (scanId == null) return json({'error': 'no such scan'}, 404);
        return json(
          ScanStatus(
            scanId: scanId!,
            state: added ? ScanJobState.done : ScanJobState.running,
            progress: progress(added ? ScanPhase.done : ScanPhase.analyzing),
            gitUrl: 'https://github.com/acme/demo',
            projectId: added ? 'p-demo' : null,
          ).toJson(),
        );
      }

      if (path.startsWith('/projects/')) {
        return json({
          'project': _project('demo').toJson(),
          'report': _report.toJson(),
        });
      }

      listCalls++;
      return json({
        'projects': [
          if (added) _project('demo').toJson(),
        ],
      });
    }),
  );

  return (
    api: api,
    finishAdd: () => added = true,
    listCalls: () => listCalls,
  );
}

Widget _app(ApiClient api, ScanQueue scans) => MaterialApp(
      theme: buildTheme(),
      builder: (context, child) =>
          ScanOverlay(queue: scans, child: child ?? const SizedBox()),
      home: RegistryScreen(api: api, scans: scans),
    );

void main() {
  group('RegistryScreen', () {
    testWidgets('reloads the list when a scan lands', (tester) async {
      final backend = _backend();
      final scans = ScanQueue(
        successLinger: Duration.zero,
        pollInterval: const Duration(milliseconds: 10),
      );
      addTearDown(scans.dispose);

      await tester.pumpWidget(_app(backend.api, scans));
      await tester.pumpAndSettle();

      expect(find.textContaining('No projects yet'), findsOneWidget);

      await tester.enterText(
        find.byType(TextField),
        'https://github.com/acme/demo',
      );
      await tester.tap(find.text('Add project'));
      await tester.pump();

      // The form is free again immediately — nothing is waiting on the scan.
      expect(find.textContaining('No projects yet'), findsOneWidget);

      backend.finishAdd();
      await tester.pumpAndSettle();

      expect(find.text('demo'), findsOneWidget);
      expect(find.textContaining('No projects yet'), findsNothing);
    });

    // The reported failure: the list is right only if the screen notices a scan
    // it was not listening for. A screen built after the scan started — or
    // rebuilt while it ran — hears no event, so the reload cannot be driven by
    // one.
    testWidgets('reloads for a scan it never saw start', (tester) async {
      final backend = _backend();
      final scans = ScanQueue(
        successLinger: Duration.zero,
        pollInterval: const Duration(milliseconds: 10),
      );
      addTearDown(scans.dispose);

      // Started before the screen exists, as happens when the user is on a
      // report and the registry has been rebuilt underneath them.
      scans.addProject(backend.api, 'https://github.com/acme/demo');
      await tester.pumpWidget(_app(backend.api, scans));
      // Pumped rather than settled: the scan is already in flight, so the
      // panel is spinning an indicator that by design never comes to rest.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      backend.finishAdd();
      // Long enough for the next poll to see it, which is how a finished scan
      // reaches this client at all now.
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pumpAndSettle();

      expect(find.text('demo'), findsOneWidget);
    });

    testWidgets('a failed scan does not reload the list', (tester) async {
      var listCalls = 0;
      final api = ApiClient(
        accessToken: () async => 'token',
        client: MockClient((request) async {
          if (request.method == 'POST') {
            return http.Response(
              jsonEncode({'error': 'repository not found'}),
              400,
              headers: {'content-type': 'application/json'},
            );
          }
          listCalls++;
          return http.Response(
            jsonEncode({'projects': <Object>[]}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final scans = ScanQueue();
      addTearDown(scans.dispose);

      await tester.pumpWidget(_app(api, scans));
      await tester.pumpAndSettle();
      final before = listCalls;

      await tester.enterText(
        find.byType(TextField),
        'https://github.com/acme/demo',
      );
      await tester.tap(find.text('Add project'));
      await tester.pumpAndSettle();

      expect(find.text('repository not found'), findsOneWidget);
      expect(
        listCalls,
        before,
        reason: 'nothing was added, so there is nothing to re-read',
      );
    });

    testWidgets('a URL that is not one is refused before it is queued',
        (tester) async {
      final backend = _backend();
      final scans = ScanQueue();
      addTearDown(scans.dispose);

      await tester.pumpWidget(_app(backend.api, scans));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'not a url');
      await tester.tap(find.text('Add project'));
      await tester.pump();

      expect(find.textContaining('does not look like a Git URL'), findsOneWidget);
      expect(scans.tasks, isEmpty);
    });
  });
}
