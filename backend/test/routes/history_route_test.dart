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
import '../../routes/projects/[id]/history.dart' as history_route;

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
  const bob = AuthUser(
    id: 'b0000000-0000-0000-0000-00000000000b',
    role: 'authenticated',
    email: 'bob@example.com',
  );

  _MockRequestContext contextFor({
    required AuthUser user,
    HttpMethod method = HttpMethod.get,
    String uri = 'http://localhost/projects/p-alice/history',
  }) {
    final request = _MockRequest();
    when(() => request.method).thenReturn(method);
    when(() => request.uri).thenReturn(Uri.parse(uri));

    final context = _MockRequestContext();
    when(() => context.request).thenReturn(request);
    when(context.read<Deps>).thenReturn(deps);
    when(context.read<AuthUser>).thenReturn(user);
    return context;
  }

  Future<Map<String, dynamic>> jsonOf(Response response) async =>
      jsonDecode(await response.body()) as Map<String, dynamic>;

  Future<ReportRevision> store(String version, DateTime at) =>
      repository.saveReport(
        DepReport(
          projectId: 'p-alice',
          generatedAt: at,
          nodes: [
            DepNode(name: 'http', kind: DepKind.direct, installed: version),
          ],
        ),
      );

  setUp(() async {
    repository = InMemoryProjectRepository();
    deps = Deps.forTesting(
      repository: repository,
      gitFetcher: FakeGitFetcher(),
      analyzer: FakeAnalyzer(),
    );

    await repository.add(
      Project(
        id: 'p-alice',
        gitUrl: 'https://github.com/acme/demo.git',
        name: 'demo',
        ownerId: alice.id,
        addedAt: DateTime.utc(2026, 1, 1),
      ),
    );
  });

  group('GET /projects/<id>/history', () {
    test('lists the revisions newest first', () async {
      await store('1.0.0', DateTime.utc(2026, 1, 1));
      await store('2.0.0', DateTime.utc(2026, 2, 1));

      final response = await history_route.onRequest(
        contextFor(user: alice),
        'p-alice',
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = await jsonOf(response);
      final revisions = body['revisions'] as List;
      expect(revisions, hasLength(2));
      expect(revisions.first['firstSeenAt'], startsWith('2026-02-01'));
    });

    test('a project scanned twice with no change has one revision', () async {
      await store('1.0.0', DateTime.utc(2026, 1, 1));
      await store('1.0.0', DateTime.utc(2026, 2, 1));

      final body = await jsonOf(
        await history_route.onRequest(contextFor(user: alice), 'p-alice'),
      );

      final revisions = body['revisions'] as List;
      expect(revisions, hasLength(1));
      expect(revisions.single['firstSeenAt'], startsWith('2026-01-01'));
      expect(revisions.single['lastSeenAt'], startsWith('2026-02-01'));
    });

    test('a project with no report yet has an empty history', () async {
      final body = await jsonOf(
        await history_route.onRequest(contextFor(user: alice), 'p-alice'),
      );

      expect(body['revisions'], isEmpty);
    });

    test('?revision returns that revision in full', () async {
      final first = await store('1.0.0', DateTime.utc(2026, 1, 1));
      await store('2.0.0', DateTime.utc(2026, 2, 1));

      final body = await jsonOf(
        await history_route.onRequest(
          contextFor(
            user: alice,
            uri: 'http://localhost/projects/p-alice/history'
                '?revision=${first.id}',
          ),
          'p-alice',
        ),
      );

      final nodes = body['nodes'] as List;
      expect(nodes.single['installed'], '1.0.0');
    });

    test('an unknown revision is a 404', () async {
      await store('1.0.0', DateTime.utc(2026, 1, 1));

      final response = await history_route.onRequest(
        contextFor(
          user: alice,
          uri: 'http://localhost/projects/p-alice/history?revision=nope',
        ),
        'p-alice',
      );

      expect(response.statusCode, HttpStatus.notFound);
    });

    test('another owner gets a 404, not a 403', () async {
      // A 403 would confirm the project exists.
      await store('1.0.0', DateTime.utc(2026, 1, 1));

      final response = await history_route.onRequest(
        contextFor(user: bob),
        'p-alice',
      );

      expect(response.statusCode, HttpStatus.notFound);
    });

    test('a revision id cannot be read through another project', () async {
      final revision = await store('1.0.0', DateTime.utc(2026, 1, 1));
      await repository.add(
        Project(
          id: 'p-alice-2',
          gitUrl: 'https://github.com/acme/other.git',
          name: 'other',
          ownerId: alice.id,
          addedAt: DateTime.utc(2026, 1, 1),
        ),
      );

      final response = await history_route.onRequest(
        contextFor(
          user: alice,
          uri: 'http://localhost/projects/p-alice-2/history'
              '?revision=${revision.id}',
        ),
        'p-alice-2',
      );

      expect(response.statusCode, HttpStatus.notFound);
    });

    test('limit is clamped rather than rejected', () async {
      for (var i = 0; i < 4; i++) {
        await store('1.0.$i', DateTime.utc(2026, 1, i + 1));
      }

      Future<int> countWith(String query) async {
        final body = await jsonOf(
          await history_route.onRequest(
            contextFor(
              user: alice,
              uri: 'http://localhost/projects/p-alice/history?$query',
            ),
            'p-alice',
          ),
        );
        return (body['revisions'] as List).length;
      }

      expect(await countWith('limit=2'), 2);
      // Garbled and out-of-range values fall back rather than deciding the
      // size of a query.
      expect(await countWith('limit=banana'), 4);
      expect(await countWith('limit=-1'), 4);
      expect(await countWith('limit=100000'), 4);
    });

    test('rejects anything but GET', () async {
      final response = await history_route.onRequest(
        contextFor(user: alice, method: HttpMethod.post),
        'p-alice',
      );

      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });
}
