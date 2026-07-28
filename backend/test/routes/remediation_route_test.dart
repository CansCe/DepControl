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
import '../../routes/projects/[id]/remediation.dart' as remediation_route;

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
  const bob = AuthUser(
    id: 'b0000000-0000-0000-0000-00000000000b',
    role: 'authenticated',
    email: 'bob@example.com',
  );

  _MockRequestContext contextFor({
    required AuthUser user,
    HttpMethod method = HttpMethod.get,
  }) {
    final request = _MockRequest();
    when(() => request.method).thenReturn(method);

    final context = _MockRequestContext();
    when(() => context.request).thenReturn(request);
    when(context.read<Deps>).thenReturn(deps);
    when(context.read<AuthUser>).thenReturn(user);
    return context;
  }

  Future<Map<String, dynamic>> jsonOf(Response response) async =>
      jsonDecode(await response.body()) as Map<String, dynamic>;

  Future<void> storeReport(List<DepNode> nodes) => repository.saveReport(
        DepReport(
          projectId: 'p-alice',
          generatedAt: DateTime.utc(2026, 1, 2),
          nodes: nodes,
        ),
      );

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
        id: 'p-alice',
        gitUrl: 'https://github.com/acme/demo.git',
        name: 'demo',
        ownerId: alice.id,
        addedAt: DateTime.utc(2026, 1, 1),
      ),
    );
  });

  group('a clean report', () {
    test('returns an empty plan without fetching anything', () async {
      await storeReport(const [
        DepNode(name: 'http', kind: DepKind.direct, installed: '1.2.0'),
      ]);

      final response = await remediation_route.onRequest(
        contextFor(user: alice),
        'p-alice',
      );

      expect(response.statusCode, HttpStatus.ok);
      final plan = RemediationPlan.fromJson(await jsonOf(response));
      expect(plan.remediations, isEmpty);
      // No advisories means no reason to touch the network.
      expect(fetcher.calls, isEmpty);
    });
  });

  group('a report with advisories', () {
    test('plans against the repository as it stands now', () async {
      await storeReport(const [
        DepNode(
          name: 'http',
          kind: DepKind.direct,
          installed: '1.0.0',
          constraint: '^1.0.0',
          status: DepStatus.vulnerable,
          advisories: [
            DepAdvisory(
              id: 'GHSA-demo',
              severity: AdvisorySeverity.high,
              fixedIn: '1.2.0',
            ),
          ],
        ),
      ]);

      final response = await remediation_route.onRequest(
        contextFor(user: alice),
        'p-alice',
      );

      expect(response.statusCode, HttpStatus.ok);
      final plan = RemediationPlan.fromJson(await jsonOf(response));
      expect(plan.projectId, 'p-alice');
      expect(plan.remediations, hasLength(1));
      expect(plan.remediations.single.package, 'http');
      expect(plan.worstSeverity, AdvisorySeverity.high);
      // It re-fetched, because a fix has to work against the current pubspec.
      expect(fetcher.calls, hasLength(1));
    });
  });

  group('access', () {
    test('404s for a project owned by another user', () async {
      final response = await remediation_route.onRequest(
        contextFor(user: bob),
        'p-alice',
      );

      expect(response.statusCode, HttpStatus.notFound);
    });

    test('404s when no report has been generated yet', () async {
      final response = await remediation_route.onRequest(
        contextFor(user: alice),
        'p-alice',
      );

      expect(response.statusCode, HttpStatus.notFound);
      expect((await jsonOf(response))['error'], contains('no report'));
    });

    test('POST is rejected with 405', () async {
      final response = await remediation_route.onRequest(
        contextFor(user: alice, method: HttpMethod.post),
        'p-alice',
      );

      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });
}
