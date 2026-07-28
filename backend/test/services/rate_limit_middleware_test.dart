import 'dart:convert';
import 'dart:io';

import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:backend/src/repository/project_repository.dart';
import 'package:backend/src/services/rate_limit_middleware.dart';
import 'package:backend/src/services/rate_limiter.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../support/fakes.dart';

class _MockRequestContext extends Mock implements RequestContext {}

void main() {
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

  late Deps deps;
  var handled = 0;

  /// The wrapped handler: counts what actually reached the route.
  Handler pipeline() => rateLimitOutboundWork()((_) async {
        handled++;
        return Response(body: 'ok');
      });

  RequestContext contextFor(
    String path, {
    HttpMethod method = HttpMethod.post,
    AuthUser user = alice,
  }) {
    final context = _MockRequestContext();
    when(() => context.request).thenReturn(
      Request(method.value.toUpperCase(), Uri.parse('http://localhost$path')),
    );
    when(context.read<Deps>).thenReturn(deps);
    when(context.read<AuthUser>).thenReturn(user);
    return context;
  }

  void wire({RateLimiter? limiter}) {
    deps = Deps.forTesting(
      repository: InMemoryProjectRepository(),
      gitFetcher: FakeGitFetcher(),
      analyzer: FakeAnalyzer(),
      limiter: limiter,
    );
  }

  setUp(() {
    handled = 0;
    wire(limiter: RateLimiter(burst: 2, refill: const Duration(seconds: 1)));
  });

  group('what gets charged', () {
    test('a write is charged', () async {
      await pipeline()(contextFor('/projects'));
      await pipeline()(contextFor('/projects'));
      final third = await pipeline()(contextFor('/projects'));

      expect(third.statusCode, HttpStatus.tooManyRequests);
      expect(handled, 2);
    });

    // Listing projects and reading a stored report are database reads. Charging
    // them would ration the cheap half of the API to protect the expensive one.
    test('reading stored data is free', () async {
      for (var i = 0; i < 10; i++) {
        final response = await pipeline()(
          contextFor('/projects', method: HttpMethod.get),
        );
        expect(response.statusCode, HttpStatus.ok);
      }
      expect(handled, 10);
    });

    // The exception among reads: it re-fetches the pubspec and asks pub.dev for
    // a release history.
    test('the upgrade endpoint is charged despite being a GET', () async {
      await pipeline()(
        contextFor('/projects/p1/upgrade/http', method: HttpMethod.get),
      );
      await pipeline()(
        contextFor('/projects/p1/upgrade/yaml', method: HttpMethod.get),
      );
      final third = await pipeline()(
        contextFor('/projects/p1/upgrade/path', method: HttpMethod.get),
      );

      expect(third.statusCode, HttpStatus.tooManyRequests);
    });
  });

  group('the refusal', () {
    test('carries Retry-After and an explanation', () async {
      await pipeline()(contextFor('/projects'));
      await pipeline()(contextFor('/projects'));
      final refused = await pipeline()(contextFor('/projects'));

      expect(refused.statusCode, HttpStatus.tooManyRequests);
      expect(refused.headers[HttpHeaders.retryAfterHeader], '1');

      final body = jsonDecode(await refused.body()) as Map<String, dynamic>;
      expect(body['error'], 'Too many requests');
      expect(body['retryAfterSeconds'], 1);
      expect(body['reason'], contains('rate limited'));
    });

    test('does not reach the route', () async {
      for (var i = 0; i < 5; i++) {
        await pipeline()(contextFor('/projects'));
      }
      expect(handled, 2);
    });
  });

  test('one user cannot spend another\'s allowance', () async {
    await pipeline()(contextFor('/projects'));
    await pipeline()(contextFor('/projects'));
    expect(
      (await pipeline()(contextFor('/projects'))).statusCode,
      HttpStatus.tooManyRequests,
    );

    final bobsTurn = await pipeline()(contextFor('/projects', user: bob));
    expect(bobsTurn.statusCode, HttpStatus.ok);
  });

  test('no limiter configured lets everything through', () async {
    wire();

    for (var i = 0; i < 50; i++) {
      final response = await pipeline()(contextFor('/projects'));
      expect(response.statusCode, HttpStatus.ok);
    }
    expect(handled, 50);
  });
}
