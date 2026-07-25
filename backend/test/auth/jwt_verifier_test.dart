import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/auth/jwt_verifier.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:test/test.dart';

void main() {
  group('SupabaseJwtVerifier (legacy HS256)', () {
    const secret = 'super-secret-test-key';
    final verifier = SupabaseJwtVerifier(secret);

    String token(
      Map<String, dynamic> claims, {
      String signWith = secret,
      Duration? expiresIn = const Duration(hours: 1),
    }) {
      return JWT(claims).sign(SecretKey(signWith), expiresIn: expiresIn);
    }

    test('accepts a valid token and maps Supabase claims', () async {
      final user = await verifier.verify(token({
        'sub': 'user-123',
        'email': 'a@b.com',
        'role': 'authenticated',
      }));

      expect(user, isA<AuthUser>());
      expect(user.id, 'user-123');
      expect(user.email, 'a@b.com');
      expect(user.role, 'authenticated');
    });

    test('defaults role to authenticated when absent', () async {
      final user = await verifier.verify(token({'sub': 'user-123'}));
      expect(user.role, 'authenticated');
      expect(user.email, isNull);
    });

    test('rejects a token signed with the wrong secret', () {
      return expectLater(
        verifier.verify(token({'sub': 'x'}, signWith: 'other-secret')),
        throwsA(isA<AuthException>()),
      );
    });

    test('rejects an expired token', () {
      final expired =
          token({'sub': 'x'}, expiresIn: const Duration(seconds: -1));
      return expectLater(
        verifier.verify(expired),
        throwsA(isA<AuthException>()
            .having((e) => e.message, 'message', contains('expired'))),
      );
    });

    test('rejects a token missing sub', () {
      return expectLater(
        verifier.verify(token({'email': 'a@b.com'})),
        throwsA(isA<AuthException>()),
      );
    });

    test('rejects a structurally invalid token', () {
      return expectLater(
        verifier.verify('not-a-jwt'),
        throwsA(isA<AuthException>()),
      );
    });
  });

  group('SupabaseJwksVerifier (signing keys, ES256)', () {
    final jwksUri = Uri.parse('https://proj.supabase.co/auth/v1/jwks');
    late _EcKey key1;
    late _EcKey key2;

    setUp(() {
      key1 = _EcKey.generate('key-1');
      key2 = _EcKey.generate('key-2');
    });

    /// Serves a JWKS containing [key1] only, counting fetches.
    ({MockClient client, int Function() fetches}) jwksServing(_EcKey key) {
      var fetches = 0;
      final client = MockClient((req) async {
        if (req.url == jwksUri) {
          fetches++;
          return http.Response(
            jsonEncode({
              'keys': [key.jwk()]
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('not found', 404);
      });
      return (client: client, fetches: () => fetches);
    }

    test('verifies a token signed by the published key', () async {
      final served = jwksServing(key1);
      final verifier =
          SupabaseJwksVerifier(jwksUri: jwksUri, client: served.client);

      final token = key1.signToken({
        'sub': 'user-9',
        'email': 'e@x.com',
        'role': 'authenticated',
      });

      final user = await verifier.verify(token);
      expect(user.id, 'user-9');
      expect(user.email, 'e@x.com');
      expect(user.role, 'authenticated');
    });

    test('caches keys — a second verify does not refetch JWKS', () async {
      final served = jwksServing(key1);
      final verifier =
          SupabaseJwksVerifier(jwksUri: jwksUri, client: served.client);

      await verifier.verify(key1.signToken({'sub': 'a'}));
      await verifier.verify(key1.signToken({'sub': 'b'}));

      expect(served.fetches(), 1);
    });

    test('rejects a token whose kid is not in the JWKS', () {
      final served = jwksServing(key1);
      final verifier =
          SupabaseJwksVerifier(jwksUri: jwksUri, client: served.client);

      // Signed by key2, whose kid is absent from the served JWKS.
      return expectLater(
        verifier.verify(key2.signToken({'sub': 'x'})),
        throwsA(isA<AuthException>()
            .having((e) => e.message, 'message', contains('kid'))),
      );
    });

    test('rejects a token whose signature does not match the published key',
        () {
      final served = jwksServing(key1);
      final verifier =
          SupabaseJwksVerifier(jwksUri: jwksUri, client: served.client);

      // Sign with key2's private key but advertise key1's kid (which IS served),
      // so the key is found but the signature check must fail.
      final forged = key2.signToken({'sub': 'x'}, overrideKid: key1.kid);
      return expectLater(
        verifier.verify(forged),
        throwsA(isA<AuthException>()),
      );
    });

    test('rejects when the JWKS endpoint is unavailable', () {
      final client = MockClient((_) async => http.Response('boom', 500));
      final verifier = SupabaseJwksVerifier(jwksUri: jwksUri, client: client);

      return expectLater(
        verifier.verify(key1.signToken({'sub': 'x'})),
        throwsA(isA<AuthException>()),
      );
    });
  });

  group('UnconfiguredVerifier', () {
    test('rejects everything with a 500 status', () {
      return expectLater(
        const UnconfiguredVerifier().verify('anything'),
        throwsA(isA<AuthException>()
            .having((e) => e.statusCode, 'statusCode', 500)),
      );
    });
  });
}

/// Test helper: a P-256 keypair that can publish itself as a JWK and sign
/// ES256 tokens, mirroring what Supabase's signing keys do.
class _EcKey {
  _EcKey(this.kid, this._public, this._private);

  factory _EcKey.generate(String kid) {
    final keyParams = pc.ECKeyGeneratorParameters(pc.ECCurve_secp256r1());
    final random = pc.FortunaRandom();
    final seedSource = Random.secure();
    final seed =
        Uint8List.fromList(List.generate(32, (_) => seedSource.nextInt(256)));
    random.seed(pc.KeyParameter(seed));
    final generator = pc.ECKeyGenerator()
      ..init(pc.ParametersWithRandom(keyParams, random));
    final pair = generator.generateKeyPair();
    return _EcKey(
      kid,
      pair.publicKey as pc.ECPublicKey,
      pair.privateKey as pc.ECPrivateKey,
    );
  }

  final String kid;
  final pc.ECPublicKey _public;
  final pc.ECPrivateKey _private;

  Map<String, dynamic> jwk() {
    final q = _public.Q!;
    return {
      'kty': 'EC',
      'crv': 'P-256',
      'kid': kid,
      'alg': 'ES256',
      'x': _b64url(_bigIntToBytes(q.x!.toBigInteger()!, 32)),
      'y': _b64url(_bigIntToBytes(q.y!.toBigInteger()!, 32)),
    };
  }

  String signToken(Map<String, dynamic> claims, {String? overrideKid}) {
    return JWT(claims, header: {'kid': overrideKid ?? kid}).sign(
      ECPrivateKey.raw(_private),
      algorithm: JWTAlgorithm.ES256,
    );
  }
}

Uint8List _bigIntToBytes(BigInt value, int length) {
  final result = Uint8List(length);
  var v = value;
  final mask = BigInt.from(0xff);
  for (var i = length - 1; i >= 0; i--) {
    result[i] = (v & mask).toInt();
    v = v >> 8;
  }
  return result;
}

String _b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
