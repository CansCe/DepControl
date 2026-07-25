import 'dart:io';

import 'auth/jwt_verifier.dart';
import 'repository/postgres_project_repository.dart';
import 'repository/project_repository.dart';
import 'services/git_fetcher.dart';
import 'services/logger.dart';
import 'services/pub_api_client.dart';
import 'services/pubspec_analyzer.dart';
import 'services/resolver.dart';

/// Tiny process-wide service locator, provided into Dart Frog request context
/// by `routes/_middleware.dart`. Swap the repository here for Postgres in
/// Phase 3.
class Deps {
  Deps()
      : repository = _buildRepository(),
        gitFetcher = GitFetcher(),
        pubApi = PubApiClient(),
        resolver = const Resolver(),
        authVerifier = _buildVerifier() {
    analyzer = PubspecAnalyzer(pubApi);
  }

  final ProjectRepository repository;
  final GitFetcher gitFetcher;
  final PubApiClient pubApi;
  final Resolver resolver;
  final JwtVerifier authVerifier;
  late final PubspecAnalyzer analyzer;

  /// Builds the JWT verifier from the environment, preferring modern Supabase
  /// **signing keys** (asymmetric, verified against the project JWKS) over the
  /// legacy HS256 shared secret. Fails closed (rejects all tokens) with a
  /// startup warning when nothing is configured, so a misconfigured deploy never
  /// silently exposes protected routes.
  ///
  /// Config precedence:
  ///   1. `SUPABASE_JWKS_URL` — explicit JWKS endpoint, or
  ///      `SUPABASE_URL` — derives `<url>/auth/v1/.well-known/jwks.json`.
  ///   2. `SUPABASE_JWT_SECRET` — legacy HS256 shared secret.
  static JwtVerifier _buildVerifier() {
    final env = Platform.environment;

    final jwksUrl =
        env['SUPABASE_JWKS_URL'] ?? _jwksFromSupabaseUrl(env['SUPABASE_URL']);
    if (jwksUrl != null) {
      return SupabaseJwksVerifier(jwksUri: Uri.parse(jwksUrl));
    }

    final secret = env['SUPABASE_JWT_SECRET'];
    if (secret != null && secret.isNotEmpty) {
      log.tagged('auth').warn(
            'Using legacy HS256 shared-secret verification. Prefer signing '
            'keys: set SUPABASE_URL (or SUPABASE_JWKS_URL).',
          );
      return SupabaseJwtVerifier(secret);
    }

    log.tagged('auth').warn(
          'No auth configured (set SUPABASE_URL or SUPABASE_JWT_SECRET) — '
          'protected routes will reject all requests.',
        );
    return const UnconfiguredVerifier();
  }

  /// Chooses the persistence backend from the environment: Postgres when
  /// `DATABASE_URL` is set (Phase 3), otherwise the in-memory scaffold. The
  /// in-memory fallback keeps local dev working before a database is wired up,
  /// but its state is lost on every restart — a warning makes that explicit.
  static ProjectRepository _buildRepository() {
    final url = Platform.environment['DATABASE_URL'];
    if (url != null && url.isNotEmpty) {
      log.tagged('db').info('Using Postgres repository (DATABASE_URL).');
      return PostgresProjectRepository.fromUrl(url);
    }
    log.tagged('db').warn(
          'DATABASE_URL not set — using in-memory repository. State is lost '
          'on restart; set DATABASE_URL to persist to Supabase Postgres.',
        );
    return InMemoryProjectRepository();
  }

  static String? _jwksFromSupabaseUrl(String? base) {
    if (base == null || base.isEmpty) return null;
    final trimmed =
        base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    return '$trimmed/auth/v1/.well-known/jwks.json';
  }
}

/// Single shared instance for the scaffold (in-memory state must survive
/// across requests).
final deps = Deps();
