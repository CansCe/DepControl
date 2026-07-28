import 'dart:convert';
import 'dart:io';

import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:backend/src/repository/api_diff_store.dart';
import 'package:backend/src/repository/project_repository.dart';
import 'package:backend/src/services/upgrade_inspector.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import '../support/fakes.dart';

// Route handlers live outside lib/, so they're imported by path.
import '../../routes/projects/[id]/upgrade/[package].dart' as upgrade_route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

/// An [UpgradeInspector] that answers from a canned impact instead of pub.dev.
class _FakeInspector implements UpgradeInspector {
  _FakeInspector({this.impact});

  final UpgradeImpact? impact;

  @override
  Future<UpgradeImpact?> inspect(
    String package, {
    required String from,
    String? to,
    String? projectSdk,
  }) async =>
      impact;
}

void main() {
  late InMemoryProjectRepository repository;
  late InMemoryApiDiffStore apiDiffs;
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

  const impact = UpgradeImpact(
    package: 'yaml',
    from: '3.1.2',
    to: '3.1.3',
    releasesBetween: 1,
  );

  const storedDiff = ApiDiff(
    package: 'yaml',
    from: '3.1.2',
    to: '3.1.3',
    changes: [
      ApiChange(
        kind: ApiChangeKind.removed,
        declaration: 'class Pair',
        before: 'Pair',
      ),
    ],
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

  /// Builds the graph with an inspector that reports [result].
  void wire({UpgradeImpact? result = impact}) {
    deps = Deps.forTesting(
      repository: repository,
      apiDiffs: apiDiffs,
      gitFetcher: FakeGitFetcher(),
      analyzer: FakeAnalyzer(),
      inspector: _FakeInspector(impact: result),
    );
  }

  setUp(() async {
    repository = InMemoryProjectRepository();
    apiDiffs = InMemoryApiDiffStore();
    wire();

    await repository.add(
      Project(
        id: 'p-alice',
        gitUrl: 'https://github.com/acme/demo.git',
        name: 'demo',
        ownerId: alice.id,
        addedAt: DateTime.utc(2026, 1, 1),
      ),
    );
    await repository.saveReport(
      DepReport(
        projectId: 'p-alice',
        generatedAt: DateTime.utc(2026, 1, 2),
        nodes: const [
          DepNode(
            name: 'yaml',
            kind: DepKind.direct,
            installed: '3.1.2',
            latest: '3.1.3',
            status: DepStatus.outdated,
          ),
        ],
      ),
    );
  });

  group('the API diff', () {
    test('is returned when one has been computed for the pair', () async {
      await apiDiffs.save(storedDiff);

      final response = await upgrade_route.onRequest(
        contextFor(user: alice),
        'p-alice',
        'yaml',
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = await jsonOf(response);
      expect(body['impact'], isNotNull);

      final diff = body['apiDiff'] as Map<String, dynamic>;
      expect(diff['package'], 'yaml');
      expect(diff['from'], '3.1.2');
      expect(diff['to'], '3.1.3');
      expect((diff['changes'] as List).single, {
        'kind': 'removed',
        'declaration': 'class Pair',
        'before': 'Pair',
        'after': null,
      });
    });

    // Absent means "nobody has computed this", not "the API is unchanged", so
    // the response must not conflate the two.
    test('is null when nothing has computed the pair', () async {
      final response = await upgrade_route.onRequest(
        contextFor(user: alice),
        'p-alice',
        'yaml',
      );

      final body = await jsonOf(response);
      expect(body['impact'], isNotNull);
      expect(body['apiDiff'], isNull);
    });

    test('a miss records the pair as wanted', () async {
      await upgrade_route.onRequest(
        contextFor(user: alice),
        'p-alice',
        'yaml',
      );

      final pending = await apiDiffs.pendingRequests();
      expect(pending, hasLength(1));
      expect(pending.single.package, 'yaml');
      expect(pending.single.from, '3.1.2');
      expect(pending.single.to, '3.1.3');
    });

    test('a hit records nothing', () async {
      await apiDiffs.save(storedDiff);

      await upgrade_route.onRequest(
        contextFor(user: alice),
        'p-alice',
        'yaml',
      );

      expect(await apiDiffs.pendingRequests(), isEmpty);
    });

    // The diff is keyed on the versions the inspector settled on, not on
    // whatever else is stored for the package.
    test('a diff for other versions is not served in its place', () async {
      await apiDiffs.save(
        const ApiDiff(package: 'yaml', from: '3.0.0', to: '3.1.3'),
      );

      final response = await upgrade_route.onRequest(
        contextFor(user: alice),
        'p-alice',
        'yaml',
      );

      expect((await jsonOf(response))['apiDiff'], isNull);
    });
  });

  group('nothing to compare', () {
    test('reports both fields as null with a reason', () async {
      wire(result: null);

      final response = await upgrade_route.onRequest(
        contextFor(user: alice),
        'p-alice',
        'yaml',
      );

      final body = await jsonOf(response);
      expect(body['impact'], isNull);
      expect(body['apiDiff'], isNull);
      expect(body['reason'], isNotNull);
    });

    test('records no request, since there are no versions to compare',
        () async {
      wire(result: null);

      await upgrade_route.onRequest(
        contextFor(user: alice),
        'p-alice',
        'yaml',
      );

      expect(await apiDiffs.pendingRequests(), isEmpty);
    });
  });

  group('access', () {
    test('404s for a project owned by another user', () async {
      final response = await upgrade_route.onRequest(
        contextFor(user: bob),
        'p-alice',
        'yaml',
      );

      expect(response.statusCode, HttpStatus.notFound);
    });

    test('404s for a package that is not in the report', () async {
      final response = await upgrade_route.onRequest(
        contextFor(user: alice),
        'p-alice',
        'not-a-dependency',
      );

      expect(response.statusCode, HttpStatus.notFound);
    });

    test('POST is rejected with 405', () async {
      final response = await upgrade_route.onRequest(
        contextFor(user: alice, method: HttpMethod.post),
        'p-alice',
        'yaml',
      );

      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });
}
