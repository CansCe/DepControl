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

import '../../routes/projects/[id]/index.dart' as detail_route;
import '../../routes/projects/[id]/refresh.dart' as refresh_route;
import '../../routes/projects/[id]/remediation.dart' as remediation_route;
import '../../routes/projects/[id]/resolve.dart' as resolve_route;
import '../../routes/projects/[id]/upgrade/[package].dart' as upgrade_route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

void main() {
  late InMemoryProjectRepository repository;
  late FakeGitFetcher fetcher;
  late Deps deps;

  const alice = AuthUser(
    id: 'a0000000-0000-0000-0000-00000000000a',
    role: 'authenticated',
    email: 'alice@example.com',
  );

  _MockRequestContext contextFor({
    HttpMethod method = HttpMethod.get,
    Object? body,
  }) {
    final request = _MockRequest();
    when(() => request.method).thenReturn(method);
    when(() => request.uri).thenReturn(Uri.parse('http://localhost/projects'));
    when(request.json).thenAnswer((_) async => body);

    final context = _MockRequestContext();
    when(() => context.request).thenReturn(request);
    when(context.read<Deps>).thenReturn(deps);
    when(context.read<AuthUser>).thenReturn(alice);
    return context;
  }

  Future<Map<String, dynamic>> jsonOf(Response response) async =>
      jsonDecode(await response.body()) as Map<String, dynamic>;

  setUp(() async {
    repository = InMemoryProjectRepository();
    fetcher = FakeGitFetcher();
    deps = Deps.forTesting(
      repository: repository,
      gitFetcher: fetcher,
      analyzer: FakeAnalyzer(),
    );

    await repository.add(
      Project(
        id: 'p1',
        gitUrl: 'https://github.com/acme/demo.git',
        name: 'demo',
        ownerId: alice.id,
        addedAt: DateTime.utc(2026, 1, 1),
      ),
    );
    await repository.saveReport(
      DepReport(
        projectId: 'p1',
        generatedAt: DateTime.utc(2026, 1, 2),
        nodes: const [
          DepNode(
            name: 'yaml',
            kind: DepKind.direct,
            installed: '3.1.2',
            latest: '3.1.3',
            status: DepStatus.outdated,
            advisories: [DepAdvisory(id: 'GHSA-demo', fixedIn: '3.1.3')],
          ),
        ],
      ),
    );
    await repository.setArchived('p1', ownerId: alice.id, archived: true);
  });

  /// Archiving means "stop working on this", so nothing that reaches outward
  /// should still run for it.
  group('an archived project refuses', () {
    test('re-analysis', () async {
      final response = await refresh_route.onRequest(
        contextFor(method: HttpMethod.post),
        'p1',
      );

      expect(response.statusCode, HttpStatus.conflict);
      expect((await jsonOf(response))['error'], contains('archived'));
      // And nothing was fetched.
      expect(fetcher.calls, isEmpty);
    });

    test('simulating a change', () async {
      final response = await resolve_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          body: {'package': 'yaml', 'targetConstraint': '^3.1.3'},
        ),
        'p1',
      );

      expect(response.statusCode, HttpStatus.conflict);
      expect(fetcher.calls, isEmpty);
    });

    test('upgrade detail', () async {
      final response = await upgrade_route.onRequest(
        contextFor(),
        'p1',
        'yaml',
      );

      expect(response.statusCode, HttpStatus.conflict);
      expect(fetcher.calls, isEmpty);
    });

    test('planning remediations', () async {
      final response = await remediation_route.onRequest(contextFor(), 'p1');

      expect(response.statusCode, HttpStatus.conflict);
      expect(fetcher.calls, isEmpty);
    });

    test('and says restoring it is the way back', () async {
      final response = await remediation_route.onRequest(contextFor(), 'p1');
      expect((await jsonOf(response))['reason'], contains('Restore it'));
    });
  });

  group('an archived project still', () {
    test('serves its stored report', () async {
      final response = await detail_route.onRequest(contextFor(), 'p1');

      expect(response.statusCode, HttpStatus.ok);
      final body = await jsonOf(response);
      expect((body['report'] as Map)['nodes'], hasLength(1));
      expect((body['project'] as Map)['archivedAt'], isNotNull);
    });

    test('works again once restored', () async {
      await repository.setArchived('p1', ownerId: alice.id, archived: false);

      final response = await refresh_route.onRequest(
        contextFor(method: HttpMethod.post),
        'p1',
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(fetcher.calls, hasLength(1));
    });
  });
}
