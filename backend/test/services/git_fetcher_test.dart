import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:backend/src/services/git_fetcher.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const _pubspec = 'name: demo\n';

/// A repository tarball as a forge serves one: every path under a single
/// top-level directory named for the repo and ref.
Uint8List _tarGz(Map<String, String> files, {String prefix = 'demo-main'}) {
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = utf8.encode(entry.value);
    archive.add(ArchiveFile('$prefix/${entry.key}', bytes.length, bytes));
  }
  return GZipEncoder().encodeBytes(TarEncoder().encodeBytes(archive));
}

/// Records every URL requested and serves [bodies] by path, 404 otherwise.
({GitFetcher fetcher, List<Uri> requested}) fetcherFor({
  Map<String, String> bodies = const {},
}) {
  final requested = <Uri>[];
  final client = MockClient((request) async {
    requested.add(request.url);
    final body = bodies[request.url.path];
    if (body == null) return http.Response('not found', 404);
    return http.Response(body, 200);
  });
  return (fetcher: GitFetcher(client: client), requested: requested);
}

void main() {
  group('URL construction', () {
    test('reads a GitHub repo from raw.githubusercontent.com', () async {
      final f = fetcherFor(
        bodies: {'/acme/demo/main/pubspec.yaml': _pubspec},
      );

      final files = await f.fetcher.fetch(
        'https://github.com/acme/demo.git',
        ref: 'main',
      );

      expect(files.pubspecYaml, _pubspec);
      expect(f.requested.first.host, 'raw.githubusercontent.com');
      expect(f.requested.first.path, '/acme/demo/main/pubspec.yaml');
    });

    test('reads a GitLab repo from its raw path', () async {
      final f = fetcherFor(
        bodies: {'/acme/demo/-/raw/main/pubspec.yaml': _pubspec},
      );

      await f.fetcher.fetch('https://gitlab.com/acme/demo', ref: 'main');

      expect(f.requested.first.host, 'gitlab.com');
      expect(f.requested.first.path, '/acme/demo/-/raw/main/pubspec.yaml');
    });

    test('keeps a slash-bearing branch name intact', () async {
      final f = fetcherFor(
        bodies: {'/acme/demo/feature/thing/pubspec.yaml': _pubspec},
      );

      await f.fetcher.fetch(
        'https://github.com/acme/demo',
        ref: 'feature/thing',
      );

      expect(f.requested.first.path, '/acme/demo/feature/thing/pubspec.yaml');
    });

    test('a missing lockfile is absent, not an error', () async {
      final f = fetcherFor(
        bodies: {'/acme/demo/HEAD/pubspec.yaml': _pubspec},
      );

      final files = await f.fetcher.fetch('https://github.com/acme/demo');

      expect(files.hasLock, isFalse);
    });
  });

  group('ref validation', () {
    // The one that matters. `..` normalises the repository out of the raw URL,
    // so the server would fetch a different project's pubspec while the stored
    // project still points at this one.
    test('refuses a ref that climbs out of the repository', () async {
      final f = fetcherFor();

      await expectLater(
        f.fetcher.fetch(
          'https://github.com/acme/demo',
          ref: '../../victim/other/main',
        ),
        throwsA(isA<StateError>()),
      );
      // Nothing was requested at all: it is rejected before the network.
      expect(f.requested, isEmpty);
    });

    test('refuses traversal buried mid-ref', () async {
      final f = fetcherFor();

      await expectLater(
        f.fetcher.fetch(
          'https://github.com/acme/demo',
          ref: 'main/../../../victim/other/main',
        ),
        throwsA(isA<StateError>()),
      );
      expect(f.requested, isEmpty);
    });

    // A query or fragment truncates the path, so the request stops being for a
    // pubspec at all.
    test('refuses a ref carrying URL syntax', () async {
      final f = fetcherFor();

      for (final ref in ['main?x=1', 'main#frag', 'main%2f..', 'ma in']) {
        await expectLater(
          f.fetcher.fetch('https://github.com/acme/demo', ref: ref),
          throwsA(isA<StateError>()),
          reason: 'ref "$ref" should be rejected',
        );
      }
      expect(f.requested, isEmpty);
    });

    test('accepts a commit sha and a tag', () async {
      const sha = 'e83c5163316f89bfbde7d9ab23ca2e25604af290';
      final f = fetcherFor(
        bodies: {
          '/acme/demo/$sha/pubspec.yaml': _pubspec,
          '/acme/demo/v1.2.3/pubspec.yaml': _pubspec,
        },
      );

      await f.fetcher.fetch('https://github.com/acme/demo', ref: sha);
      await f.fetcher.fetch('https://github.com/acme/demo', ref: 'v1.2.3');
    });
  });

  group('host and repository validation', () {
    test('refuses a host that is not a known forge', () async {
      final f = fetcherFor();

      await expectLater(
        f.fetcher.fetch('https://internal.corp.example/acme/demo'),
        throwsA(isA<StateError>()),
      );
      expect(f.requested, isEmpty);
    });

    // A lookalike host must not pass because it contains an allowed one.
    test('refuses a lookalike host', () async {
      final f = fetcherFor();

      await expectLater(
        f.fetcher.fetch('https://github.com.evil.example/acme/demo'),
        throwsA(isA<StateError>()),
      );
      expect(f.requested, isEmpty);
    });

    test('refuses a non-https URL', () async {
      final f = fetcherFor();

      await expectLater(
        f.fetcher.fetch('http://github.com/acme/demo'),
        throwsA(isA<StateError>()),
      );
      expect(f.requested, isEmpty);
    });

    test('refuses a URL that names no repository', () async {
      final f = fetcherFor();

      await expectLater(
        f.fetcher.fetch('https://github.com/acme'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('response limits', () {
    test('refuses a body past the cap', () async {
      final huge = 'x' * (GitFetcher.maxResponseBytes + 1);
      final f = fetcherFor(bodies: {'/acme/demo/HEAD/pubspec.yaml': huge});

      await expectLater(
        f.fetcher.fetch('https://github.com/acme/demo'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('larger than'),
          ),
        ),
      );
    });

    test('accepts a body at the cap', () async {
      final big = 'x' * GitFetcher.maxResponseBytes;
      final f = fetcherFor(bodies: {'/acme/demo/HEAD/pubspec.yaml': big});

      final files = await f.fetcher.fetch('https://github.com/acme/demo');
      expect(files.pubspecYaml.length, GitFetcher.maxResponseBytes);
    });

    test('gives up on a host that never responds', () async {
      final client = MockClient(
        (_) => Completer<http.Response>().future, // never completes
      );
      final fetcher = GitFetcher(
        client: client,
        timeout: const Duration(milliseconds: 50),
      );

      await expectLater(
        fetcher.fetch('https://github.com/acme/demo'),
        throwsA(
          isA<StateError>()
              .having((e) => e.message, 'message', contains('Timed out')),
        ),
      );
    });
  });

  group('reading the repository from its tarball', () {
    /// Serves [archive] from the forge's archive endpoint, and [raw]/[treePaths]
    /// from the file-by-file endpoints so the fallback can be observed too.
    ({GitFetcher fetcher, List<Uri> requested}) serving(
      Uint8List? archive, {
      Map<String, String> raw = const {},
      List<String> treePaths = const [],
      int maxArchiveBytes = GitFetcher.defaultMaxArchiveBytes,
    }) {
      final requested = <Uri>[];
      final client = MockClient((request) async {
        requested.add(request.url);

        if (request.url.host == 'codeload.github.com' ||
            request.url.path.endsWith('archive.tar.gz')) {
          return archive == null
              ? http.Response('not found', 404)
              : http.Response.bytes(archive, 200);
        }
        if (request.url.host == 'api.github.com') {
          return http.Response(
            jsonEncode({
              'tree': [
                for (final path in treePaths) {'path': path, 'type': 'blob'},
              ],
            }),
            200,
          );
        }
        final body = raw[request.url.path];
        return body == null
            ? http.Response('not found', 404)
            : http.Response(body, 200);
      });
      return (
        fetcher: GitFetcher(client: client, maxArchiveBytes: maxArchiveBytes),
        requested: requested,
      );
    }

    test('reads every pubspec and its imports in one request', () async {
      final f = serving(
        _tarGz({
          'pubspec.yaml': 'name: demo\n',
          'pubspec.lock': 'packages:\n',
          'lib/main.dart': "import 'package:http/http.dart';\n",
          'test/main_test.dart': "import 'package:test/test.dart';\n",
        }),
      );

      final repo = await f.fetcher.fetchAll(
        'https://github.com/acme/demo',
        ref: 'main',
      );

      expect(f.requested, hasLength(1));
      expect(f.requested.single.host, 'codeload.github.com');
      expect(f.requested.single.path, '/acme/demo/tar.gz/main');

      expect(repo.manifests, hasLength(1));
      expect(repo.primary.files.pubspecYaml, 'name: demo\n');
      expect(repo.primary.files.hasLock, isTrue);
      expect(repo.primary.importedPackages, {'http', 'test'});
      expect(repo.discoveryNote, isNull);
    });

    // The whole point of reading a monorepo package by package: counting the
    // differ's imports against the root would report the root as depending on
    // packages it has never heard of.
    test('attributes source to the package nearest above it', () async {
      final f = serving(
        _tarGz({
          'pubspec.yaml': 'name: root\n',
          'lib/root.dart': "import 'package:http/http.dart';\n",
          'tools/differ/pubspec.yaml': 'name: differ\n',
          'tools/differ/lib/differ.dart': "import 'package:yaml/yaml.dart';\n",
        }),
      );

      final repo = await f.fetcher.fetchAll('https://github.com/acme/demo');

      expect(repo.manifests.map((m) => m.directory), ['', 'tools/differ']);
      expect(repo.manifests.first.importedPackages, {'http'});
      expect(repo.manifests.last.importedPackages, {'yaml'});
    });

    test('reads a lint set out of analysis options', () async {
      final f = serving(
        _tarGz({
          'pubspec.yaml': 'name: demo\n',
          'analysis_options.yaml': 'include: package:lints/recommended.yaml\n',
        }),
      );

      final repo = await f.fetcher.fetchAll('https://github.com/acme/demo');
      expect(repo.primary.importedPackages, {'lints'});
    });

    test('ignores generated and vendored trees', () async {
      final f = serving(
        _tarGz({
          'pubspec.yaml': 'name: demo\n',
          'lib/main.dart': "import 'package:http/http.dart';\n",
          '.dart_tool/pub/pubspec.yaml': 'name: junk\n',
          'build/web/main.dart': "import 'package:ghost/ghost.dart';\n",
          'ios/Pods/Thing/pubspec.yaml': 'name: pod\n',
        }),
      );

      final repo = await f.fetcher.fetchAll('https://github.com/acme/demo');

      expect(repo.manifests, hasLength(1));
      expect(repo.primary.importedPackages, {'http'});
    });

    // The root is not special to a tarball, so a repository that keeps its
    // package one level down is now readable at all.
    test('reads a repository whose only package is in a subdirectory',
        () async {
      final f = serving(
        _tarGz({
          'README.md': '# demo\n',
          'packages/app/pubspec.yaml': 'name: app\n',
          'packages/app/lib/app.dart': "import 'package:http/http.dart';\n",
        }),
      );

      final repo = await f.fetcher.fetchAll('https://github.com/acme/demo');

      expect(repo.primary.directory, 'packages/app');
      expect(repo.primary.importedPackages, {'http'});
    });

    test('caps how many manifests it reads, and says it capped', () async {
      final f = serving(
        _tarGz({
          'pubspec.yaml': 'name: root\n',
          for (var i = 0; i < GitFetcher.maxManifests + 5; i++)
            'pkg$i/pubspec.yaml': 'name: pkg$i\n',
        }),
      );

      final repo = await f.fetcher.fetchAll('https://github.com/acme/demo');

      expect(repo.manifests, hasLength(GitFetcher.maxManifests));
      expect(repo.discoveryNote, contains('were read'));
    });

    // Alphabetically `examples` beats `packages`, so a repository laid out like
    // bloc's used to spend its whole budget on demo apps and report nothing
    // about the library the repository is actually for.
    test('spends the cap on libraries before examples', () async {
      // Padded so alphabetical order matches numeric, and the example that
      // loses its place is unambiguously the last one.
      String demo(int i) => 'examples/demo${i.toString().padLeft(2, '0')}';
      final last = demo(GitFetcher.maxManifests - 1);

      final f = serving(
        _tarGz({
          for (var i = 0; i < GitFetcher.maxManifests; i++)
            '${demo(i)}/pubspec.yaml': 'name: demo$i\n',
          'packages/core/pubspec.yaml': 'name: core\n',
        }),
      );

      final repo = await f.fetcher.fetchAll('https://github.com/acme/demo');
      final read = repo.manifests.map((m) => m.directory);

      expect(repo.primary.directory, 'packages/core');
      expect(read, isNot(contains(last)));
      expect(read, contains(demo(0)));
    });

    test('a repository with no pubspec anywhere is an error', () async {
      final f = serving(_tarGz({'README.md': '# nothing here\n'}));

      await expectLater(
        f.fetcher.fetchAll('https://github.com/acme/demo'),
        throwsA(
          isA<StateError>()
              .having((e) => e.message, 'message', contains('No pubspec.yaml')),
        ),
      );
    });

    test('asks GitLab for the project as one encoded segment', () async {
      final f = serving(
        _tarGz({'pubspec.yaml': 'name: demo\n'}, prefix: 'demo-main-abc123'),
      );

      await f.fetcher.fetchAll('https://gitlab.com/acme/demo', ref: 'main');

      // Not `acme%252Fdemo`: encoding the encoding asks GitLab for a project
      // whose name literally contains a percent sign.
      expect(
        f.requested.single.toString(),
        'https://gitlab.com/api/v4/projects/acme%2Fdemo'
        '/repository/archive.tar.gz?sha=main',
      );
    });

    group('falling back to reading files', () {
      test('when the archive is not there', () async {
        final f = serving(
          null,
          raw: {'/acme/demo/HEAD/pubspec.yaml': 'name: root\n'},
          treePaths: ['pubspec.yaml'],
        );

        final repo = await f.fetcher.fetchAll('https://github.com/acme/demo');

        expect(repo.manifests, hasLength(1));
        expect(repo.primary.files.pubspecYaml, 'name: root\n');
        // The report is complete; only the import facts are missing, and a null
        // says so rather than an empty set claiming nothing is imported.
        expect(repo.primary.importedPackages, isNull);
        expect(f.requested.first.host, 'codeload.github.com');
        expect(f.requested.map((u) => u.host), contains('api.github.com'));
      });

      test('when the body is not an archive at all', () async {
        final f = serving(
          Uint8List.fromList(utf8.encode('<html>rate limited</html>')),
          raw: {'/acme/demo/HEAD/pubspec.yaml': 'name: root\n'},
          treePaths: ['pubspec.yaml'],
        );

        final repo = await f.fetcher.fetchAll('https://github.com/acme/demo');
        expect(repo.primary.files.pubspecYaml, 'name: root\n');
      });

      // A few hundred kilobytes of gzip expands to gigabytes. The cap is
      // counted as it inflates, so this stops mid-stream rather than after.
      test('when the archive inflates past the cap', () async {
        final f = serving(
          _tarGz({'pubspec.yaml': 'name: demo\n', 'big.txt': 'x' * 200000}),
          raw: {'/acme/demo/HEAD/pubspec.yaml': 'name: root\n'},
          treePaths: ['pubspec.yaml'],
          maxArchiveBytes: 4096,
        );

        final repo = await f.fetcher.fetchAll('https://github.com/acme/demo');

        expect(repo.primary.files.pubspecYaml, 'name: root\n');
        expect(repo.primary.importedPackages, isNull);
      });
    });

    test('refuses a traversing ref before requesting anything', () async {
      final f = serving(_tarGz({'pubspec.yaml': _pubspec}));

      await expectLater(
        f.fetcher.fetchAll(
          'https://github.com/acme/demo',
          ref: '../../victim/other/main',
        ),
        throwsA(isA<StateError>()),
      );
      expect(f.requested, isEmpty);
    });
  });

  group('discovering every manifest', () {
    /// Serves the GitHub tree API from [paths] plus raw files from [bodies].
    GitFetcher repoWith({
      required List<String> paths,
      required Map<String, String> bodies,
      int treeStatus = 200,
    }) {
      final client = MockClient((request) async {
        if (request.url.host == 'api.github.com') {
          if (treeStatus != 200) {
            return http.Response('{"message":"rate limited"}', treeStatus);
          }
          return http.Response(
            jsonEncode({
              'tree': [
                for (final path in paths) {'path': path, 'type': 'blob'},
              ],
            }),
            200,
          );
        }
        final body = bodies[request.url.path];
        return body == null
            ? http.Response('not found', 404)
            : http.Response(body, 200);
      });
      return GitFetcher(client: client);
    }

    test('reads a pubspec in a subdirectory as well as the root', () async {
      final fetcher = repoWith(
        paths: ['pubspec.yaml', 'tools/differ/pubspec.yaml', 'README.md'],
        bodies: {
          '/acme/demo/HEAD/pubspec.yaml': 'name: root\n',
          '/acme/demo/HEAD/tools/differ/pubspec.yaml': 'name: differ\n',
          '/acme/demo/HEAD/tools/differ/pubspec.lock': 'packages:\n',
        },
      );

      final repo = await fetcher.fetchAll('https://github.com/acme/demo');

      expect(repo.manifests.map((m) => m.directory), ['', 'tools/differ']);
      expect(repo.manifests.first.files.pubspecYaml, 'name: root\n');
      expect(repo.manifests.last.files.pubspecYaml, 'name: differ\n');
      expect(repo.manifests.last.files.hasLock, isTrue);
      expect(repo.discoveryNote, isNull);
    });

    test('labels the root manifest readably', () async {
      final fetcher = repoWith(
        paths: ['pubspec.yaml'],
        bodies: {'/acme/demo/HEAD/pubspec.yaml': 'name: root\n'},
      );

      final repo = await fetcher.fetchAll('https://github.com/acme/demo');
      expect(repo.primary.label, 'repository root');
    });

    test('ignores generated and build trees', () async {
      final fetcher = repoWith(
        paths: [
          'pubspec.yaml',
          '.dart_tool/pub/pubspec.yaml',
          'frontend/build/web/pubspec.yaml',
        ],
        bodies: {'/acme/demo/HEAD/pubspec.yaml': 'name: root\n'},
      );

      final repo = await fetcher.fetchAll('https://github.com/acme/demo');
      expect(repo.manifests, hasLength(1));
    });

    // The tree API is rate limited and shared by IP. Losing it should cost
    // coverage, not the whole scan.
    test('falls back to the root and says so when listing fails', () async {
      final fetcher = repoWith(
        paths: const [],
        bodies: {'/acme/demo/HEAD/pubspec.yaml': 'name: root\n'},
        treeStatus: 403,
      );

      final repo = await fetcher.fetchAll('https://github.com/acme/demo');

      expect(repo.manifests, hasLength(1));
      expect(repo.discoveryNote, contains('only the pubspec.yaml at its root'));
    });

    test('caps how many manifests it reads, and says it capped', () async {
      final many = [
        'pubspec.yaml',
        for (var i = 0; i < GitFetcher.maxManifests + 5; i++)
          'pkg$i/pubspec.yaml',
      ];
      final fetcher = repoWith(
        paths: many,
        bodies: {
          '/acme/demo/HEAD/pubspec.yaml': 'name: root\n',
          for (var i = 0; i < GitFetcher.maxManifests + 5; i++)
            '/acme/demo/HEAD/pkg$i/pubspec.yaml': 'name: pkg$i\n',
        },
      );

      final repo = await fetcher.fetchAll('https://github.com/acme/demo');

      expect(repo.manifests, hasLength(GitFetcher.maxManifests + 1));
      expect(repo.discoveryNote, contains('were read'));
    });

    test('skips a listed manifest that cannot be read', () async {
      final fetcher = repoWith(
        paths: ['pubspec.yaml', 'ghost/pubspec.yaml'],
        bodies: {'/acme/demo/HEAD/pubspec.yaml': 'name: root\n'},
      );

      final repo = await fetcher.fetchAll('https://github.com/acme/demo');
      expect(repo.manifests, hasLength(1));
    });

    test('still refuses a traversing ref while discovering', () async {
      final fetcher = repoWith(
        paths: const [],
        bodies: const {},
      );

      await expectLater(
        fetcher.fetchAll('https://github.com/acme/demo', ref: '../../other/x'),
        throwsA(isA<StateError>()),
      );
    });
  });

  test('decodes a pubspec that is not valid UTF-8 rather than throwing',
      () async {
    final client = MockClient((request) async {
      if (!request.url.path.endsWith('pubspec.yaml')) {
        return http.Response('not found', 404);
      }
      return http.Response.bytes([...utf8.encode('name: demo'), 0xC3], 200);
    });

    final files =
        await GitFetcher(client: client).fetch('https://github.com/acme/demo');
    expect(files.pubspecYaml, startsWith('name: demo'));
  });
}
