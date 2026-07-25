import 'dart:io';

import 'package:dart_frog/dart_frog.dart';

import '../services/logger.dart';
import 'auth_user.dart';
import 'jwt_verifier.dart';

/// Why a request has no authenticated user. Provided alongside `AuthUser?` so
/// [requireAuth] can explain the rejection instead of returning a bare 401.
///
/// [statusCode] carries the verifier's own classification: 401 for a bad token,
/// 500 when the server is misconfigured (missing secret, unreachable JWKS).
class AuthFailure {
  const AuthFailure(this.message, this.statusCode);

  final String message;
  final int statusCode;

  /// True when the cause is server-side (misconfiguration / JWKS outage)
  /// rather than a bad token from the client.
  bool get isServerError => statusCode >= HttpStatus.internalServerError;
}

/// Global middleware: reads an *optional* `Authorization: Bearer <jwt>`, verifies
/// it, and injects an `AuthUser?` into the context (null when the header is
/// absent or the token is invalid). This never rejects a request on its own —
/// routes that must be protected apply [requireAuth] in their own `_middleware`.
///
/// When verification fails it also provides an [AuthFailure] describing why, and
/// logs the reason. Silently dropping the cause used to make a server-side
/// problem (e.g. an unreachable JWKS endpoint) indistinguishable from a client
/// simply not sending a token.
Middleware authProvider(JwtVerifier verifier, {Logger? logger}) {
  final auth = (logger ?? log).tagged('auth');
  return (handler) {
    return (context) async {
      final (user, failure) = await _readUser(context.request, verifier, auth);
      return handler(
        context
            .provide<AuthUser?>(() => user)
            .provide<AuthFailure?>(() => failure),
      );
    };
  };
}

/// Guard for protected route subtrees: rejects any request without a valid user,
/// and re-provides the identity as a non-null `AuthUser` for handlers to read.
///
/// Reports the specific reason when one is known — including a 500 when the
/// failure is a server misconfiguration, so a broken deploy isn't reported to
/// clients as "your token is bad".
Middleware requireAuth() {
  return (handler) {
    return (context) {
      final user = context.read<AuthUser?>();
      if (user != null) {
        return handler(context.provide<AuthUser>(() => user));
      }

      final failure = context.read<AuthFailure?>();
      if (failure != null) {
        return Response.json(
          statusCode: failure.statusCode,
          body: {
            'error': failure.isServerError
                ? 'Authentication unavailable'
                : 'Authentication failed',
            'reason': failure.message,
          },
        );
      }

      return Response.json(
        statusCode: HttpStatus.unauthorized,
        body: {
          'error': 'Authentication required',
          'reason': 'No Authorization: Bearer <token> header was sent.',
        },
      );
    };
  };
}

Future<(AuthUser?, AuthFailure?)> _readUser(
  Request request,
  JwtVerifier verifier,
  Logger auth,
) async {
  final header =
      request.headers['Authorization'] ?? request.headers['authorization'];
  if (header == null) return (null, null);

  final parts = header.split(' ');
  if (parts.length != 2 || parts.first.toLowerCase() != 'bearer') {
    const message = 'Authorization header must be "Bearer <token>".';
    auth.warn(message);
    return (null, const AuthFailure(message, HttpStatus.unauthorized));
  }

  try {
    return (await verifier.verify(parts.last), null);
  } on AuthException catch (e) {
    // Server-side problems are logged loudly; a bad client token is routine.
    if (e.statusCode >= HttpStatus.internalServerError) {
      auth.error('Token verification unavailable: ${e.message}');
    } else {
      auth.debug('Rejected token: ${e.message}');
    }
    return (null, AuthFailure(e.message, e.statusCode));
  }
}
