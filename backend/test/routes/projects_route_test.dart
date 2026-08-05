import 'dart:convert';
import 'dart:io';

import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:backend/src/repository/project_repository.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import '../support/fakes.dart';

// Route handlers live outside lib/, so they're imported by path.
import '../../routes/projects/index.dart' as projects_route;
import '../../routes/projects/[id]/index.dart' as project_detail_route;
import '../../routes/projects/[id]/refresh.dart' as project_refresh_route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

void main() {
  late InMemoryProjectRepository repository;
  late Deps deps;

  const alice = AuthUser(id: 'a0000000-0000-0000-0000-00000000000a',
      role: 'authenticated', email: 'alice@example.com');
  const bob = AuthUser(id: 'b0000000-0000-0000-0000-00000000000b',
      role: 'authenticated', email: 'bob@example.com');

  /// Builds a context wired to [repository], the given [user], and a request
  /// with [method]/[body].
  _MockRequestContext contextFor({
    required HttpMethod method,
    required AuthUser user,
    Object? body,
    String path = '/projects',
  }) {
    final request = _MockRequest();
    when(() => request.method).thenReturn(method);
    when(() => request.uri).thenReturn(Uri.parse('http://localhost$path'));
    when(request.json).thenAnswer((_) async => body);
    // A bundle upload is refused on its declared length before the body is
    // read, so every request here has to be able to answer what its headers
    // are. A real client sends none of interest.
    when(() => request.headers).thenReturn(const {});

    final context = _MockRequestContext();
    when(() => context.request).thenReturn(request);
    when(context.read<Deps>).thenReturn(deps);
    when(context.read<AuthUser>).thenReturn(user);
    return context;
  }

  Future<Map<String, dynamic>> jsonOf(Response response) async =>
      jsonDecode(await response.body()) as Map<String, dynamic>;

  /// Runs the queue the way the worker does — **not** through a request.
  ///
  /// That is the whole point of these tests now. A scan is a job, and the
  /// request that asks for one only writes it down; driving the runner from
  /// here is what proves the work does not depend on anybody still holding a
  /// connection.
  Future<void> runQueuedScans() => deps.scanRunner.drain();

  Future<ScanStatus> statusOf(String scanId, AuthUser user) async {
    final job = await deps.scanJobs.byId(scanId, ownerId: user.id);
    return job!.toStatus();
  }

  Project projectFor(AuthUser user, {String id = 'p1', String name = 'demo'}) =>
      Project(
        id: id,
        gitUrl: 'https://github.com/acme/$name.git',
        name: name,
        ownerId: user.id,
        addedAt: DateTime.utc(2026, 1, 1),
      );

  setUp(() {
    repository = InMemoryProjectRepository();
    deps = Deps.forTesting(
      repository: repository,
      gitFetcher: FakeGitFetcher(),
      analyzer: FakeAnalyzer(),
    );
  });

  group('GET /projects', () {
    test('returns an empty list when the user has no projects', () async {
      final response = await projects_route.onRequest(
        contextFor(method: HttpMethod.get, user: alice),
      );

      expect(response.statusCode, HttpStatus.ok);
      expect((await jsonOf(response))['projects'], isEmpty);
    });

    test('returns only the calling user\'s projects', () async {
      await repository.add(projectFor(alice, id: 'p-alice', name: 'alpha'));
      await repository.add(projectFor(bob, id: 'p-bob', name: 'beta'));

      final response = await projects_route.onRequest(
        contextFor(method: HttpMethod.get, user: alice),
      );

      final projects = (await jsonOf(response))['projects'] as List;
      expect(projects, hasLength(1));
      expect((projects.single as Map)['id'], 'p-alice');
      expect((projects.single as Map)['ownerId'], alice.id);
    });
  });

  group('POST /projects', () {
    test('accepts the scan and creates nothing yet', () async {
      final response = await projects_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          user: alice,
          body: {
            'gitUrl': 'https://github.com/acme/widget.git',
            'scanId': 'scan-1',
          },
        ),
      );

      expect(response.statusCode, HttpStatus.accepted);
      final status = ScanStatus.fromJson(await jsonOf(response));
      expect(status.scanId, 'scan-1');
      expect(status.state, ScanJobState.queued);
      expect(status.projectId, isNull);

      // Nothing exists until the work has actually been done. A git URL nobody
      // can clone must not leave a project behind, which is exactly what
      // creating one here to hang the scan off would do.
      expect(await repository.allForOwner(alice.id), isEmpty);
    });

    test('the queued scan creates the project when the worker runs it',
        () async {
      await projects_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          user: alice,
          body: {
            'gitUrl': 'https://github.com/acme/widget.git',
            'scanId': 'scan-1',
          },
        ),
      );

      await runQueuedScans();

      final projects = await repository.allForOwner(alice.id);
      expect(projects, hasLength(1));
      expect(projects.single.ownerId, alice.id);
      expect(projects.single.gitUrl, 'https://github.com/acme/widget.git');
      expect(projects.single.name, 'widget');
      expect(projects.single.ref, 'HEAD');
      expect(await repository.reportFor(projects.single.id), isNotNull);
      expect(await repository.allForOwner(bob.id), isEmpty);

      final status = await statusOf('scan-1', alice);
      expect(status.state, ScanJobState.done);
      expect(status.projectId, projects.single.id);
    });

    test('honours an explicit ref', () async {
      await projects_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          user: alice,
          body: {
            'gitUrl': 'https://github.com/acme/widget.git',
            'ref': 'develop',
            'scanId': 'scan-1',
          },
        ),
      );
      await runQueuedScans();

      final projects = await repository.allForOwner(alice.id);
      expect(projects.single.ref, 'develop');
    });

    test('asking for the same scan twice queues one', () async {
      Future<Response> submit() => projects_route.onRequest(
            contextFor(
              method: HttpMethod.post,
              user: alice,
              body: {
                'gitUrl': 'https://github.com/acme/widget.git',
                'scanId': 'scan-1',
              },
            ),
          );

      expect((await submit()).statusCode, HttpStatus.accepted);
      expect((await submit()).statusCode, HttpStatus.accepted);
      await runQueuedScans();

      // A retried request, or a client that did not hear the first answer.
      // Neither is a second repository to clone.
      expect(await repository.allForOwner(alice.id), hasLength(1));
    });

    test('rejects a missing scanId with 400', () async {
      final response = await projects_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          user: alice,
          body: {'gitUrl': 'https://github.com/acme/widget.git'},
        ),
      );

      // A scan nobody can name is a scan nobody can find again after closing
      // the page, which is the one thing this is all for.
      expect(response.statusCode, HttpStatus.badRequest);
      expect((await jsonOf(response))['error'], contains('scanId'));
    });

    test('rejects a host it cannot read, before queueing anything', () async {
      final response = await projects_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          user: alice,
          body: {
            'gitUrl': 'https://example.com/acme/widget.git',
            'scanId': 'scan-1',
          },
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect((await jsonOf(response))['error'], contains('github.com'));
      expect(await deps.scanJobs.pendingCount(), 0);
    });

    test('rejects a missing gitUrl with 400', () async {
      final response = await projects_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          user: alice,
          body: {'scanId': 'scan-1'},
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect((await jsonOf(response))['error'], contains('gitUrl'));
    });

    test('rejects a non-object body with 400', () async {
      final response = await projects_route.onRequest(
        contextFor(method: HttpMethod.post, user: alice, body: 'not-json'),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect((await jsonOf(response))['error'], contains('JSON object'));
    });

    test('rejects an empty gitUrl with 400', () async {
      final response = await projects_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          user: alice,
          body: {'gitUrl': '', 'scanId': 'scan-1'},
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
    });

    test('an unreachable repo fails the scan, and leaves no project', () async {
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
          user: alice,
          body: {
            'gitUrl': 'https://github.com/acme/missing.git',
            'scanId': 'scan-1',
          },
        ),
      );
      // Accepted: whether a repository exists is not knowable without the
      // network, so it stops being a thing the request can answer.
      expect(response.statusCode, HttpStatus.accepted);

      await runQueuedScans();

      final status = await statusOf('scan-1', alice);
      expect(status.state, ScanJobState.failed);
      expect(status.error, 'repository not found');
      expect(status.progress.phase, ScanPhase.failed);
      expect(await repository.allForOwner(alice.id), isEmpty);
    });

    test('a failed scan is not retried', () async {
      var fetches = 0;
      deps = Deps.forTesting(
        repository: repository,
        gitFetcher: FakeGitFetcher(
          onFetch: (_, __) {
            fetches++;
            throw StateError('repository not found');
          },
        ),
        analyzer: FakeAnalyzer(),
      );

      await projects_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          user: alice,
          body: {
            'gitUrl': 'https://github.com/acme/missing.git',
            'scanId': 'scan-1',
          },
        ),
      );
      await runQueuedScans();
      await runQueuedScans();

      // Retries exist for a worker that died holding a job, not for a scan
      // that ran and found the repository private. Cloning it twice more would
      // not change the answer.
      expect(fetches, 1);
    });
  });

  group('unsupported methods', () {
    test('DELETE /projects is 405', () async {
      final response = await projects_route.onRequest(
        contextFor(method: HttpMethod.delete, user: alice),
      );
      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });

    test('PUT /projects/<id> is 405', () async {
      final response = await project_detail_route.onRequest(
        contextFor(method: HttpMethod.put, user: alice),
        'p1',
      );
      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });

  group('POST /projects/<id>/refresh', () {
    _MockRequestContext refreshContext(AuthUser user, {String? scanId}) =>
        contextFor(
          method: HttpMethod.post,
          user: user,
          body: {if (scanId != null) 'scanId': scanId},
        );

    test('re-analyzes in place instead of creating a second project',
        () async {
      await repository.add(projectFor(alice, id: 'p-alice'));

      final response = await project_refresh_route.onRequest(
        refreshContext(alice, scanId: 'scan-1'),
        'p-alice',
      );

      expect(response.statusCode, HttpStatus.accepted);
      final queued = ScanStatus.fromJson(await jsonOf(response));
      // A refresh knows its project from the start, unlike an add.
      expect(queued.projectId, 'p-alice');

      await runQueuedScans();

      // Still exactly one project, with a fresh report.
      expect(await repository.allForOwner(alice.id), hasLength(1));
      expect(await repository.reportFor('p-alice'), isNotNull);
      expect((await statusOf('scan-1', alice)).state, ScanJobState.done);
    });

    test('stamps lastCheckedAt', () async {
      await repository.add(projectFor(alice, id: 'p-alice'));
      expect((await repository.byId('p-alice', ownerId: alice.id))!.lastCheckedAt,
          isNull);

      await project_refresh_route.onRequest(
        refreshContext(alice, scanId: 'scan-1'),
        'p-alice',
      );
      await runQueuedScans();

      final updated = await repository.byId('p-alice', ownerId: alice.id);
      expect(updated!.lastCheckedAt, isNotNull);
    });

    test('re-fetches the repository at the recorded ref', () async {
      final fetcher = FakeGitFetcher();
      deps = Deps.forTesting(
        repository: repository,
        gitFetcher: fetcher,
        analyzer: FakeAnalyzer(),
      );
      await repository.add(
        projectFor(alice, id: 'p-alice').copyWith(ref: 'develop'),
      );

      await project_refresh_route.onRequest(
        refreshContext(alice, scanId: 'scan-1'),
        'p-alice',
      );
      await runQueuedScans();

      expect(fetcher.calls.single.ref, 'develop');
    });

    test('a second refresh returns the one already queued', () async {
      final fetcher = FakeGitFetcher();
      deps = Deps.forTesting(
        repository: repository,
        gitFetcher: fetcher,
        analyzer: FakeAnalyzer(),
      );
      await repository.add(projectFor(alice, id: 'p-alice'));

      await project_refresh_route.onRequest(
        refreshContext(alice, scanId: 'scan-1'),
        'p-alice',
      );
      final second = await project_refresh_route.onRequest(
        refreshContext(alice, scanId: 'scan-2'),
        'p-alice',
      );
      await runQueuedScans();

      // Pressing Re-analyze twice is somebody checking whether the first press
      // registered. The client has always guarded this; now that the queue
      // outlives the client, a second device can be the one asking.
      expect(ScanStatus.fromJson(await jsonOf(second)).scanId, 'scan-1');
      expect(fetcher.calls, hasLength(1));
    });

    test('refuses a scan for a project archived after it was queued', () async {
      await repository.add(projectFor(alice, id: 'p-alice'));
      await project_refresh_route.onRequest(
        refreshContext(alice, scanId: 'scan-1'),
        'p-alice',
      );

      // A job can sit in the queue across a restart, and archiving means "do
      // not re-fetch this" — which a scan queued beforehand would otherwise go
      // on to do.
      await repository.setArchived('p-alice', ownerId: alice.id, archived: true);
      await runQueuedScans();

      final status = await statusOf('scan-1', alice);
      expect(status.state, ScanJobState.failed);
      expect(status.error, contains('archived'));
    });

    test('404s for a project owned by another user', () async {
      await repository.add(projectFor(alice, id: 'p-alice'));

      final response = await project_refresh_route.onRequest(
        refreshContext(bob, scanId: 'scan-1'),
        'p-alice',
      );

      expect(response.statusCode, HttpStatus.notFound);
    });

    test('rejects a missing scanId with 400', () async {
      await repository.add(projectFor(alice, id: 'p-alice'));

      final response = await project_refresh_route.onRequest(
        refreshContext(alice),
        'p-alice',
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect((await jsonOf(response))['error'], contains('scanId'));
    });

    test('GET is rejected with 405', () async {
      final response = await project_refresh_route.onRequest(
        contextFor(method: HttpMethod.get, user: alice),
        'p-alice',
      );

      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });

    test('a repository that can no longer be fetched fails the scan', () async {
      await repository.add(projectFor(alice, id: 'p-alice'));
      deps = Deps.forTesting(
        repository: repository,
        gitFetcher: FakeGitFetcher(
          onFetch: (_, __) => throw StateError('repository not found'),
        ),
        analyzer: FakeAnalyzer(),
      );

      final response = await project_refresh_route.onRequest(
        refreshContext(alice, scanId: 'scan-1'),
        'p-alice',
      );
      expect(response.statusCode, HttpStatus.accepted);

      await runQueuedScans();

      final status = await statusOf('scan-1', alice);
      expect(status.state, ScanJobState.failed);
      expect(status.error, 'repository not found');
      // The project it was refreshing is untouched — a failed re-scan must not
      // cost somebody the report they already had.
      expect(await repository.byId('p-alice', ownerId: alice.id), isNotNull);
    });
  });

  group('archiving', () {
    setUp(() async {
      await repository.add(projectFor(alice, id: 'p-alice'));
    });

    test('takes the project out of the default listing', () async {
      await project_detail_route.onRequest(
        contextFor(
          method: HttpMethod.patch,
          user: alice,
          body: {'archived': true},
        ),
        'p-alice',
      );

      final listed = await projects_route.onRequest(
        contextFor(method: HttpMethod.get, user: alice),
      );
      expect((await jsonOf(listed))['projects'], isEmpty);
    });

    test('shows it under ?archived=true', () async {
      await repository.setArchived(
        'p-alice',
        ownerId: alice.id,
        archived: true,
      );

      final listed = await projects_route.onRequest(
        contextFor(
          method: HttpMethod.get,
          user: alice,
          path: '/projects?archived=true',
        ),
      );

      final projects = (await jsonOf(listed))['projects'] as List;
      expect(projects, hasLength(1));
      expect((projects.single as Map)['archivedAt'], isNotNull);
    });

    test('restoring puts it back', () async {
      await repository.setArchived(
        'p-alice',
        ownerId: alice.id,
        archived: true,
      );

      final response = await project_detail_route.onRequest(
        contextFor(
          method: HttpMethod.patch,
          user: alice,
          body: {'archived': false},
        ),
        'p-alice',
      );

      expect(response.statusCode, HttpStatus.ok);
      final project = (await jsonOf(response))['project'] as Map;
      expect(project['archivedAt'], isNull);

      final listed = await projects_route.onRequest(
        contextFor(method: HttpMethod.get, user: alice),
      );
      expect((await jsonOf(listed))['projects'], hasLength(1));
    });

    test('keeps the report', () async {
      await repository.saveReport(
        DepReport(
          projectId: 'p-alice',
          generatedAt: DateTime.utc(2026, 1, 2),
          nodes: const [
            DepNode(name: 'http', kind: DepKind.direct, installed: '1.2.0'),
          ],
        ),
      );

      await project_detail_route.onRequest(
        contextFor(
          method: HttpMethod.patch,
          user: alice,
          body: {'archived': true},
        ),
        'p-alice',
      );

      expect(await repository.reportFor('p-alice'), isNotNull);
    });

    test('404s for a project owned by another user', () async {
      final response = await project_detail_route.onRequest(
        contextFor(
          method: HttpMethod.patch,
          user: bob,
          body: {'archived': true},
        ),
        'p-alice',
      );

      expect(response.statusCode, HttpStatus.notFound);
      // And Alice's project is untouched.
      expect(
        (await repository.byId('p-alice', ownerId: alice.id))!.isArchived,
        isFalse,
      );
    });

    test('rejects a body without an archived flag', () async {
      final response = await project_detail_route.onRequest(
        contextFor(
          method: HttpMethod.patch,
          user: alice,
          body: <String, dynamic>{},
        ),
        'p-alice',
      );

      expect(response.statusCode, HttpStatus.badRequest);
    });
  });

  group('deleting', () {
    setUp(() async {
      await repository.add(projectFor(alice, id: 'p-alice'));
      await repository.saveReport(
        DepReport(
          projectId: 'p-alice',
          generatedAt: DateTime.utc(2026, 1, 2),
          nodes: const [
            DepNode(name: 'http', kind: DepKind.direct, installed: '1.2.0'),
          ],
        ),
      );
    });

    test('removes the project and its report', () async {
      final response = await project_detail_route.onRequest(
        contextFor(method: HttpMethod.delete, user: alice),
        'p-alice',
      );

      expect(response.statusCode, HttpStatus.noContent);
      expect(await repository.byId('p-alice', ownerId: alice.id), isNull);
      expect(await repository.reportFor('p-alice'), isNull);
    });

    // The one that matters: a destructive verb must not act across owners, and
    // must not reveal that the id exists either.
    test('404s for a project owned by another user, and deletes nothing',
        () async {
      final response = await project_detail_route.onRequest(
        contextFor(method: HttpMethod.delete, user: bob),
        'p-alice',
      );

      expect(response.statusCode, HttpStatus.notFound);
      expect(await repository.byId('p-alice', ownerId: alice.id), isNotNull);
      expect(await repository.reportFor('p-alice'), isNotNull);
    });

    test('404s for an id that does not exist', () async {
      final response = await project_detail_route.onRequest(
        contextFor(method: HttpMethod.delete, user: alice),
        'does-not-exist',
      );

      expect(response.statusCode, HttpStatus.notFound);
    });
  });

  group('GET /projects/<id>', () {
    test('returns the project and its report', () async {
      await repository.add(projectFor(alice, id: 'p-alice'));
      await repository.saveReport(
        DepReport(
          projectId: 'p-alice',
          generatedAt: DateTime.utc(2026, 1, 2),
          nodes: const [
            DepNode(
              name: 'http',
              kind: DepKind.direct,
              installed: '1.2.0',
              latest: '1.3.0',
              status: DepStatus.outdated,
            ),
          ],
        ),
      );

      final response = await project_detail_route.onRequest(
        contextFor(method: HttpMethod.get, user: alice),
        'p-alice',
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = await jsonOf(response);
      expect((body['project'] as Map)['id'], 'p-alice');
      expect((body['report'] as Map)['nodes'], hasLength(1));
    });

    test('404s for an unknown id', () async {
      final response = await project_detail_route.onRequest(
        contextFor(method: HttpMethod.get, user: alice),
        'does-not-exist',
      );

      expect(response.statusCode, HttpStatus.notFound);
    });

    // Ownership leak check: Bob must not be able to read Alice's project, and
    // the response must not reveal that the id exists.
    test('404s (not 403) for a project owned by another user', () async {
      await repository.add(projectFor(alice, id: 'p-alice'));

      final response = await project_detail_route.onRequest(
        contextFor(method: HttpMethod.get, user: bob),
        'p-alice',
      );

      expect(response.statusCode, HttpStatus.notFound);
      final body = await jsonOf(response);
      expect(body['error'], 'project not found');
      expect(body.containsKey('project'), isFalse);
    });
  });
}
