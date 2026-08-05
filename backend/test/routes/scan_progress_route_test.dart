import 'dart:convert';
import 'dart:io';

import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:backend/src/repository/project_repository.dart';
import 'package:backend/src/services/scan_progress_store.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import '../support/fakes.dart';

import '../../routes/projects/index.dart' as projects_route;
import '../../routes/scans/[id].dart' as scan_route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

void main() {
  late InMemoryProjectRepository repository;
  late Deps deps;

  const alice = AuthUser(
    id: 'a0000000-0000-0000-0000-00000000000a',
    role: 'authenticated',
    email: 'alice@example.com',
  );

  _MockRequestContext contextFor({
    required HttpMethod method,
    Object? body,
    String path = '/projects',
  }) {
    final request = _MockRequest();
    when(() => request.method).thenReturn(method);
    when(() => request.uri).thenReturn(Uri.parse('http://localhost$path'));
    when(request.json).thenAnswer((_) async => body);
    when(() => request.headers).thenReturn(const {});

    final context = _MockRequestContext();
    when(() => context.request).thenReturn(request);
    when(context.read<Deps>).thenReturn(deps);
    when(context.read<AuthUser>).thenReturn(alice);
    return context;
  }

  Future<Map<String, dynamic>> jsonOf(Response response) async =>
      jsonDecode(await response.body()) as Map<String, dynamic>;

  setUp(() {
    repository = InMemoryProjectRepository();
    deps = Deps.forTesting(
      repository: repository,
      gitFetcher: FakeGitFetcher(),
      analyzer: FakeAnalyzer(),
    );
  });

  Future<Response> submitAdd(String scanId, {String repo = 'demo'}) =>
      projects_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          body: {
            'gitUrl': 'https://github.com/acme/$repo.git',
            'scanId': scanId,
          },
        ),
      );

  Future<Response> readScan(String scanId) => scan_route.onRequest(
        contextFor(method: HttpMethod.get, path: '/scans/$scanId'),
        scanId,
      );

  group('scan progress', () {
    test('a queued scan is describable before anything has run', () async {
      await submitAdd('scan-1');

      // The difference this phase makes: there is something to read the moment
      // the request is answered, rather than only once a worker has started.
      final status = ScanStatus.fromJson(await jsonOf(await readScan('scan-1')));
      expect(status.state, ScanJobState.queued);
      expect(status.progress.phase, ScanPhase.queued);
    });

    test('the scan records what it did, and the route serves it', () async {
      await submitAdd('scan-1');
      await deps.scanRunner.drain();

      final response = await readScan('scan-1');
      expect(response.statusCode, HttpStatus.ok);

      final status = ScanStatus.fromJson(await jsonOf(response));
      expect(status.state, ScanJobState.done);
      expect(status.progress.phase, ScanPhase.done);
      expect(status.projectId, isNotNull);
      // The fake analyzer reports one package per node it returns.
      expect(status.progress.packagesDone, status.progress.packagesTotal);
      expect(status.progress.packagesTotal, greaterThan(0));
    });

    test('the answer outlives the memory it was recorded in', () async {
      await submitAdd('scan-1');
      await deps.scanRunner.drain();

      // What a restart looks like from the route's side: the in-memory store is
      // gone and the row is all there is. Before this phase that was a 404 and
      // the client was told to guess.
      deps.scanProgress.remove('scan-1');

      final status = ScanStatus.fromJson(await jsonOf(await readScan('scan-1')));
      expect(status.state, ScanJobState.done);
      expect(status.progress.phase, ScanPhase.done);
    });

    test('a scan belonging to somebody else is a 404, not a 403', () async {
      await submitAdd('scan-1');

      const bob = AuthUser(
        id: 'b0000000-0000-0000-0000-00000000000b',
        role: 'authenticated',
        email: 'bob@example.com',
      );
      final context = contextFor(method: HttpMethod.get, path: '/scans/scan-1');
      when(context.read<AuthUser>).thenReturn(bob);

      // The id is one the *client* invented, so it is guessable — which is
      // exactly why this route stopped being keyed on the id alone.
      final response = await scan_route.onRequest(context, 'scan-1');
      expect(response.statusCode, HttpStatus.notFound);
    });

    test('an unknown scan is a 404, not an error', () async {
      final response = await readScan('nope');

      expect(response.statusCode, HttpStatus.notFound);
    });

    test('a failed scan records why', () async {
      deps = Deps.forTesting(
        repository: repository,
        gitFetcher: FakeGitFetcher(
          onFetch: (_, __) => throw StateError('repository not found'),
        ),
        analyzer: FakeAnalyzer(),
      );

      await submitAdd('scan-3', repo: 'gone');
      await deps.scanRunner.drain();

      final status = ScanStatus.fromJson(await jsonOf(await readScan('scan-3')));
      expect(status.state, ScanJobState.failed);
      expect(status.error, 'repository not found');
      expect(status.progress.phase, ScanPhase.failed);
      expect(status.progress.error, 'repository not found');
    });
  });

  group('ScanProgressStore', () {
    test('drops finished entries once they are stale', () {
      final store = ScanProgressStore(retention: Duration.zero);
      final old = DateTime.now().toUtc().subtract(const Duration(minutes: 10));
      store
        ..put(
          'old',
          ScanProgress(
            phase: ScanPhase.done,
            startedAt: old,
            phaseStartedAt: old,
          ),
        )
        // A second write is what triggers the tidy-up.
        ..put(
          'new',
          ScanProgress(
            phase: ScanPhase.fetching,
            startedAt: DateTime.now().toUtc(),
            phaseStartedAt: DateTime.now().toUtc(),
          ),
        );

      expect(store['old'], isNull);
      expect(store['new'], isNotNull);
    });

    // The id comes from the client, so the map it keys must not be unbounded.
    test('never grows past its capacity', () {
      final store = ScanProgressStore(capacity: 3);
      for (var i = 0; i < 20; i++) {
        final at = DateTime.now().toUtc().add(Duration(seconds: i));
        store.put(
          'scan-$i',
          ScanProgress(
            phase: ScanPhase.fetching,
            startedAt: at,
            phaseStartedAt: at,
          ),
        );
      }

      expect(store['scan-19'], isNotNull);
      expect(store['scan-0'], isNull);
    });
  });
}
