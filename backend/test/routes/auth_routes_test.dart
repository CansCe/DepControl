import 'dart:convert';
import 'dart:io';

import 'package:backend/src/auth/auth_middleware.dart';
import 'package:backend/src/auth/auth_user.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../routes/index.dart' as root_route;
import '../../routes/me/index.dart' as me_route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

void main() {
  const alice = AuthUser(
    id: 'a0000000-0000-0000-0000-00000000000a',
    role: 'authenticated',
    email: 'alice@example.com',
  );

  Future<Map<String, dynamic>> jsonOf(Response response) async =>
      jsonDecode(await response.body()) as Map<String, dynamic>;

  group('GET /', () {
    test('reports service status and endpoints without auth', () async {
      final request = _MockRequest();
      when(() => request.method).thenReturn(HttpMethod.get);
      final context = _MockRequestContext();
      when(() => context.request).thenReturn(request);

      final response = root_route.onRequest(context);
      expect(response.statusCode, HttpStatus.ok);

      final body = await jsonOf(response);
      expect(body['service'], 'depcontrol-api');
      expect(body['status'], 'ok');
      expect(body['endpoints'], isNotEmpty);
    });
  });

  group('GET /me', () {
    _MockRequestContext contextFor(HttpMethod method) {
      final request = _MockRequest();
      when(() => request.method).thenReturn(method);
      final context = _MockRequestContext();
      when(() => context.request).thenReturn(request);
      when(context.read<AuthUser>).thenReturn(alice);
      return context;
    }

    test('returns the authenticated user, without leaking raw claims',
        () async {
      final response = me_route.onRequest(contextFor(HttpMethod.get));

      expect(response.statusCode, HttpStatus.ok);
      final user = (await jsonOf(response))['user'] as Map<String, dynamic>;
      expect(user['id'], alice.id);
      expect(user['email'], 'alice@example.com');
      expect(user['role'], 'authenticated');
      expect(user.containsKey('claims'), isFalse);
    });

    test('rejects a non-GET method with 405', () {
      final response = me_route.onRequest(contextFor(HttpMethod.post));
      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });

  group('requireAuth guard', () {
    /// Builds a context whose auth state is [user]/[failure], with `provide`
    /// stubbed to return itself so the guarded handler can run.
    _MockRequestContext contextFor({AuthUser? user, AuthFailure? failure}) {
      final context = _MockRequestContext();
      when(context.read<AuthUser?>).thenReturn(user);
      when(context.read<AuthFailure?>).thenReturn(failure);
      when(() => context.provide<AuthUser>(any())).thenReturn(context);
      return context;
    }

    final guarded = requireAuth()((_) async => Response(body: 'reached'));

    test('passes an authenticated request through to the handler', () async {
      final response = await guarded(contextFor(user: alice));

      expect(response.statusCode, HttpStatus.ok);
      expect(await response.body(), 'reached');
    });

    test('401s with a hint when no token was sent', () async {
      final response = await guarded(contextFor());

      expect(response.statusCode, HttpStatus.unauthorized);
      final body = await jsonOf(response);
      expect(body['error'], 'Authentication required');
      expect(body['reason'], contains('Authorization'));
    });

    test('401s with the reason when the token was rejected', () async {
      final response = await guarded(
        contextFor(
          failure: const AuthFailure('Token expired', HttpStatus.unauthorized),
        ),
      );

      expect(response.statusCode, HttpStatus.unauthorized);
      final body = await jsonOf(response);
      expect(body['error'], 'Authentication failed');
      expect(body['reason'], 'Token expired');
    });

    // A server-side fault must not be reported as a client auth problem.
    test('500s when verification itself is unavailable', () async {
      final response = await guarded(
        contextFor(
          failure: const AuthFailure(
            'JWKS fetch failed',
            HttpStatus.internalServerError,
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.internalServerError);
      final body = await jsonOf(response);
      expect(body['error'], 'Authentication unavailable');
      expect(body['reason'], 'JWKS fetch failed');
    });
  });
}
