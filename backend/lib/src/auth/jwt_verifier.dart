import 'dart:convert';
import 'dart:io';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart' as pc;

import 'auth_user.dart';

/// Raised when a token cannot be trusted. Carries the HTTP status the API
/// should surface (401 for bad tokens, 500 for a misconfigured server).
class AuthException implements Exception {
  const AuthException(this.message,
      {this.statusCode = HttpStatus.unauthorized});

  final String message;
  final int statusCode;

  @override
  String toString() => 'AuthException($statusCode): $message';
}

/// Turns a bearer token string into a trusted [AuthUser], or throws
/// [AuthException] if it cannot be verified. Async because key material may be
/// fetched over the network (see [SupabaseJwksVerifier]).
abstract interface class JwtVerifier {
  Future<AuthUser> verify(String token);
}

/// Verifies Supabase access tokens against the project's **JWKS** endpoint
/// (asymmetric "signing keys": ES256 by default, or RS256).
///
/// This is the modern Supabase path: the private signing key never leaves
/// Supabase, keys can be rotated, and the server verifies locally using the
/// public keys published at `<project>/auth/v1/.well-known/jwks.json`. The token
/// header carries a `kid` selecting which published key signed it.
///
/// Keys are cached in memory; the cache is refreshed when it goes stale
/// ([cacheTtl]) or when a token references an unknown `kid` (rotation),
/// rate-limited by [minRefreshInterval] so unknown-kid tokens can't be used to
/// hammer the JWKS endpoint.
class SupabaseJwksVerifier implements JwtVerifier {
  SupabaseJwksVerifier({
    required this.jwksUri,
    http.Client? client,
    this.cacheTtl = const Duration(hours: 1),
    this.minRefreshInterval = const Duration(minutes: 1),
  }) : _client = client ?? http.Client();

  final Uri jwksUri;
  final Duration cacheTtl;
  final Duration minRefreshInterval;
  final http.Client _client;

  Map<String, JWTKey> _keys = {};
  DateTime? _fetchedAt; // last SUCCESSFUL fetch
  DateTime? _lastAttempt; // last fetch attempt (success or failure)
  Future<void>? _inflight;

  @override
  Future<AuthUser> verify(String token) async {
    final header = _decodeHeader(token);
    final kid = header['kid'];
    if (kid is! String || kid.isEmpty) {
      throw const AuthException('Token missing key id (kid)');
    }

    var key = await _keyFor(kid);
    if (key == null) {
      // Unknown kid could mean the signing key was just rotated — try once more
      // with a fresh JWKS (rate-limited inside _refresh).
      await _refresh();
      key = _keys[kid];
    }
    if (key == null) {
      throw AuthException('No matching JWKS key for kid "$kid"');
    }

    final JWT jwt;
    try {
      jwt = JWT.verify(token, key);
    } on JWTExpiredException {
      throw const AuthException('Token expired');
    } on JWTException catch (e) {
      throw AuthException('Invalid token: ${e.message}');
    }
    return _userFromJwt(jwt);
  }

  Future<JWTKey?> _keyFor(String kid) async {
    final stale =
        _fetchedAt == null || DateTime.now().difference(_fetchedAt!) > cacheTtl;
    if (_keys.isEmpty || stale) {
      await _refresh();
    }
    return _keys[kid];
  }

  Future<void> _refresh() {
    final now = DateTime.now();
    final tooSoon = _lastAttempt != null &&
        now.difference(_lastAttempt!) < minRefreshInterval &&
        _keys.isNotEmpty;
    if (tooSoon) return Future.value();
    return _inflight ??= _doFetch().whenComplete(() => _inflight = null);
  }

  Future<void> _doFetch() async {
    _lastAttempt = DateTime.now();
    final http.Response res;
    try {
      res = await _client.get(jwksUri);
    } catch (e) {
      throw AuthException('JWKS fetch failed: $e',
          statusCode: HttpStatus.internalServerError);
    }
    if (res.statusCode != 200) {
      throw AuthException('JWKS fetch failed (HTTP ${res.statusCode})',
          statusCode: HttpStatus.internalServerError);
    }

    final body = jsonDecode(res.body);
    final rawKeys =
        (body is Map && body['keys'] is List) ? body['keys'] as List : const [];
    final parsed = <String, JWTKey>{};
    for (final entry in rawKeys) {
      if (entry is! Map) continue;
      final kid = entry['kid'];
      if (kid is! String) continue;
      final key = _jwkToKey(Map<String, dynamic>.from(entry));
      if (key != null) parsed[kid] = key;
    }
    _keys = parsed;
    _fetchedAt = DateTime.now();
  }
}

/// Legacy Supabase verification: HS256 with the project's shared JWT secret
/// (dashboard → Project Settings → API → JWT Secret), via `SUPABASE_JWT_SECRET`.
/// Prefer [SupabaseJwksVerifier] (signing keys); kept for projects still on the
/// legacy shared secret. Checks signature + expiry; does not enforce `aud`.
class SupabaseJwtVerifier implements JwtVerifier {
  const SupabaseJwtVerifier(this._secret);

  final String _secret;

  @override
  Future<AuthUser> verify(String token) async {
    final JWT jwt;
    try {
      jwt = JWT.verify(token, SecretKey(_secret));
    } on JWTExpiredException {
      throw const AuthException('Token expired');
    } on JWTException catch (e) {
      throw AuthException('Invalid token: ${e.message}');
    }
    return _userFromJwt(jwt);
  }
}

/// Fail-closed verifier used when no secret/JWKS is configured: rejects every
/// token so unauthenticated access is never silently allowed. Surfaced as a
/// server error because the cause is a deploy misconfiguration, not a bad client.
class UnconfiguredVerifier implements JwtVerifier {
  const UnconfiguredVerifier();

  @override
  Future<AuthUser> verify(String token) async => throw const AuthException(
        'Auth is not configured (set SUPABASE_URL or SUPABASE_JWT_SECRET)',
        statusCode: HttpStatus.internalServerError,
      );
}

// --- shared helpers -------------------------------------------------------

/// Maps the claims of an already-verified [JWT] to an [AuthUser], enforcing the
/// invariant that a usable identity has a non-empty `sub`.
AuthUser _userFromJwt(JWT jwt) {
  final payload = jwt.payload;
  if (payload is! Map<String, dynamic>) {
    throw const AuthException('Malformed token payload');
  }
  final sub = payload['sub'];
  if (sub is! String || sub.isEmpty) {
    throw const AuthException('Token missing subject');
  }
  return AuthUser.fromClaims(payload);
}

/// Reads the (unverified) JOSE header so we can select a key by `kid` before
/// verifying the signature.
Map<String, dynamic> _decodeHeader(String token) {
  final JWT decoded;
  try {
    decoded = JWT.decode(token);
  } on JWTException catch (e) {
    throw AuthException('Malformed token: ${e.message}');
  }
  final header = decoded.header;
  if (header == null) throw const AuthException('Token missing header');
  return header;
}

/// Converts a single JWK into a dart_jsonwebtoken public key. Returns null for
/// key types we don't support (they're skipped, not fatal).
JWTKey? _jwkToKey(Map<String, dynamic> jwk) {
  switch (jwk['kty']) {
    case 'EC':
      final params = _ecParams(jwk['crv'] as String?);
      final point = params.curve.createPoint(
        _b64UrlToBigInt(jwk['x'] as String),
        _b64UrlToBigInt(jwk['y'] as String),
      );
      return ECPublicKey.raw(pc.ECPublicKey(point, params));
    case 'RSA':
      return RSAPublicKey.raw(pc.RSAPublicKey(
        _b64UrlToBigInt(jwk['n'] as String),
        _b64UrlToBigInt(jwk['e'] as String),
      ));
    default:
      return null;
  }
}

pc.ECDomainParameters _ecParams(String? crv) {
  switch (crv) {
    case 'P-256':
      return pc.ECCurve_secp256r1();
    case 'P-384':
      return pc.ECCurve_secp384r1();
    case 'P-521':
      return pc.ECCurve_secp521r1();
    default:
      throw AuthException('Unsupported EC curve: $crv');
  }
}

/// Decodes a base64url (unpadded) JWK field into a positive big-endian integer.
BigInt _b64UrlToBigInt(String s) {
  final normalized = s.replaceAll('-', '+').replaceAll('_', '/');
  final padded = normalized.padRight(
    normalized.length + (4 - normalized.length % 4) % 4,
    '=',
  );
  final bytes = base64.decode(padded);
  var result = BigInt.zero;
  for (final byte in bytes) {
    result = (result << 8) | BigInt.from(byte);
  }
  return result;
}
