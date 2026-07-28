import 'dart:convert';
import 'dart:io';

import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:backend/src/repository/license_policy_store.dart';
import 'package:backend/src/repository/project_repository.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import '../support/fakes.dart';

// Route handlers live outside lib/, so they're imported by path.
import '../../routes/policy/licenses.dart' as policy_route;
import '../../routes/projects/[id]/licenses.dart' as licenses_route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

void main() {
  late InMemoryProjectRepository repository;
  late InMemoryLicensePolicyStore policies;
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
    String uri = 'http://localhost/projects/p-alice/licenses',
    Object? body,
  }) {
    final request = _MockRequest();
    when(() => request.method).thenReturn(method);
    when(() => request.uri).thenReturn(Uri.parse(uri));
    when(request.json).thenAnswer(
      (_) async => body ?? (throw const FormatException('no body')),
    );

    final context = _MockRequestContext();
    when(() => context.request).thenReturn(request);
    when(context.read<Deps>).thenReturn(deps);
    when(context.read<AuthUser>).thenReturn(user);
    return context;
  }

  Future<Map<String, dynamic>> jsonOf(Response response) async =>
      jsonDecode(await response.body()) as Map<String, dynamic>;

  PackageLicense license(String? spdxId, LicenseCategory category) =>
      PackageLicense(
        spdxId: spdxId,
        category: category,
        source: LicenseSource.installedVersion,
      );

  Future<void> storeReport(List<DepNode> nodes) => repository.saveReport(
        DepReport(
          projectId: 'p-alice',
          generatedAt: DateTime.utc(2026, 7, 28),
          nodes: nodes,
        ),
      );

  setUp(() async {
    repository = InMemoryProjectRepository();
    policies = InMemoryLicensePolicyStore();
    deps = Deps.forTesting(
      repository: repository,
      licensePolicies: policies,
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

  group('GET /projects/<id>/licenses', () {
    test('judges the stored report against the standard policy', () async {
      await storeReport([
        DepNode(
          name: 'http',
          kind: DepKind.direct,
          installed: '1.2.0',
          license: license('MIT', LicenseCategory.permissive),
        ),
        DepNode(
          name: 'copyleft_pkg',
          kind: DepKind.direct,
          installed: '2.0.0',
          license: license('AGPL-3.0-only', LicenseCategory.networkCopyleft),
        ),
      ]);

      final response = await licenses_route.onRequest(
        contextFor(user: alice),
        'p-alice',
      );
      expect(response.statusCode, HttpStatus.ok);

      final body = await jsonOf(response);
      final report = LicenseReport.fromJson(
        body['report'] as Map<String, dynamic>,
      );

      expect(report.findings, hasLength(2));
      expect(report.forbidden.single.package, 'copyleft_pkg');
      // Nobody has written a policy, so the reader is looking at the default.
      expect(body['policyIsCustom'], isFalse);
    });

    test("applies the caller's own policy", () async {
      await policies.save(
        alice.id,
        const LicensePolicy(
          categories: {LicenseCategory.networkCopyleft: LicenseRule.allowed},
        ),
      );
      await storeReport([
        DepNode(
          name: 'copyleft_pkg',
          kind: DepKind.direct,
          installed: '2.0.0',
          license: license('AGPL-3.0-only', LicenseCategory.networkCopyleft),
        ),
      ]);

      final body = await jsonOf(
        await licenses_route.onRequest(contextFor(user: alice), 'p-alice'),
      );

      expect(body['policyIsCustom'], isTrue);
      final report =
          LicenseReport.fromJson(body['report'] as Map<String, dynamic>);
      expect(report.findings.single.rule, LicenseRule.allowed);
    });

    test('serves a CSV manifest on request', () async {
      await storeReport([
        DepNode(
          name: 'http',
          kind: DepKind.direct,
          installed: '1.2.0',
          license: license('MIT', LicenseCategory.permissive),
        ),
      ]);

      final response = await licenses_route.onRequest(
        contextFor(
          user: alice,
          uri: 'http://localhost/projects/p-alice/licenses?format=csv',
        ),
        'p-alice',
      );

      expect(response.headers['Content-Type'], startsWith('text/csv'));
      expect(
        response.headers['Content-Disposition'],
        contains('demo-licenses-'),
      );
      final csv = await response.body();
      expect(csv, startsWith('package,version,license'));
      expect(csv, contains('http,1.2.0,MIT'));
    });

    // A license is a fact about the versions in the snapshot, the same way an
    // advisory is — not a comparison with pub.dev as it is today. Nothing here
    // reaches outward, so there is nothing for archiving to refuse.
    test('still answers for an archived project', () async {
      await storeReport([
        DepNode(
          name: 'http',
          kind: DepKind.direct,
          installed: '1.2.0',
          license: license('MIT', LicenseCategory.permissive),
        ),
      ]);
      await repository.setArchived(
        'p-alice',
        ownerId: alice.id,
        archived: true,
      );

      final response = await licenses_route.onRequest(
        contextFor(user: alice),
        'p-alice',
      );
      expect(response.statusCode, HttpStatus.ok);
    });

    test("reports another user's project as missing", () async {
      await storeReport([]);

      final response = await licenses_route.onRequest(
        contextFor(user: bob),
        'p-alice',
      );
      expect(response.statusCode, HttpStatus.notFound);
    });

    test('says so when the project has no report yet', () async {
      final response = await licenses_route.onRequest(
        contextFor(user: alice),
        'p-alice',
      );
      expect(response.statusCode, HttpStatus.notFound);
      expect((await jsonOf(response))['error'], contains('no report'));
    });

    test('refuses a write', () async {
      final response = await licenses_route.onRequest(
        contextFor(user: alice, method: HttpMethod.post),
        'p-alice',
      );
      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });

  group('/policy/licenses', () {
    test('serves the standard policy before anyone writes one', () async {
      final body = await jsonOf(
        await policy_route.onRequest(
          contextFor(user: alice, uri: 'http://localhost/policy/licenses'),
        ),
      );

      expect(body['isCustom'], isFalse);
      expect(body['policy'], LicensePolicy.standard.toJson());
      expect(body['standard'], LicensePolicy.standard.toJson());
    });

    test('stores a policy and reads it back', () async {
      const policy = LicensePolicy(
        categories: {LicenseCategory.weakCopyleft: LicenseRule.allowed},
        licenses: {'SSPL-1.0': LicenseRule.allowed},
        checkDevDependencies: true,
      );

      final put = await policy_route.onRequest(
        contextFor(
          user: alice,
          method: HttpMethod.put,
          uri: 'http://localhost/policy/licenses',
          body: policy.toJson(),
        ),
      );
      expect(put.statusCode, HttpStatus.ok);
      expect((await jsonOf(put))['isCustom'], isTrue);

      final stored = await policies.forOwner(alice.id);
      expect(stored.isCustom, isTrue);
      expect(stored.policy.licenses, {'SSPL-1.0': LicenseRule.allowed});
      expect(stored.policy.checkDevDependencies, isTrue);
    });

    test('keeps one user out of another\'s policy', () async {
      await policy_route.onRequest(
        contextFor(
          user: alice,
          method: HttpMethod.put,
          uri: 'http://localhost/policy/licenses',
          body: const LicensePolicy(
            categories: {LicenseCategory.strongCopyleft: LicenseRule.allowed},
          ).toJson(),
        ),
      );

      final forBob = await policies.forOwner(bob.id);
      expect(forBob.isCustom, isFalse);
      expect(forBob.policy.categories, LicensePolicy.standard.categories);
    });

    test('rejects a body that is not a policy', () async {
      final response = await policy_route.onRequest(
        contextFor(
          user: alice,
          method: HttpMethod.put,
          uri: 'http://localhost/policy/licenses',
        ),
      );
      expect(response.statusCode, HttpStatus.badRequest);
    });

    test('drops a policy back to the standard one', () async {
      await policies.save(
        alice.id,
        const LicensePolicy(licenses: {'MIT': LicenseRule.forbidden}),
      );

      final response = await policy_route.onRequest(
        contextFor(
          user: alice,
          method: HttpMethod.delete,
          uri: 'http://localhost/policy/licenses',
        ),
      );

      expect((await jsonOf(response))['isCustom'], isFalse);
      expect((await policies.forOwner(alice.id)).isCustom, isFalse);
    });
  });
}
