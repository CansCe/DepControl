import 'dart:async';
import 'dart:convert';

import 'package:backend/src/ecosystem/osv_client.dart';
import 'package:backend/src/services/pub_api_client.dart';
import 'package:backend/src/services/request_cache.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

http.Response _ok(Object body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );

void main() {
  group('RequestCache', () {
    test('asks once for an answer it already has', () async {
      var calls = 0;
      final cache = RequestCache<String, int>(capacity: 4, ttl: const Duration(minutes: 1));

      expect(await cache.run('a', () async => ++calls), 1);
      expect(await cache.run('a', () async => ++calls), 1);
      expect(calls, 1);
    });

    // The case a scan actually hits: eight workers reach for the same popular
    // package in the same instant. A cache holding values rather than futures
    // would let all eight through, because none of them has finished yet.
    test('two callers arriving together share one request', () async {
      var calls = 0;
      final gate = Completer<void>();
      final cache = RequestCache<String, int>(capacity: 4, ttl: const Duration(minutes: 1));

      Future<int> fetch() async {
        calls++;
        await gate.future;
        return 7;
      }

      final both = Future.wait([cache.run('a', fetch), cache.run('a', fetch)]);
      gate.complete();

      expect(await both, [7, 7]);
      expect(calls, 1);
    });

    test('drops the least recently used entry when full', () async {
      var calls = 0;
      final cache = RequestCache<String, int>(
        capacity: 2,
        ttl: const Duration(minutes: 1),
      );

      await cache.run('a', () async => ++calls);
      await cache.run('b', () async => ++calls);
      // Touching 'a' makes 'b' the oldest.
      await cache.run('a', () async => ++calls);
      await cache.run('c', () async => ++calls);

      expect(cache.length, 2);
      // 'a' is still held; 'b' was evicted and costs a request again.
      await cache.run('a', () async => ++calls);
      expect(calls, 3);
      await cache.run('b', () async => ++calls);
      expect(calls, 4);
    });

    // The distinction the whole design turns on: an answer is worth keeping,
    // a silence is not.
    test('does not remember an answer it was told not to keep', () async {
      var calls = 0;
      final cache = RequestCache<String, bool>(
        capacity: 4,
        ttl: const Duration(minutes: 1),
      );

      Future<bool> fetch() async => ++calls > 1;

      expect(await cache.run('a', fetch, keep: (ok) => ok), isFalse);
      expect(await cache.run('a', fetch, keep: (ok) => ok), isTrue);
      // Now that a real answer landed, it stays.
      expect(await cache.run('a', fetch, keep: (ok) => ok), isTrue);
      expect(calls, 2);
    });

    // The failure a cache with no expiry would cause: a server up for a week
    // reporting the versions and advisories that existed when it started, so a
    // nightly rescan never notices anything. Slow is survivable; permanently
    // wrong is not.
    test('an answer goes stale', () async {
      var calls = 0;
      final cache = RequestCache<String, int>(
        capacity: 4,
        ttl: const Duration(milliseconds: 20),
      );

      expect(await cache.run('a', () async => ++calls), 1);
      expect(await cache.run('a', () async => ++calls), 1);

      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(await cache.run('a', () async => ++calls), 2);
    });

    // A hit that reset the clock would make a busy key immortal — exactly the
    // key a scan asks about most.
    test('a hit does not renew the expiry', () async {
      var calls = 0;
      final cache = RequestCache<String, int>(
        capacity: 4,
        ttl: const Duration(milliseconds: 60),
      );

      expect(await cache.run('a', () async => ++calls), 1);
      for (var i = 0; i < 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        await cache.run('a', () async => ++calls);
      }

      expect(calls, 2);
    });

    test('a lookup that throws is not remembered as an answer', () async {
      var calls = 0;
      final cache = RequestCache<String, int>(capacity: 4, ttl: const Duration(minutes: 1));

      Future<int> fetch() async {
        if (++calls == 1) throw StateError('boom');
        return 9;
      }

      await expectLater(cache.run('a', fetch), throwsStateError);
      expect(await cache.run('a', fetch), 9);
    });
  });

  group('PubApiClient', () {
    /// A pub.dev serving one package, recording every path it is asked for.
    ({PubApiClient pub, List<String> seen}) serving({
      List<String> versions = const ['1.0.0', '1.2.0'],
      String latest = '1.2.0',
    }) {
      final seen = <String>[];
      final client = MockClient((request) async {
        seen.add(request.url.path);
        if (request.url.path != '/api/packages/http') {
          return http.Response('{}', 404);
        }
        return _ok({
          'latest': {'version': latest},
          'versions': [
            for (final v in versions)
              {
                'version': v,
                'pubspec': {
                  'environment': {'sdk': '^3.0.0'},
                  'dependencies': {'meta': '^1.0.0'},
                },
              },
          ],
        });
      });
      return (
        pub: PubApiClient(client: client, baseUrl: 'https://pub.test'),
        seen: seen,
      );
    }

    // Before this, `latestVersion`, `versions` and `dependencyNames` were three
    // separate requests for one document pub.dev serves whole — and they were
    // made again for every manifest in the repository that wanted the package.
    test('answers latest, versions and edges from one document', () async {
      final s = serving();

      expect(await s.pub.latestVersion('http'), '1.2.0');
      expect((await s.pub.versions('http')).map((v) => '${v.version}'),
          ['1.0.0', '1.2.0']);
      expect(await s.pub.dependencyNames('http', '1.2.0'), ['meta']);

      expect(s.seen, ['/api/packages/http']);
    });

    // A version the document does not list — a retracted release a lockfile
    // still pins — is served by the per-version endpoint alone, so that request
    // is still worth making.
    test('falls back to the per-version endpoint for an unlisted version',
        () async {
      final s = serving();

      expect(await s.pub.dependencyNames('http', '0.9.0'), isEmpty);
      expect(s.seen, contains('/api/packages/http/versions/0.9.0'));
    });

    test('a package pub.dev does not have is asked about once', () async {
      final s = serving();

      expect(await s.pub.latestVersion('absent'), isNull);
      expect(await s.pub.latestVersion('absent'), isNull);

      expect(s.seen.where((p) => p == '/api/packages/absent'), hasLength(1));
    });

    // A 404 is pub.dev saying it has no such package. A timeout is pub.dev
    // saying nothing at all, and remembering that as an answer would report the
    // package as unknown for the life of the process — long after pub.dev came
    // back.
    test('an unreachable moment is not remembered as an answer', () async {
      var calls = 0;
      final client = MockClient((request) async {
        if (++calls == 1) throw http.ClientException('connection reset');
        return _ok({
          'latest': {'version': '1.2.0'},
          'versions': const <dynamic>[],
        });
      });
      final pub = PubApiClient(client: client, baseUrl: 'https://pub.test');

      expect(await pub.latestVersion('http'), isNull);
      expect(await pub.latestVersion('http'), '1.2.0');
    });

    test('a 500 is not remembered either', () async {
      var calls = 0;
      final client = MockClient((request) async {
        if (++calls == 1) return http.Response('nope', 503);
        return _ok({
          'latest': {'version': '1.2.0'},
          'versions': const <dynamic>[],
        });
      });
      final pub = PubApiClient(client: client, baseUrl: 'https://pub.test');

      expect(await pub.latestVersion('http'), isNull);
      expect(await pub.latestVersion('http'), '1.2.0');
    });

    test('reads a version score once', () async {
      final seen = <String>[];
      final client = MockClient((request) async {
        seen.add(request.url.path);
        return _ok({
          'tags': ['license:mit'],
        });
      });
      final pub = PubApiClient(client: client, baseUrl: 'https://pub.test');

      expect(await pub.versionTags('http', '1.2.0'), ['license:mit']);
      expect(await pub.versionTags('http', '1.2.0'), ['license:mit']);
      // The latest-release score is a different endpoint and must not be
      // served from the per-version entry.
      expect(await pub.latestTags('http'), ['license:mit']);

      expect(seen, [
        '/api/packages/http/versions/1.2.0/score',
        '/api/packages/http/score',
      ]);
    });

    test('weighs an archive once', () async {
      final seen = <http.BaseRequest>[];
      final client = MockClient((request) async {
        seen.add(request);
        return http.Response('', 200, headers: {'content-length': '4096'});
      });
      final pub = PubApiClient(client: client, baseUrl: 'https://pub.test');

      expect(await pub.archiveSizeBytes('http', '1.2.0'), 4096);
      expect(await pub.archiveSizeBytes('http', '1.2.0'), 4096);

      expect(seen, hasLength(1));
      expect(seen.single.method, 'HEAD');
    });
  });

  group('OsvClient', () {
    test('queries a package once', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return _ok({'vulns': const <dynamic>[]});
      });
      final osv = OsvClient(client: client, baseUrl: 'https://osv.test');

      expect(await osv.advisoriesFor('http', ecosystem: 'Pub'), isEmpty);
      expect(await osv.advisoriesFor('http', ecosystem: 'Pub'), isEmpty);
      expect(calls, 1);
    });

    // The same name in two ecosystems is two unrelated packages — npm and
    // pub.dev both publish a `path` — so the ecosystem has to be part of the
    // key or one would answer for the other.
    test('keeps ecosystems apart', () async {
      final asked = <String>[];
      final client = MockClient((request) async {
        asked.add((jsonDecode(request.body)['package'] as Map)['ecosystem']
            as String);
        return _ok({'vulns': const <dynamic>[]});
      });
      final osv = OsvClient(client: client, baseUrl: 'https://osv.test');

      await osv.advisoriesFor('path', ecosystem: 'Pub');
      await osv.advisoriesFor('path', ecosystem: 'npm');

      expect(asked, ['Pub', 'npm']);
    });

    // An unreachable advisory database must never be remembered as a clean
    // bill of health.
    test('does not remember a silence as "no advisories"', () async {
      var calls = 0;
      final client = MockClient((request) async {
        if (++calls == 1) throw http.ClientException('connection reset');
        return _ok({
          'vulns': [
            {'id': 'GHSA-x'},
          ],
        });
      });
      final osv = OsvClient(client: client, baseUrl: 'https://osv.test');

      expect(await osv.advisoriesFor('http', ecosystem: 'Pub'), isEmpty);
      expect(
        (await osv.advisoriesFor('http', ecosystem: 'Pub')).single.id,
        'GHSA-x',
      );
    });
  });
}
