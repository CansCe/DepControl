import 'dart:io';

import 'package:dart_frog/dart_frog.dart';

import 'auth_user.dart';
import 'jwt_verifier.dart';

/// Global middleware: reads an *optional* `Authorization: Bearer <jwt>`, verifies
/// it, and injects an `AuthUser?` into the context (null when the header is
/// absent or the token is invalid). This never rejects a request on its own —
/// routes that must be protected apply [requireAuth] in their own `_middleware`.
Middleware authProvider(JwtVerifier verifier) {
  return (handler) {
    return (context) async {
      final user = await _tryReadUser(context.request, verifier);
      return handler(context.provide<AuthUser?>(() => user));
    };
  };
}

/// Guard for protected route subtrees: 401s any request without a valid user,
/// and re-provides the identity as a non-null `AuthUser` for handlers to read.
Middleware requireAuth() {
  return (handler) {
    return (context) {
      final user = context.read<AuthUser?>();
      if (user == null) {
        return Response.json(
          statusCode: HttpStatus.unauthorized,
          body: {'error': 'Authentication required'},
        );
      }
      return handler(context.provide<AuthUser>(() => user));
    };
  };
}

Future<AuthUser?> _tryReadUser(Request request, JwtVerifier verifier) async {
  final header =
      request.headers['Authorization'] ?? request.headers['authorization'];
  if (header == null) return null;

  final parts = header.split(' ');
  if (parts.length != 2 || parts.first.toLowerCase() != 'bearer') return null;

  try {
    return await verifier.verify(parts.last);
  } on AuthException {
    // Malformed/expired token → treat as anonymous. requireAuth turns the
    // absence of a user into a 401 at the routes that actually need one.
    return null;
  }
}
