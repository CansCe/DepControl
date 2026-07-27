import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';

void main() {
  /// Builds a client whose requests are captured, so tests can assert on the
  /// headers actually sent.
  ({ApiClient api, List<http.BaseRequest> sent}) clientFor(
    http.Response Function(http.Request request) respond, {
    String? token = 'test-token',
  }) {
    final sent = <http.BaseRequest>[];
    final api = ApiClient(
      client: MockClient((request) async {
        sent.add(request);
        return respond(request);
      }),
      accessToken: () async => token,
    );
    return (api: api, sent: sent);
  }

  http.Response ok(Object body) => http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json'},
      );

  group('authorization header', () {
    test('attaches the bearer token to GET requests', () async {
      final c = clientFor((_) => ok({'projects': <dynamic>[]}));
      await c.api.listProjects();

      expect(c.sent.single.headers['Authorization'], 'Bearer test-token');
    });

    test('attaches the bearer token to POST requests', () async {
      final c = clientFor(
        (_) => http.Response(
          jsonEncode({
            'project': {
              'id': 'p1',
              'gitUrl': 'https://example.com/a.git',
              'name': 'a',
              'ownerId': 'u1',
              'ref': 'HEAD',
            },
            'report': {
              'projectId': 'p1',
              'generatedAt': '2026-01-01T00:00:00.000Z',
              'nodes': <dynamic>[],
            },
          }),
          201,
          headers: {'content-type': 'application/json'},
        ),
      );

      await c.api.addProject('https://example.com/a.git');

      expect(c.sent.single.headers['Authorization'], 'Bearer test-token');
      expect(c.sent.single.headers['Content-Type'], contains('application/json'));
    });

    test('omits the header entirely when there is no session', () async {
      final c = clientFor((_) => ok({'projects': <dynamic>[]}), token: null);
      await c.api.listProjects();

      expect(c.sent.single.headers.containsKey('Authorization'), isFalse);
    });

    test('reads the token per request, so a refresh is picked up', () async {
      var current = 'first';
      final sent = <http.BaseRequest>[];
      final api = ApiClient(
        client: MockClient((request) async {
          sent.add(request);
          return ok({'projects': <dynamic>[]});
        }),
        accessToken: () async => current,
      );

      await api.listProjects();
      current = 'second';
      await api.listProjects();

      expect(sent.first.headers['Authorization'], 'Bearer first');
      expect(sent.last.headers['Authorization'], 'Bearer second');
    });
  });

  group('error handling', () {
    test('401 raises ApiAuthException carrying the server reason', () async {
      final c = clientFor(
        (_) => http.Response(
          jsonEncode({
            'error': 'Authentication failed',
            'reason': 'Token expired',
          }),
          401,
          headers: {'content-type': 'application/json'},
        ),
      );

      await expectLater(
        c.api.listProjects(),
        throwsA(
          isA<ApiAuthException>()
              .having((e) => e.message, 'message', 'Token expired'),
        ),
      );
    });

    test('400 raises ApiException with the server error', () async {
      final c = clientFor(
        (_) => http.Response(
          jsonEncode({'error': 'gitUrl is required'}),
          400,
          headers: {'content-type': 'application/json'},
        ),
      );

      await expectLater(
        c.api.addProject(''),
        throwsA(
          isA<ApiException>()
              .having((e) => e.message, 'message', 'gitUrl is required'),
        ),
      );
    });

    // Regression: these methods previously cast the body without checking the
    // status, so an error response surfaced as an opaque type error.
    test('a non-2xx on listProjects does not surface as a cast error',
        () async {
      final c = clientFor((_) => http.Response('Internal Server Error', 500));

      await expectLater(
        c.api.listProjects(),
        throwsA(isA<ApiException>()),
      );
    });

    test('an unreachable API is reported clearly', () async {
      final api = ApiClient(
        client: MockClient((_) async => throw const SocketExceptionStub()),
        accessToken: () async => 'test-token',
      );

      await expectLater(
        api.listProjects(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.message, 'message', contains('Cannot reach')),
        ),
      );
    });
  });

  group('parsing', () {
    test('maps the projects payload onto models', () async {
      final c = clientFor(
        (_) => ok({
          'projects': [
            {
              'id': 'p1',
              'gitUrl': 'https://example.com/a.git',
              'name': 'alpha',
              'ownerId': 'u1',
              'ref': 'main',
              'addedAt': '2026-01-01T00:00:00.000Z',
            },
          ],
        }),
      );

      final projects = await c.api.listProjects();

      expect(projects, hasLength(1));
      expect(projects.single.name, 'alpha');
      expect(projects.single.ownerId, 'u1');
      expect(projects.single.ref, 'main');
    });

    test('a report of null is returned as null, not an error', () async {
      final c = clientFor(
        (_) => ok({'project': <String, dynamic>{}, 'report': null}),
      );

      expect(await c.api.report('p1'), isNull);
    });
  });
}

/// Stands in for a network failure without importing dart:io (this test also
/// runs under the web test runner).
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
  @override
  String toString() => 'Connection refused';
}
