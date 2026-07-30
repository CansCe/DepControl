import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/scans/scan_overlay.dart';
import 'package:frontend/scans/scan_queue.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';

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

Project _project(String id, String name) => Project(
      id: id,
      gitUrl: 'https://github.com/acme/$name',
      name: name,
      ownerId: 'u1',
    );

String _body(String id, String name) => jsonEncode({
      'project': _project(id, name).toJson(),
      'report': _report.toJson(),
    });

/// An API whose responses land only when the test says so, so a scan can be
/// held mid-flight and inspected.
///
/// [progress] is what `GET /scans/<id>` answers with; null means the server
/// cannot say, which is the fallback path clients must survive.
({ApiClient api, Map<String, Completer<http.Response>> gates}) _gatedApi({
  ScanProgress Function()? progress,
}) {
  final gates = <String, Completer<http.Response>>{};
  final api = ApiClient(
    accessToken: () async => 'token',
    client: MockClient((request) {
      final key = request.url.path;
      if (key.startsWith('/scans/')) {
        return Future.value(
          progress == null
              ? http.Response('{}', 404)
              : http.Response(
                  jsonEncode(progress().toJson()),
                  200,
                  headers: {'content-type': 'application/json'},
                ),
        );
      }
      return (gates[key] ??= Completer<http.Response>()).future;
    }),
  );
  return (api: api, gates: gates);
}

ApiClient _immediateApi({int status = 200, String? error}) => ApiClient(
      accessToken: () async => 'token',
      client: MockClient((request) async {
        if (error != null) {
          return http.Response(
            jsonEncode({'error': error}),
            status,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          _body('p1', 'demo'),
          status,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

void main() {
  group('ScanQueue', () {
    test('a queued add reports itself before it finishes', () async {
      final queue = ScanQueue();
      addTearDown(queue.dispose);
      final gated = _gatedApi();

      final task = queue.addProject(gated.api, 'https://github.com/acme/demo');

      expect(task.kind, ScanKind.add);
      // Named from the URL, because the server has not said what the project
      // is called yet and "scanning something" is no use in the panel.
      expect(task.label, 'demo');
      expect(queue.activeCount, 1);
      expect(queue.isBusy, isTrue);
    });

    test('a second project can be added without waiting for the first',
        () async {
      final queue = ScanQueue();
      addTearDown(queue.dispose);
      final gated = _gatedApi();

      queue.addProject(gated.api, 'https://github.com/acme/one');
      queue.addProject(gated.api, 'https://github.com/acme/two');

      expect(queue.activeCount, 2);
      expect(queue.tasks.map((t) => t.label), ['one', 'two']);
    });

    test('scans past the concurrency cap wait their turn', () async {
      final queue = ScanQueue(maxConcurrent: 2);
      addTearDown(queue.dispose);
      final gated = _gatedApi();

      for (final name in ['one', 'two', 'three']) {
        queue.addProject(gated.api, 'https://github.com/acme/$name');
      }
      await pumpEventQueue();

      expect(
        queue.tasks.map((t) => t.state),
        [ScanState.running, ScanState.running, ScanState.queued],
      );
    });

    test('finishing one scan starts the one behind it', () async {
      final queue = ScanQueue(maxConcurrent: 1);
      addTearDown(queue.dispose);
      final gated = _gatedApi();

      queue.addProject(gated.api, 'https://github.com/acme/one');
      queue.addProject(gated.api, 'https://github.com/acme/two');
      await pumpEventQueue();

      expect(queue.tasks[1].state, ScanState.queued);

      gated.gates['/projects']!.complete(
        http.Response(
          _body('p1', 'one'),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      await pumpEventQueue();

      // Not asserted as `running`: both adds hit the same path, so the one
      // gate releases the second scan as well as the first. What matters is
      // that it left the queue rather than sitting behind a finished scan.
      expect(queue.tasks[1].state, isNot(ScanState.queued));
    });

    test('a completed scan carries its project and report', () async {
      final queue = ScanQueue(successLinger: const Duration(minutes: 1));
      addTearDown(queue.dispose);

      final task =
          queue.addProject(_immediateApi(), 'https://github.com/acme/demo');
      await queue.finished.first;

      expect(task.state, ScanState.done);
      expect(task.projectId, 'p1');
      expect(task.report?.total, 1);
      // Renamed to what the server calls it, now that it can be.
      expect(task.label, 'demo');
      expect(queue.isBusy, isFalse);
    });

    test('a failed scan keeps the reason and can be retried', () async {
      final queue = ScanQueue();
      addTearDown(queue.dispose);

      final task = queue.addProject(
        _immediateApi(status: 400, error: 'repository not found'),
        'https://github.com/acme/demo',
      );
      await queue.finished.first;

      expect(task.state, ScanState.failed);
      expect(task.error, 'repository not found');

      queue.retry(task);
      expect(task.state, anyOf(ScanState.queued, ScanState.running));
      expect(task.error, isNull);
      await queue.finished.first;
    });

    test('a successful scan clears itself; a failure stays', () async {
      final queue = ScanQueue(successLinger: const Duration(milliseconds: 20));
      addTearDown(queue.dispose);

      queue.addProject(_immediateApi(), 'https://github.com/acme/ok');
      queue.addProject(
        _immediateApi(status: 400, error: 'nope'),
        'https://github.com/acme/bad',
      );
      await queue.finished.take(2).toList();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(queue.tasks, hasLength(1));
      expect(queue.tasks.single.state, ScanState.failed);
    });

    test('re-analyzing twice does not start two scans', () async {
      final queue = ScanQueue();
      addTearDown(queue.dispose);
      final gated = _gatedApi();
      final project = _project('p1', 'demo');

      final first = queue.reanalyze(gated.api, project);
      final second = queue.reanalyze(gated.api, project);

      expect(identical(first, second), isTrue);
      expect(queue.activeCount, 1);
      expect(queue.isScanning('p1'), isTrue);
    });

    test('a running scan cannot be dismissed', () async {
      final queue = ScanQueue();
      addTearDown(queue.dispose);
      final gated = _gatedApi();

      final task = queue.addProject(gated.api, 'https://github.com/acme/demo');
      queue.dismiss(task.id);

      expect(queue.tasks, hasLength(1));
    });

    test('queued time does not count as scan time', () async {
      final queue = ScanQueue(maxConcurrent: 1);
      addTearDown(queue.dispose);
      final gated = _gatedApi();

      queue.addProject(gated.api, 'https://github.com/acme/one');
      final waiting = queue.addProject(gated.api, 'https://github.com/acme/two');

      expect(waiting.state, ScanState.queued);
      expect(waiting.elapsed, Duration.zero);
    });
  });

  group('ScanOverlay', () {
    Widget host(ScanQueue queue) => MaterialApp(
          builder: (context, child) =>
              ScanOverlay(queue: queue, child: child ?? const SizedBox()),
          home: const Scaffold(body: Text('behind')),
        );

    testWidgets('stays out of the way when nothing is scanning',
        (tester) async {
      final queue = ScanQueue();
      addTearDown(queue.dispose);

      await tester.pumpWidget(host(queue));

      expect(find.text('Scanning'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('names what is being scanned', (tester) async {
      final queue = ScanQueue();
      addTearDown(queue.dispose);
      final gated = _gatedApi();

      await tester.pumpWidget(host(queue));
      queue.addProject(gated.api, 'https://github.com/acme/demo');
      await tester.pump();

      expect(find.text('Scanning'), findsOneWidget);
      expect(find.text('demo'), findsOneWidget);
      expect(find.textContaining('Adding'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      // Leaves nothing running behind it.
      gated.gates['/projects']!.complete(
        http.Response(
          _body('p1', 'demo'),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      await tester.pumpAndSettle();
      queue.clearFinished();
      await tester.pump();
    });

    testWidgets('collapses to a pill and back', (tester) async {
      final queue = ScanQueue(successLinger: Duration.zero);
      addTearDown(queue.dispose);
      final gated = _gatedApi();

      await tester.pumpWidget(host(queue));
      queue.addProject(gated.api, 'https://github.com/acme/demo');
      await tester.pump();

      // Pumped by hand rather than settled: a running scan spins a progress
      // indicator, and `pumpAndSettle` waits for an animation that by design
      // never ends.
      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Scanning 1 repository'), findsOneWidget);
      expect(find.text('demo'), findsNothing);

      await tester.tap(find.text('Scanning 1 repository'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('demo'), findsOneWidget);

      gated.gates['/projects']!.complete(
        http.Response(
          _body('p1', 'demo'),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      await tester.pumpAndSettle();
    });

    testWidgets('shows the count and the time left once the server can say',
        (tester) async {
      final queue = ScanQueue(pollInterval: const Duration(milliseconds: 20));
      addTearDown(queue.dispose);
      final started = DateTime.now().toUtc().subtract(
            const Duration(seconds: 10),
          );
      // 20 packages in 10s, 100 to do: 40 seconds left.
      final gated = _gatedApi(
        progress: () => ScanProgress(
          phase: ScanPhase.analyzing,
          startedAt: started,
          phaseStartedAt: started,
          analysisStartedAt: started,
          packagesDone: 20,
          packagesTotal: 100,
          manifestsSeen: 1,
          manifestsTotal: 1,
        ),
      );

      await tester.pumpWidget(host(queue));
      queue.addProject(gated.api, 'https://github.com/acme/demo');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pump();

      expect(find.textContaining('20 of 100 packages'), findsOneWidget);
      expect(find.textContaining('~40s left'), findsOneWidget);

      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, closeTo(0.2, 0.001));

      gated.gates['/projects']!.complete(
        http.Response(
          _body('p1', 'demo'),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      await tester.pumpAndSettle();
      queue.clearFinished();
      await tester.pump();
    });

    // An older server, or one behind a load balancer that routed the poll to a
    // machine not running the scan. The panel has to stay useful.
    testWidgets('falls back to an indeterminate bar when progress is unknown',
        (tester) async {
      final queue = ScanQueue(pollInterval: const Duration(milliseconds: 20));
      addTearDown(queue.dispose);
      final gated = _gatedApi();

      await tester.pumpWidget(host(queue));
      queue.addProject(gated.api, 'https://github.com/acme/demo');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pump();

      expect(find.textContaining('Adding'), findsOneWidget);
      expect(find.textContaining('left'), findsNothing);

      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(
        bar.value,
        isNull,
        reason: 'an unknown position must not be drawn as zero',
      );

      gated.gates['/projects']!.complete(
        http.Response(
          _body('p1', 'demo'),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      await tester.pumpAndSettle();
      queue.clearFinished();
      await tester.pump();
    });

    testWidgets('says why a scan failed and offers a retry', (tester) async {
      final queue = ScanQueue();
      addTearDown(queue.dispose);

      await tester.pumpWidget(host(queue));
      queue.addProject(
        _immediateApi(status: 400, error: 'repository not found'),
        'https://github.com/acme/demo',
      );
      await tester.pumpAndSettle();

      expect(find.text('repository not found'), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.text('repository not found'), findsNothing);
    });
  });
}
