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

ScanProgress _analyzing({int done = 20, int total = 100}) {
  final started = DateTime.now().toUtc().subtract(const Duration(seconds: 10));
  return ScanProgress(
    phase: ScanPhase.analyzing,
    startedAt: started,
    phaseStartedAt: started,
    analysisStartedAt: started,
    packagesDone: done,
    packagesTotal: total,
    manifestsSeen: 1,
    manifestsTotal: 1,
  );
}

ScanProgress _queued() {
  final now = DateTime.now().toUtc();
  return ScanProgress(
    phase: ScanPhase.queued,
    startedAt: now,
    phaseStartedAt: now,
  );
}

/// A server that speaks the queued-scan protocol.
///
/// A scan is a job now: submitting one answers 202 immediately and the work
/// happens somewhere this client cannot see. So the fake keeps every submitted
/// scan running until the test says otherwise — [finish] and [failScan] are
/// what a worker on the other side would eventually do — and counts the polls,
/// because how often this client asks is itself a thing worth asserting.
class _FakeApi {
  _FakeApi({this.answersStatus = true});

  /// When false, `GET /scans/<id>` 404s — a scan this account does not own, or
  /// a server that cannot be reached. Both mean "no news" rather than a
  /// failure, and the client has to survive either.
  final bool answersStatus;

  /// What every scan here eventually produces.
  static const projectName = 'demo';
  static const projectId = 'p1';

  final Map<String, ScanStatus> statuses = {};
  final List<String> submitted = [];
  var polls = 0;

  /// Scans the server already had before this client asked anything, for the
  /// case that matters most: opening the app onto work started elsewhere.
  final List<ScanStatus> preexisting = [];

  late final ApiClient api = ApiClient(
    accessToken: () async => 'token',
    client: MockClient(_handle),
  );

  void finish(String scanId) {
    final current = statuses[scanId]!;
    statuses[scanId] = ScanStatus(
      scanId: scanId,
      state: ScanJobState.done,
      progress: ScanProgress(
        phase: ScanPhase.done,
        startedAt: current.progress.startedAt,
        phaseStartedAt: DateTime.now().toUtc(),
      ),
      gitUrl: current.gitUrl,
      projectId: projectId,
    );
  }

  void failScan(String scanId, String error) {
    final current = statuses[scanId]!;
    statuses[scanId] = ScanStatus(
      scanId: scanId,
      state: ScanJobState.failed,
      progress: current.progress,
      gitUrl: current.gitUrl,
      error: error,
    );
  }

  void report(String scanId, ScanProgress progress) {
    final current = statuses[scanId]!;
    statuses[scanId] = ScanStatus(
      scanId: scanId,
      state: ScanJobState.running,
      progress: progress,
      gitUrl: current.gitUrl,
      projectId: current.projectId,
    );
  }

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;

    if (request.method == 'POST') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final scanId = body['scanId'] as String;
      submitted.add(scanId);
      final status = statuses[scanId] ??= ScanStatus(
        scanId: scanId,
        state: ScanJobState.queued,
        progress: _queued(),
        gitUrl: body['gitUrl'] as String? ??
            'https://github.com/acme/$projectName',
        projectId: path == '/projects' ? null : path.split('/')[2],
      );
      return _json(status.toJson(), 202);
    }

    if (path == '/scans') {
      return _json({
        'scans': [for (final scan in preexisting) scan.toJson()],
      });
    }

    if (path.startsWith('/scans/')) {
      polls++;
      final status = statuses[path.substring('/scans/'.length)];
      if (!answersStatus || status == null) {
        return _json({'error': 'no such scan'}, 404);
      }
      return _json(status.toJson());
    }

    if (path.startsWith('/projects/')) {
      return _json({
        'project': _project(projectId, projectName).toJson(),
        'report': _report.toJson(),
      });
    }

    return _json({'error': 'unexpected $path'}, 500);
  }

  static http.Response _json(Object body, [int status = 200]) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
      );
}

/// An API that refuses the submission itself, which is the one step a client
/// can still lose.
ApiClient _refusingApi({int status = 400, String error = 'nope'}) => ApiClient(
      accessToken: () async => 'token',
      client: MockClient((request) async => http.Response(
            jsonEncode({'error': error}),
            status,
            headers: {'content-type': 'application/json'},
          )),
    );

/// Pumps until [test] holds, or gives up. Real timers, so the poll interval
/// has to actually elapse.
Future<void> _until(bool Function() test, {int tries = 60}) async {
  for (var i = 0; i < tries && !test(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('ScanQueue', () {
    ScanQueue queueFor() => ScanQueue(
          pollInterval: const Duration(milliseconds: 10),
          successLinger: const Duration(minutes: 1),
        );

    test('a queued add reports itself before it finishes', () async {
      final queue = queueFor();
      addTearDown(queue.dispose);
      final server = _FakeApi();

      final task = queue.addProject(server.api, 'https://github.com/acme/demo');

      expect(task.kind, ScanKind.add);
      // Named from the URL, because the server has not said what the project
      // is called yet and "scanning something" is no use in the panel.
      expect(task.label, 'demo');
      expect(queue.activeCount, 1);
      expect(queue.isBusy, isTrue);
    });

    // The change this phase makes, from the client's side: submitting is the
    // only step that waits on anything here. Adding five repositories used to
    // hold three of them behind a local concurrency cap, which now would mean
    // three scans that do not exist on the server and would not survive the tab
    // closing.
    test('every added project is submitted at once', () async {
      final queue = queueFor();
      addTearDown(queue.dispose);
      final server = _FakeApi();

      for (final name in ['one', 'two', 'three', 'four', 'five']) {
        queue.addProject(server.api, 'https://github.com/acme/$name');
      }
      await _until(() => server.submitted.length == 5);

      expect(server.submitted, hasLength(5));
      expect(queue.activeCount, 5);
      expect(
        queue.tasks.every((t) => t.state == ScanState.running),
        isTrue,
      );
    });

    test('a completed scan carries its project and report', () async {
      final queue = queueFor();
      addTearDown(queue.dispose);
      final server = _FakeApi();

      final task = queue.addProject(server.api, 'https://github.com/acme/demo');
      await _until(() => server.submitted.isNotEmpty);
      server.finish(task.id);
      await queue.finished.first;

      expect(task.state, ScanState.done);
      expect(task.projectId, 'p1');
      expect(task.report?.total, 1);
      // Renamed to what the server calls it, now that it can be.
      expect(task.label, 'demo');
      expect(queue.isBusy, isFalse);
    });

    test('a scan the server reports as failed says why', () async {
      final queue = queueFor();
      addTearDown(queue.dispose);
      final server = _FakeApi();

      final task = queue.addProject(server.api, 'https://github.com/acme/demo');
      await _until(() => server.submitted.isNotEmpty);
      server.failScan(task.id, 'repository not found');
      await queue.finished.first;

      expect(task.state, ScanState.failed);
      expect(task.error, 'repository not found');
    });

    test('a submission the server refuses fails immediately', () async {
      final queue = queueFor();
      addTearDown(queue.dispose);

      final task = queue.addProject(
        _refusingApi(error: 'repository not found'),
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

    // Losing sight of a scan is not the scan failing, and the message has to
    // say which of the two happened — the work is still going on the server,
    // and telling somebody it failed would invite them to start it again.
    test('losing contact says the scan is still running', () async {
      final queue = ScanQueue(
        pollInterval: const Duration(milliseconds: 10),
        pollBackoffLimit: const Duration(milliseconds: 20),
        pollGiveUpAfter: const Duration(milliseconds: 60),
      );
      addTearDown(queue.dispose);
      final server = _FakeApi(answersStatus: false);

      final task = queue.addProject(server.api, 'https://github.com/acme/demo');
      await queue.finished.first;

      expect(task.state, ScanState.failed);
      expect(task.error, contains('still running'));
      expect(task.error, isNot(contains('failed')));
    });

    test('an unanswerable scan stops being asked about', () async {
      final queue = ScanQueue(
        pollInterval: const Duration(milliseconds: 10),
        pollBackoffLimit: const Duration(milliseconds: 20),
        pollGiveUpAfter: const Duration(milliseconds: 60),
      );
      addTearDown(queue.dispose);
      final server = _FakeApi(answersStatus: false);

      queue.addProject(server.api, 'https://github.com/acme/demo');
      await queue.finished.first;
      final asked = server.polls;
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(
        server.polls,
        asked,
        reason: 'a 404 that will never change should not be asked for again',
      );
      // A flat 10ms interval would have made twenty in that window alone.
      expect(asked, lessThan(10), reason: 'the interval should have stretched');
    });

    test('a scan the server can describe is polled at the flat interval',
        () async {
      final queue = ScanQueue(
        pollInterval: const Duration(milliseconds: 10),
        // Short enough that a poller counting the *scan* as silent, rather than
        // the run of unanswered polls, would have given up long ago.
        pollGiveUpAfter: const Duration(milliseconds: 40),
      );
      addTearDown(queue.dispose);
      final server = _FakeApi();

      final task = queue.addProject(server.api, 'https://github.com/acme/demo');
      await _until(() => server.submitted.isNotEmpty);
      server.report(task.id, _analyzing());
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(server.polls, greaterThan(8));
      expect(task.state, ScanState.running);
      expect(task.progress?.packagesDone, 20);
    });

    test('re-analyzing twice does not start two scans', () async {
      final queue = queueFor();
      addTearDown(queue.dispose);
      final server = _FakeApi();
      final project = _project('p1', 'demo');

      final first = queue.reanalyze(server.api, project);
      final second = queue.reanalyze(server.api, project);

      expect(identical(first, second), isTrue);
      expect(queue.activeCount, 1);
      expect(queue.isScanning('p1'), isTrue);
    });

    test('a running scan cannot be dismissed', () async {
      final queue = queueFor();
      addTearDown(queue.dispose);
      final server = _FakeApi();

      final task = queue.addProject(server.api, 'https://github.com/acme/demo');
      queue.dismiss(task.id);

      expect(queue.tasks, hasLength(1));
    });

    group('reattaching', () {
      // The point of the whole phase, from the app's side: the work carried on
      // while nobody was looking, and a client that showed an empty panel would
      // invite the person to start the same scan again.
      test('picks up a scan started before the app was opened', () async {
        final queue = queueFor();
        addTearDown(queue.dispose);
        final server = _FakeApi()
          ..preexisting.add(
            ScanStatus(
              scanId: 'scan-elsewhere',
              state: ScanJobState.running,
              progress: _analyzing(),
              gitUrl: 'https://github.com/acme/widget.git',
            ),
          );
        server.statuses['scan-elsewhere'] = server.preexisting.single;

        await queue.reattach(server.api);

        expect(queue.tasks, hasLength(1));
        final task = queue.tasks.single;
        expect(task.id, 'scan-elsewhere');
        expect(task.label, 'widget');
        expect(task.attached, isTrue);

        // And it is genuinely watched, not just listed.
        await _until(() => task.progress != null);
        expect(task.progress?.packagesDone, 20);

        server.finish('scan-elsewhere');
        await queue.finished.first;
        expect(task.state, ScanState.done);
        expect(task.report?.total, 1);
      });

      test('does not double up on a scan this client already has', () async {
        final queue = queueFor();
        addTearDown(queue.dispose);
        final server = _FakeApi();

        final task =
            queue.addProject(server.api, 'https://github.com/acme/demo');
        await _until(() => server.submitted.isNotEmpty);
        server.preexisting.add(server.statuses[task.id]!);

        await queue.reattach(server.api);

        expect(queue.tasks, hasLength(1));
      });

      test('a server that cannot be reached is silent, not an error', () async {
        final queue = queueFor();
        addTearDown(queue.dispose);

        // This runs on launch, and an account with nothing running — which is
        // nearly always — must not be shown an error because the network was
        // briefly away.
        await queue.reattach(_refusingApi(status: 500, error: 'down'));

        expect(queue.tasks, isEmpty);
      });
    });
  });

  group('ScanOverlay', () {
    Widget host(ScanQueue queue) => MaterialApp(
          builder: (context, child) =>
              ScanOverlay(queue: queue, child: child ?? const SizedBox()),
          home: const Scaffold(body: Text('behind')),
        );

    ScanQueue queueFor() => ScanQueue(
          pollInterval: const Duration(milliseconds: 10),
          successLinger: const Duration(minutes: 1),
        );

    testWidgets('stays out of the way when nothing is scanning',
        (tester) async {
      final queue = queueFor();
      addTearDown(queue.dispose);

      await tester.pumpWidget(host(queue));

      expect(find.text('Scanning'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('names what is being scanned', (tester) async {
      final queue = queueFor();
      addTearDown(queue.dispose);
      final server = _FakeApi();

      await tester.pumpWidget(host(queue));
      final task = queue.addProject(server.api, 'https://github.com/acme/demo');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));

      expect(find.text('Scanning'), findsOneWidget);
      expect(find.text('demo'), findsOneWidget);
      // "Starting", not "Adding": the server has accepted the scan and says it
      // is queued, which is a more specific thing to know than the kind of
      // scan it is — and it is what the row has always shown for that phase.
      expect(find.textContaining('Starting'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      // Leaves nothing running behind it.
      server.finish(task.id);
      await tester.pumpAndSettle();
      queue.clearFinished();
      await tester.pump();
    });

    testWidgets('shows the count and the time left once the server can say',
        (tester) async {
      final queue = queueFor();
      addTearDown(queue.dispose);
      final server = _FakeApi();

      await tester.pumpWidget(host(queue));
      final task = queue.addProject(server.api, 'https://github.com/acme/demo');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      // 20 packages in 10s, 100 to do: 40 seconds left.
      server.report(task.id, _analyzing());
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pump();

      expect(find.textContaining('20 of 100 packages'), findsOneWidget);
      expect(find.textContaining('~40s left'), findsOneWidget);

      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, closeTo(0.2, 0.001));

      server.finish(task.id);
      await tester.pumpAndSettle();
      queue.clearFinished();
      await tester.pump();
    });

    // A scan the server will not describe — one still queued, or a poll that
    // could not get through. The panel has to stay useful.
    testWidgets('falls back to an indeterminate bar when progress is unknown',
        (tester) async {
      final queue = queueFor();
      addTearDown(queue.dispose);
      final server = _FakeApi();

      await tester.pumpWidget(host(queue));
      final task = queue.addProject(server.api, 'https://github.com/acme/demo');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));

      expect(find.textContaining('Starting'), findsOneWidget);
      expect(find.textContaining('left'), findsNothing);

      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(
        bar.value,
        isNull,
        reason: 'an unknown position must not be drawn as zero',
      );

      server.finish(task.id);
      await tester.pumpAndSettle();
      queue.clearFinished();
      await tester.pump();
    });

    testWidgets('says why a scan failed and offers a retry', (tester) async {
      final queue = queueFor();
      addTearDown(queue.dispose);

      await tester.pumpWidget(host(queue));
      queue.addProject(
        _refusingApi(error: 'repository not found'),
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
