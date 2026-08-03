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

  // Remediation resolves against pub.dev and edits a pubspec, so it covers Dart
  // and nothing else. What it used to do about that was reach for a
  // `pubspec.yaml` anyway — which for an npm repository is not there, so
  // `GitFetcher.fetch` threw and the route answered 500 for every advisory an
  // npm project has.
  group('a project this planner does not cover', () {
    const npmAdvisory = DepNode(
      name: 'lodash',
      ecosystem: 'npm',
      kind: DepKind.direct,
      installed: '4.17.20',
      constraint: '^4.17.0',
      status: DepStatus.vulnerable,
      advisories: [
        DepAdvisory(
          id: 'GHSA-npm-demo',
          severity: AdvisorySeverity.high,
          fixedIn: '4.17.21',
        ),
      ],
    );

    test('answers rather than failing', () async {
      await storeReport(const [npmAdvisory]);

      final response = await remediation_route.onRequest(
        contextFor(user: alice),
        'p-alice',
      );

      expect(response.statusCode, HttpStatus.ok);
    });

    // The whole point. Dropping the advisory would leave a report saying
    // "1 vulnerable" beside a panel offering nothing, which reads as "there is
    // no fix" — the one conclusion that is definitely wrong.
    test('reports the advisory as blocked, not as absent', () async {
      await storeReport(const [npmAdvisory]);

      final response = await remediation_route.onRequest(
        contextFor(user: alice),
        'p-alice',
      );

      final plan = RemediationPlan.fromJson(await jsonOf(response));
      expect(plan.remediations, hasLength(1));
      expect(plan.blocked.single.package, 'lodash');
      expect(
        plan.blocked.single.blocker,
        RemediationBlocker.unsupportedEcosystem,
      );
      expect(plan.blocked.single.advisoryIds, ['GHSA-npm-demo']);
      expect(plan.actionable, isEmpty);
    });

    test('does not go looking for a manifest that is not there', () async {
      await storeReport(const [npmAdvisory]);

      await remediation_route.onRequest(contextFor(user: alice), 'p-alice');

      expect(fetcher.calls, isEmpty);
    });

    // A repository holding both still gets its Dart fixes planned; only the
    // packages this planner cannot speak for come back blocked.
    test('still plans the Dart half of a mixed repository', () async {
      await storeReport(const [
        npmAdvisory,
        DepNode(
          name: 'http',
          kind: DepKind.direct,
          installed: '1.0.0',
          constraint: '^1.0.0',
          status: DepStatus.vulnerable,
          advisories: [
            DepAdvisory(
              id: 'GHSA-dart-demo',
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

      final plan = RemediationPlan.fromJson(await jsonOf(response));
      expect(plan.remediations, hasLength(2));
      expect(
        plan.remediations
            .firstWhere((r) => r.package == 'lodash')
            .blocker,
        RemediationBlocker.unsupportedEcosystem,
      );
      // The Dart one was actually planned, which means the manifest was read.
      expect(fetcher.calls, isNotEmpty);
    });
  });

  // The report says there are Dart packages and the repository has no pubspec:
  // a moved directory, a rewritten default branch, a report older than the
  // layout it describes. The reader needs to know their report is stale, and a
  // 500 does not tell them that.
  group('a repository whose manifest has gone', () {
    test('says the report is stale rather than throwing', () async {
      deps = Deps.forTesting(
        repository: repository,
        gitFetcher: FakeGitFetcher(
          onFetch: (gitUrl, ref) =>
              throw StateError('No pubspec.yaml found at $gitUrl ($ref).'),
        ),
        analyzer: FakeAnalyzer(),
      );

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

      expect(response.statusCode, HttpStatus.conflict);
      expect((await jsonOf(response))['error'], contains('Re-analyze'));
    });
  });
}
