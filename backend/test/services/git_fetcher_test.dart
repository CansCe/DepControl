import 'dart:async';
import 'dart:convert';

import 'package:backend/src/services/git_fetcher.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const _pubspec = 'name: demo\n';

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
