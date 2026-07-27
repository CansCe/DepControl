// Diagnoses what SMOKE_TOKEN actually contains, without printing the token.
//
//   $env:SMOKE_TOKEN="<paste>"; dart run tool/inspect_token.dart
//
// Prints only non-sensitive metadata: the JOSE header (alg/kid/typ), the
// standard registered claims (iss/aud/exp/iat), and whether the key id matches
// one published by your project's JWKS. The signature, the subject, and the
// email are never printed.
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final token = Platform.environment['SMOKE_TOKEN'];

  if (token == null || token.isEmpty) {
    stderr.writeln('SMOKE_TOKEN is not set.');
    stderr.writeln(r'  $env:SMOKE_TOKEN="<access token>"');
    exit(2);
  }

  stdout.writeln('Length: ${token.length} characters');
  stdout.writeln('Segments (dot-separated): ${token.split('.').length}');
  stdout.writeln('');

  if (_reportNotAToken(token)) exit(1);

  final parts = token.split('.');
  if (parts.length != 3) {
    stdout.writeln('NOT A JWT: expected 3 dot-separated segments, '
        'found ${parts.length}.');
    stdout.writeln('A JWT looks like  eyJhbGci....eyJzdWIi....<signature>');
    exit(1);
  }

  final header = _decodeJson(parts[0], 'header');
  if (header == null) exit(1);

  stdout.writeln('Header:');
  stdout.writeln('  alg: ${header['alg']}   typ: ${header['typ']}');
  stdout.writeln('  kid: ${header['kid'] ?? '(none)'}');
  stdout.writeln('');

  final payload = _decodeJson(parts[1], 'payload');
  if (payload == null) exit(1);

  stdout.writeln('Claims (identifying values withheld):');
  stdout.writeln('  iss: ${payload['iss']}');
  stdout.writeln('  aud: ${payload['aud']}');
  stdout.writeln('  role: ${payload['role']}');
  stdout.writeln('  sub present: ${payload['sub'] != null}');

  final exp = payload['exp'];
  if (exp is int) {
    final expiry = DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
    final expired = expiry.isBefore(DateTime.now().toUtc());
    stdout.writeln('  exp: $expiry ${expired ? '(EXPIRED)' : '(valid)'}');
    if (expired) {
      stdout.writeln('');
      stdout.writeln('This token has expired - sign in again for a fresh one.');
    }
  }
  stdout.writeln('');

  await _checkAgainstJwks(header['kid'] as String?, header['alg'] as String?);
}

/// Recognises the things people paste by mistake. Returns true if it reported
/// a definitive problem.
bool _reportNotAToken(String token) {
  if (token.contains('-----BEGIN')) {
    stdout.writeln('This is a PEM KEY, not an access token.');
    stdout.writeln('A signing key signs tokens; it is not one. The server '
        'already fetches the public half from your JWKS.');
    return true;
  }
  if (token.startsWith('sb_publishable_') || token.startsWith('sb_secret_')) {
    stdout.writeln('This is a Supabase API KEY, not a user access token.');
    stdout.writeln('API keys identify the project; access tokens identify a '
        'signed-in user. /me needs the latter.');
    return true;
  }
  if (token.trimLeft().startsWith('{')) {
    stdout.writeln('This is JSON (probably a JWK or a session object).');
    stdout.writeln('If it is a session object, the value you want is its '
        '"access_token" field.');
    return true;
  }
  if (!token.startsWith('eyJ')) {
    stdout.writeln('Does not start with "eyJ", so it is not a JWT.');
    stdout.writeln('Every JWT begins with a base64url-encoded {" - i.e. eyJ.');
    return true;
  }
  return false;
}

Map<String, dynamic>? _decodeJson(String segment, String label) {
  try {
    final normalized = base64Url.normalize(segment);
    final decoded = utf8.decode(base64Url.decode(normalized));
    final json = jsonDecode(decoded);
    if (json is Map<String, dynamic>) return json;
    stdout.writeln('The $label segment is not a JSON object.');
    return null;
  } catch (e) {
    stdout.writeln('Could not decode the $label segment: $e');
    stdout.writeln('The token is malformed or was truncated when copied.');
    return null;
  }
}

Future<void> _checkAgainstJwks(String? kid, String? alg) async {
  final base = Platform.environment['SUPABASE_URL'];
  if (base == null || base.isEmpty) {
    stdout.writeln('SUPABASE_URL not set - skipping the JWKS check.');
    return;
  }
  if (kid == null) {
    stdout.writeln('Token has no "kid", so it cannot be matched to a JWKS key.');
    stdout.writeln('Legacy HS256 tokens have no kid and need '
        'SUPABASE_JWT_SECRET instead.');
    return;
  }

  final trimmed = base.endsWith('/')
      ? base.substring(0, base.length - 1)
      : base;
  final uri = Uri.parse('$trimmed/auth/v1/.well-known/jwks.json');

  try {
    final client = HttpClient();
    final response = await (await client.getUrl(uri)).close();
    final body = await response.transform(utf8.decoder).join();
    client.close();

    final keys = (jsonDecode(body) as Map<String, dynamic>)['keys'] as List?;
    final published = (keys ?? [])
        .whereType<Map<String, dynamic>>()
        .map((k) => k['kid'])
        .toList();

    stdout.writeln('JWKS published key ids: $published');
    if (published.contains(kid)) {
      stdout.writeln('MATCH - this token was signed by a current key ($alg).');
      stdout.writeln('If the API still rejects it, it is expired or altered.');
    } else {
      stdout.writeln('NO MATCH - no published key has this kid.');
      stdout.writeln('The token came from a different project, or the signing '
          'key was rotated after it was issued.');
    }
  } catch (e) {
    stdout.writeln('Could not fetch JWKS ($e).');
  }
}
