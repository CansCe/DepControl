import 'dart:io';

import 'auth/jwt_verifier.dart';
import 'repository/postgres_project_repository.dart';
import 'repository/project_repository.dart';
import 'services/git_fetcher.dart';
import 'services/logger.dart';
import 'services/pub_api_client.dart';
import 'services/pubspec_analyzer.dart';
import 'services/resolver.dart';
import 'services/upgrade_inspector.dart';

/// Tiny process-wide service locator, provided into Dart Frog request context
/// by `routes/_middleware.dart`. Swap the repository here for Postgres in
/// Phase 3.
class Deps {
  /// Builds the production graph from the environment.
  factory Deps() {
    final pubApi = PubApiClient();
    return Deps._(
      repository: _buildRepository(),
      gitFetcher: GitFetcher(),
      pubApi: pubApi,
      analyzer: PubspecAnalyzer(pubApi),
      resolver: Resolver(pubApi),
      inspector: UpgradeInspector(pubApi),
      authVerifier: _buildVerifier(),
    );
  }

  /// Builds a [Deps] from explicit collaborators, for tests.
  ///
  /// Nothing here touches the environment, the network, or a database, so route
  /// tests can exercise handlers against in-memory fakes.
  factory Deps.forTesting({
    required ProjectRepository repository,
    required GitFetcher gitFetcher,
    required PubspecAnalyzer analyzer,
    PubApiClient? pubApi,
    Resolver? resolver,
    UpgradeInspector? inspector,
    JwtVerifier authVerifier = const UnconfiguredVerifier(),
  }) {
    final api = pubApi ?? PubApiClient();
    return Deps._(
      repository: repository,
      gitFetcher: gitFetcher,
      pubApi: api,
      analyzer: analyzer,
      resolver: resolver ?? Resolver(api),
      inspector: inspector ?? UpgradeInspector(api),
      authVerifier: authVerifier,
    );
  }

  Deps._({
    required this.repository,
    required this.gitFetcher,
    required this.pubApi,
    required this.analyzer,
    required this.resolver,
    required this.inspector,
    required this.authVerifier,
  });

  final ProjectRepository repository;
  final GitFetcher gitFetcher;
  final PubApiClient pubApi;
  final Resolver resolver;
  final UpgradeInspector inspector;
  final JwtVerifier authVerifier;
  final PubspecAnalyzer analyzer;

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
    final db = log.tagged('db');
    final url = Platform.environment['DATABASE_URL'];
    if (url != null && url.isNotEmpty) {
      try {
        final repo = PostgresProjectRepository.fromUrl(url);
        db.info('Using Postgres repository (DATABASE_URL).');
        return repo;
      } catch (e) {
        // A malformed DATABASE_URL used to blow up lazily on the first request,
        // taking down every route with an opaque stack trace. In development,
        // report it clearly and keep serving from memory; in production, fail
        // fast rather than silently running without persistence.
        db.error('DATABASE_URL is unusable: $e');
        if (!log.isDevelopment) rethrow;
        db.warn(
          'Falling back to the in-memory repository so the dev server can '
          'still start. Fix DATABASE_URL in backend/.env to persist data.',
        );
        return InMemoryProjectRepository();
      }
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
