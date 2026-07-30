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

  group('scan progress', () {
    test('an add that names a scan leaves progress behind for it', () async {
      final response = await projects_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          body: {
            'gitUrl': 'https://github.com/acme/demo.git',
            'scanId': 'scan-1',
          },
        ),
      );

      expect(response.statusCode, HttpStatus.created);

      final progress = deps.scanProgress['scan-1'];
      expect(progress, isNotNull);
      expect(progress!.phase, ScanPhase.done);
      // The fake analyzer reports one package per node it returns.
      expect(progress.packagesDone, progress.packagesTotal);
      expect(progress.packagesTotal, greaterThan(0));
    });

    test('an add that names no scan records nothing', () async {
      await projects_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          body: {'gitUrl': 'https://github.com/acme/demo.git'},
        ),
      );

      expect(deps.scanProgress['scan-1'], isNull);
    });

    test('the route serves what the scan recorded', () async {
      await projects_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          body: {
            'gitUrl': 'https://github.com/acme/demo.git',
            'scanId': 'scan-2',
          },
        ),
      );

      final response = await scan_route.onRequest(
        contextFor(method: HttpMethod.get, path: '/scans/scan-2'),
        'scan-2',
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = await jsonOf(response);
      expect(body['phase'], 'done');
      expect(ScanProgress.fromJson(body).phase, ScanPhase.done);
    });

    // Progress lives in this process only. A scan that has aged out, or one
    // running on another instance, is a 404 — and the client is expected to
    // read that as "cannot say" rather than as a failure.
    test('an unknown scan is a 404, not an error', () async {
      final response = await scan_route.onRequest(
        contextFor(method: HttpMethod.get, path: '/scans/nope'),
        'nope',
      );

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

      final response = await projects_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          body: {
            'gitUrl': 'https://github.com/acme/gone.git',
            'scanId': 'scan-3',
          },
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      final progress = deps.scanProgress['scan-3']!;
      expect(progress.phase, ScanPhase.failed);
      expect(progress.error, 'repository not found');
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
