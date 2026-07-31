import 'package:backend/src/ecosystem/dart_ecosystem.dart';
import 'package:backend/src/ecosystem/osv_client.dart';
import 'package:backend/src/services/pub_api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  /// A client whose archive HEADs answer with [headers], recording every
  /// request so a test can assert on the method as well as the path.
  ({PubApiClient pub, List<http.BaseRequest> seen}) serving({
    Map<String, String> headers = const {'content-length': '46315'},
    int status = 200,
  }) {
    final seen = <http.BaseRequest>[];
    final client = MockClient((request) async {
      seen.add(request);
      // A real HEAD comes back with the header and an empty body, which is the
      // whole reason this path cannot read `Response.contentLength`.
      return http.Response('', status, headers: headers);
    });

    return (
      pub: PubApiClient(client: client, baseUrl: 'https://pub.test'),
      seen: seen,
    );
  }

  group('archiveSizeBytes', () {
    test('reads Content-Length without transferring the archive', () async {
      final s = serving();

      expect(await s.pub.archiveSizeBytes('http', '1.6.0'), 46315);
      expect(s.seen.single.method, 'HEAD');
      expect(s.seen.single.url.path, '/api/archives/http-1.6.0.tar.gz');
    });

    test('reads the header rather than the body length', () async {
      // `Response.contentLength` is derived from the body, and a HEAD has no
      // body — so it reads 0 for every archive on pub.dev however large.
      // Trusting it would report the whole ecosystem as unmeasured while
      // looking like it worked.
      final s = serving(headers: const {'content-length': '1048576'});

      expect(await s.pub.archiveSizeBytes('analyzer', '12.1.0'), 1048576);
    });

    test('a version pub.dev does not serve reports no size', () async {
      final s = serving(status: 404);

      expect(await s.pub.archiveSizeBytes('http', '99.0.0'), isNull);
    });

    test('a response without the header reports no size, not zero', () async {
      final s = serving(headers: const {});

      expect(await s.pub.archiveSizeBytes('http', '1.6.0'), isNull);
    });

    test('a transport failure is a gap in the report, not a failed scan', () {
      final client = MockClient(
        (_) async => throw http.ClientException('connection reset'),
      );
      final pub = PubApiClient(client: client, baseUrl: 'https://pub.test');

      expect(pub.archiveSizeBytes('http', '1.6.0'), completion(isNull));
    });

    group('untrusted input never reaches the path', () {
      test('a package name that would climb out of the prefix', () async {
        // Names arrive from fetched pubspecs. `../../admin` normalises the API
        // prefix away and issues a request nobody asked for.
        final s = serving();

        expect(await s.pub.archiveSizeBytes('../../admin', '1.0.0'), isNull);
        expect(s.seen, isEmpty);
      });

      test('a version out of a lockfile the project controls', () async {
        final s = serving();

        expect(await s.pub.archiveSizeBytes('http', '../../../etc'), isNull);
        expect(await s.pub.archiveSizeBytes('http', ''), isNull);
        expect(s.seen, isEmpty);
      });
    });
  });

  group('DartRegistry.sizeOf', () {
    DartRegistry registryOver(http.Client client) => DartRegistry(
          PubApiClient(client: client, baseUrl: 'https://pub.test'),
          osv: OsvClient(client: client),
        );

    test('reports the compressed archive, and says that is what it is', () async {
      final registry = registryOver(
        MockClient((_) async =>
            http.Response('', 200, headers: {'content-length': '46315'})),
      );

      final size = await registry.sizeOf('http', '1.6.0');

      expect(size?.bytes, 46315);
      // Not converted to an installed size. Source compresses by a factor that
      // depends on what the package is made of, and multiplying by a guess
      // would turn a measurement into an invention.
      expect(size?.basis, SizeBasis.archive);
      // A HEAD says how long the archive is and nothing about what is in it.
      expect(size?.fileCount, isNull);
    });

    test('an unresolved version is not a request worth making', () async {
      final seen = <http.BaseRequest>[];
      final registry = registryOver(MockClient((request) async {
        seen.add(request);
        return http.Response('', 200, headers: {'content-length': '10'});
      }));

      expect(await registry.sizeOf('http', '(unresolved)'), isNull);
      expect(seen, isEmpty);
    });
  });
}
