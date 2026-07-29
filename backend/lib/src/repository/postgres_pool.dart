import 'package:postgres/postgres.dart';

import '../env.dart';

/// Builds a connection [Pool] from a `postgres://user:pass@host:port/db` URL,
/// as provided by Supabase (Project Settings → Database → Connection string).
///
/// One pool serves every Postgres-backed store in the process — the project
/// repository and the API-diff store share it, since a pooler has a connection
/// budget and neither is busy enough to warrant its own.
///
/// The pool opens connections lazily on first use, which keeps building the
/// service graph synchronous.
///
/// TLS is required by Supabase, so `sslmode` defaults to `require`; pass
/// `?sslmode=disable` in the URL for a plaintext local Postgres.
Pool<void> postgresPoolFromUrl(String rawUrl) {
  // Belt and braces: callers should read config through `readEnvironment`, but
  // this is also reachable from tools and tests holding a raw string.
  final url = unwrapEnvValue(rawUrl);

  // The .env.example ships a `[YOUR-DB-PASSWORD]` placeholder. Catch it
  // explicitly: `Uri.parse` would otherwise fail deep in the stack with an
  // opaque "Invalid character" FormatException.
  if (url.contains('[') || url.contains(']')) {
    throw ArgumentError(
      'DATABASE_URL still contains a placeholder (e.g. [YOUR-DB-PASSWORD]). '
      'Replace it with the real password from the Supabase dashboard: '
      'Project Settings -> Database -> Connection string. '
      'If the password itself contains special characters (@ : / ? # []), '
      'URL-encode it.',
    );
  }

  final Uri uri;
  try {
    uri = Uri.parse(url);
  } on FormatException catch (e) {
    throw ArgumentError(
      'DATABASE_URL is not a valid URL (${e.message}). If your password '
      'contains special characters (@ : / ? # []), URL-encode it.',
    );
  }

  if (uri.scheme != 'postgres' && uri.scheme != 'postgresql') {
    throw ArgumentError(
      'DATABASE_URL must be a postgres:// URL (got scheme "${uri.scheme}")',
    );
  }

  final userInfo = uri.userInfo.split(':');
  final endpoint = Endpoint(
    host: uri.host,
    port: uri.hasPort ? uri.port : 5432,
    database: uri.pathSegments.isNotEmpty && uri.pathSegments.first.isNotEmpty
        ? uri.pathSegments.first
        : 'postgres',
    username: userInfo.isNotEmpty && userInfo.first.isNotEmpty
        ? Uri.decodeComponent(userInfo.first)
        : null,
    password: userInfo.length > 1
        ? Uri.decodeComponent(userInfo.sublist(1).join(':'))
        : null,
  );

  final sslMode = switch (uri.queryParameters['sslmode']) {
    'disable' => SslMode.disable,
    'verify-full' || 'verify-ca' => SslMode.verifyFull,
    _ => SslMode.require,
  };

  return Pool.withEndpoints(
    [endpoint],
    settings: PoolSettings(sslMode: sslMode, maxConnectionCount: 5),
  );
}

