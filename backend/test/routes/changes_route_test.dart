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
import '../../routes/projects/[id]/changes.dart' as changes_route;

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
    String query = '',
  }) {
    final request = _MockRequest();
    when(() => request.method).thenReturn(method);
    when(() => request.uri).thenReturn(
      Uri.parse('http://localhost/projects/p-alice/changes$query'),
    );

    final context = _MockRequestContext();
    when(() => context.request).thenReturn(request);
    when(context.read<Deps>).thenReturn(deps);
    when(context.read<AuthUser>).thenReturn(user);
    return context;
  }

  Future<Map<String, dynamic>> jsonOf(Response response) async =>
      jsonDecode(await response.body()) as Map<String, dynamic>;

  Future<ReportRevision> store(
    List<DepNode> nodes,
    DateTime at,
  ) =>
      repository.saveReport(
        DepReport(projectId: 'p-alice', generatedAt: at, nodes: nodes),
      );

  DepNode node(
    String name, {
    String version = '1.0.0',
    List<DepAdvisory> advisories = const [],
  }) =>
      DepNode(
        name: name,
        kind: DepKind.direct,
        installed: version,
        advisories: advisories,
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

  group('GET /projects/<id>/changes', () {
    test('compares the two newest revisions by default', () async {
      await store([node('http', version: '1.0.0')], DateTime.utc(2026, 1, 1));
      await store([node('http', version: '2.0.0')], DateTime.utc(2026, 2, 1));

      final body = await jsonOf(
        await changes_route.onRequest(contextFor(user: alice), 'p-alice'),
      );

      final packages = body['packages'] as List;
      expect(packages, hasLength(1));
      expect(packages.single['name'], 'http');
      expect(packages.single['fromVersion'], '1.0.0');
      expect(packages.single['toVersion'], '2.0.0');
      expect(packages.single['bump'], 'breaking');
      expect((body['summary'] as Map)['breaking'], 1);
    });

    test('a new advisory shows up in the summary', () async {
      await store([node('http')], DateTime.utc(2026, 1, 1));
      await store(
        [
          node('http', advisories: const [
            DepAdvisory(id: 'GHSA-x', severity: AdvisorySeverity.high),
          ]),
        ],
        DateTime.utc(2026, 2, 1),
      );

      final summary = (await jsonOf(
        await changes_route.onRequest(contextFor(user: alice), 'p-alice'),
      ))['summary'] as Map<String, dynamic>;

      expect(summary['newlyVulnerable'], 1);
      expect(summary['worstNewSeverity'], 'high');
    });

    test('a project with one revision says so rather than erroring', () async {
      // Scanned once, or scanned repeatedly and never changed. "Nothing has
      // changed yet" is a real answer; a 404 would read as "unknown project".
      await store([node('http')], DateTime.utc(2026, 1, 1));

      final response =
          await changes_route.onRequest(contextFor(user: alice), 'p-alice');
      final body = await jsonOf(response);

      expect(response.statusCode, HttpStatus.ok);
      expect(body['packages'], isEmpty);
      expect(body['note'], contains('Only one revision'));
    });

    test('a project with no report at all says that instead', () async {
      final body = await jsonOf(
        await changes_route.onRequest(contextFor(user: alice), 'p-alice'),
      );

      expect(body['packages'], isEmpty);
      expect(body['note'], contains('No report'));
    });

    test('two named revisions are compared in the order given', () async {
      final first =
          await store([node('http', version: '1.0.0')], DateTime.utc(2026, 1, 1));
      final second =
          await store([node('http', version: '2.0.0')], DateTime.utc(2026, 2, 1));

      final forwards = await jsonOf(
        await changes_route.onRequest(
          contextFor(user: alice, query: '?from=${first.id}&to=${second.id}'),
          'p-alice',
        ),
      );
      expect((forwards['packages'] as List).single['toVersion'], '2.0.0');

      // Backwards is a legitimate question — "what would reverting look like".
      final backwards = await jsonOf(
        await changes_route.onRequest(
          contextFor(user: alice, query: '?from=${second.id}&to=${first.id}'),
          'p-alice',
        ),
      );
      final change = (backwards['packages'] as List).single;
      expect(change['toVersion'], '1.0.0');
      expect(change['isDowngrade'], isTrue);
    });

    test('one of from/to alone is a bad request, not a guess', () async {
      final first =
          await store([node('http')], DateTime.utc(2026, 1, 1));
      await store([node('http', version: '2.0.0')], DateTime.utc(2026, 2, 1));

      final response = await changes_route.onRequest(
        contextFor(user: alice, query: '?from=${first.id}'),
        'p-alice',
      );

      expect(response.statusCode, HttpStatus.badRequest);
    });

    test('an unknown revision is a 404', () async {
      await store([node('http')], DateTime.utc(2026, 1, 1));

      final response = await changes_route.onRequest(
        contextFor(user: alice, query: '?from=nope&to=alsonope'),
        'p-alice',
      );

      expect(response.statusCode, HttpStatus.notFound);
    });

    test('another owner gets a 404, not a 403', () async {
      await store([node('http')], DateTime.utc(2026, 1, 1));

      final response =
          await changes_route.onRequest(contextFor(user: bob), 'p-alice');

      expect(response.statusCode, HttpStatus.notFound);
    });

    test('rejects anything but GET', () async {
      final response = await changes_route.onRequest(
        contextFor(user: alice, method: HttpMethod.post),
        'p-alice',
      );

      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });
}
