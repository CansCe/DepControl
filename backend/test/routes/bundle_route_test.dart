import 'dart:convert';
import 'dart:io';

import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:backend/src/repository/project_repository.dart';
import 'package:backend/src/services/bundle_ingest.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import '../support/fakes.dart';

import '../../routes/projects/index.dart' as projects_route;
import '../../routes/projects/[id]/bundle.dart' as bundle_route;
import '../../routes/projects/[id]/refresh.dart' as refresh_route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

/// A bundle as `depcontrol collect` writes one, small enough to read.
Map<String, dynamic> bundleJson({
  bool redacted = false,
  int withheld = 0,
  String? rootPackageName = 'payroll_app',
  DateTime? generatedAt,
}) =>
    CollectedBundle(
      generatedAt: generatedAt ?? DateTime.utc(2026, 8, 1, 9),
      rootPackageName: rootPackageName,
      pathsRedacted: redacted,
      privatePackagesWithheld: withheld,
      manifests: const [
        CollectedManifest(
          directory: '',
          fileName: 'pubspec.yaml',
          ecosystem: 'dart',
          packageName: 'payroll_app',
          dependencies: [
            CollectedDependency(name: 'http', constraint: '^1.2.0'),
            CollectedDependency(
              name: 'acme_secrets',
              constraint: '^2.0.0',
              origin: 'a private registry',
            ),
          ],
          locked: [CollectedPackage(name: 'http', version: '1.2.2')],
          importedPackages: ['http'],
        ),
      ],
    ).toJson();

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
    required AuthUser user,
    Object? body,
    Map<String, String> headers = const {},
    String path = '/projects',
  }) {
    final request = _MockRequest();
    when(() => request.method).thenReturn(method);
    when(() => request.uri).thenReturn(Uri.parse('http://localhost$path'));
    when(request.json).thenAnswer((_) async => body);
    when(() => request.headers).thenReturn(headers);

    final context = _MockRequestContext();
    when(() => context.request).thenReturn(request);
    when(context.read<Deps>).thenReturn(deps);
    when(context.read<AuthUser>).thenReturn(user);
    return context;
  }

  Future<Map<String, dynamic>> jsonOf(Response response) async =>
      jsonDecode(await response.body()) as Map<String, dynamic>;

  /// Drains the queue the way the worker does, never through a request.
  Future<void> runQueuedScans() => deps.scanRunner.drain();

  setUp(() {
    repository = InMemoryProjectRepository();
    deps = Deps.forTesting(
      repository: repository,
      gitFetcher: FakeGitFetcher(),
      analyzer: FakeAnalyzer(),
    );
  });

  group('POST /projects with a bundle', () {
    test('is accepted and creates nothing until the worker runs', () async {
      final response = await projects_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          user: alice,
          body: {'bundle': bundleJson(), 'scanId': 'scan-1'},
        ),
      );

      expect(response.statusCode, HttpStatus.accepted);
      expect(await repository.allForOwner(alice.id), isEmpty);
    });

    test('the queued scan creates a local project with no git URL', () async {
      await projects_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          user: alice,
          body: {'bundle': bundleJson(), 'scanId': 'scan-1'},
        ),
      );
      await runQueuedScans();

      final project = (await repository.allForOwner(alice.id)).single;
      expect(project.source, ProjectSource.local);
      expect(project.isLocal, isTrue);
      // The one thing about a private repository that would let a hosted
      // service try to reach it. There is none, and there is not meant to be.
      expect(project.gitUrl, isNull);
      expect(project.name, 'payroll_app');
      expect(project.bundleCollectedAt, DateTime.utc(2026, 8, 1, 9));
      expect(await repository.reportFor(project.id), isNotNull);
    });

    test('a redacted bundle still names the project something', () async {
      // `--redact-paths` withholds the package name too, and a project with no
      // name at all is one nobody can find in a list.
      await projects_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          user: alice,
          body: {
            'bundle': bundleJson(redacted: true, rootPackageName: null),
            'scanId': 'scan-1',
          },
        ),
      );
      await runQueuedScans();

      final project = (await repository.allForOwner(alice.id)).single;
      expect(project.name, isNotEmpty);
      expect(project.isLocal, isTrue);
    });

    test('the disclosure flags reach the report as its coverage note', () async {
      // The failure worth catching is the half-implemented one: redaction
      // applied and withholding done, with the report saying neither and
      // claiming a completeness it does not have.
      await projects_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          user: alice,
          body: {
            'bundle': bundleJson(redacted: true, withheld: 3),
            'scanId': 'scan-1',
          },
        ),
      );
      await runQueuedScans();

      final project = (await repository.allForOwner(alice.id)).single;
      final note = (await repository.reportFor(project.id))!.coverageNote;

      expect(note, contains('--redact-paths'));
      expect(note, contains('3 package references were withheld'));
    });

    test('an ordinary bundle has nothing to disclose', () async {
      await projects_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          user: alice,
          body: {'bundle': bundleJson(), 'scanId': 'scan-1'},
        ),
      );
      await runQueuedScans();

      final project = (await repository.allForOwner(alice.id)).single;
      expect((await repository.reportFor(project.id))!.coverageNote, isNull);
    });

    test('neither gitUrl nor bundle is a 400 that says what to do', () async {
      final response = await projects_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          user: alice,
          body: {'scanId': 'scan-1'},
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect((await jsonOf(response))['error'], contains('depcontrol collect'));
    });

    test('both gitUrl and bundle is refused rather than guessed', () async {
      final response = await projects_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          user: alice,
          body: {
            'gitUrl': 'https://github.com/acme/widget.git',
            'bundle': bundleJson(),
            'scanId': 'scan-1',
          },
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(await repository.allForOwner(alice.id), isEmpty);
    });

    test('a bundle that is not an object is a 400, not a 500', () async {
      final response = await projects_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          user: alice,
          body: {'bundle': 'not a bundle', 'scanId': 'scan-1'},
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
    });

    test('an oversized upload is refused before the body is read', () async {
      final response = await projects_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          user: alice,
          body: {'bundle': bundleJson(), 'scanId': 'scan-1'},
          headers: {
            HttpHeaders.contentLengthHeader: '${BundleIngest.maxBytes + 1}',
          },
        ),
      );

      expect(response.statusCode, HttpStatus.requestEntityTooLarge);
    });
  });

  group('POST /projects/<id>/bundle', () {
    Future<Project> localProject() async {
      await projects_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          user: alice,
          body: {'bundle': bundleJson(), 'scanId': 'first'},
        ),
      );
      await runQueuedScans();
      return (await repository.allForOwner(alice.id)).single;
    }

    test('re-uploading updates the project in place', () async {
      final project = await localProject();

      final response = await bundle_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          user: alice,
          body: {
            'bundle': bundleJson(generatedAt: DateTime.utc(2026, 8, 4, 17)),
            'scanId': 'second',
          },
        ),
        project.id,
      );
      await runQueuedScans();

      expect(response.statusCode, HttpStatus.accepted);
      // One project, not two: uploading the same repository through
      // `POST /projects` again would split its history down the middle.
      final projects = await repository.allForOwner(alice.id);
      expect(projects, hasLength(1));
      expect(projects.single.id, project.id);
      expect(
        projects.single.bundleCollectedAt,
        DateTime.utc(2026, 8, 4, 17),
      );
    });

    test('a git project is refused, and told which endpoint to use', () async {
      await repository.add(
        Project(
          id: 'p-git',
          gitUrl: 'https://github.com/acme/widget.git',
          name: 'widget',
          ownerId: alice.id,
        ),
      );

      final response = await bundle_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          user: alice,
          body: {'bundle': bundleJson(), 'scanId': 'scan-1'},
        ),
        'p-git',
      );

      expect(response.statusCode, HttpStatus.conflict);
      expect((await jsonOf(response))['reason'], contains('refresh'));
    });

    test('somebody else\'s project is a 404, not a 403', () async {
      final project = await localProject();

      final response = await bundle_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          user: const AuthUser(
            id: 'b0000000-0000-0000-0000-00000000000b',
            role: 'authenticated',
          ),
          body: {'bundle': bundleJson(), 'scanId': 'scan-1'},
        ),
        project.id,
      );

      expect(response.statusCode, HttpStatus.notFound);
    });

    test('a second upload while one is running returns the first', () async {
      final project = await localProject();

      final first = await bundle_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          user: alice,
          body: {'bundle': bundleJson(), 'scanId': 'second'},
        ),
        project.id,
      );
      final second = await bundle_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          user: alice,
          body: {'bundle': bundleJson(), 'scanId': 'third'},
        ),
        project.id,
      );

      expect(first.statusCode, HttpStatus.accepted);
      expect(second.statusCode, HttpStatus.accepted);
      expect((await jsonOf(second))['scanId'], 'second');
    });
  });

  group('POST /projects/<id>/refresh on a local project', () {
    test('is refused with 409 and says how to bring it up to date', () async {
      await projects_route.onRequest(
        contextFor(
          method: HttpMethod.post,
          user: alice,
          body: {'bundle': bundleJson(), 'scanId': 'first'},
        ),
      );
      await runQueuedScans();
      final project = (await repository.allForOwner(alice.id)).single;

      final response = await refresh_route.onRequest(
        contextFor(method: HttpMethod.post, user: alice, body: null),
        project.id,
      );

      // Same status and same shape as the archived-project refusal: the request
      // is well-formed and the project's state does not accept it.
      expect(response.statusCode, HttpStatus.conflict);
      final body = await jsonOf(response);
      expect(body['reason'], contains('depcontrol collect'));
      // And it says the thing a reader would otherwise get wrong: the project
      // is not going stale in the way "cannot refresh" suggests.
      expect(body['reason'], contains('advisories'));
    });
  });
}
