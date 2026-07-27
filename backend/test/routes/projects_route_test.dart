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
  }) {
    final request = _MockRequest();
    when(() => request.method).thenReturn(method);
    when(request.json).thenAnswer((_) async => body);

    final context = _MockRequestContext();
    when(() => context.request).thenReturn(request);
    when(context.read<Deps>).thenReturn(deps);
    when(context.read<AuthUser>).thenReturn(user);
    return context;
  }

  Future<Map<String, dynamic>> jsonOf(Response response) async =>
      jsonDecode(await response.body()) as Map<String, dynamic>;

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
    test('creates a project owned by the caller', () async {
      final response = await projects_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          user: alice,
          body: {'gitUrl': 'https://github.com/acme/widget.git'},
        ),
      );

      expect(response.statusCode, HttpStatus.created);
      final body = await jsonOf(response);
      final project = body['project'] as Map<String, dynamic>;

      expect(project['ownerId'], alice.id);
      expect(project['gitUrl'], 'https://github.com/acme/widget.git');
      expect(project['name'], 'widget');
      expect(project['ref'], 'HEAD');
      expect(body['report'], isNotNull);

      // and it is actually persisted against that owner
      expect(await repository.allForOwner(alice.id), hasLength(1));
      expect(await repository.allForOwner(bob.id), isEmpty);
    });

    test('honours an explicit ref', () async {
      final response = await projects_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          user: alice,
          body: {
            'gitUrl': 'https://github.com/acme/widget.git',
            'ref': 'develop',
          },
        ),
      );

      final project =
          (await jsonOf(response))['project'] as Map<String, dynamic>;
      expect(project['ref'], 'develop');
    });

    test('rejects a missing gitUrl with 400', () async {
      final response = await projects_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          user: alice,
          body: <String, dynamic>{},
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
          body: {'gitUrl': ''},
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
    });

    test('reports an unreachable repo as 400, not 500', () async {
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
          body: {'gitUrl': 'https://github.com/acme/missing.git'},
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect((await jsonOf(response))['error'], 'repository not found');
    });
  });

  group('unsupported methods', () {
    test('DELETE /projects is 405', () async {
      final response = await projects_route.onRequest(
        contextFor(method: HttpMethod.delete, user: alice),
      );
      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });

    test('DELETE /projects/<id> is 405', () async {
      final response = await project_detail_route.onRequest(
        contextFor(method: HttpMethod.delete, user: alice),
        'p1',
      );
      expect(response.statusCode, HttpStatus.methodNotAllowed);
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
