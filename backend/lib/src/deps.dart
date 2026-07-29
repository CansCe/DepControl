import 'auth/jwt_verifier.dart';
import 'env.dart';
import 'repository/api_diff_store.dart';
import 'repository/license_policy_store.dart';
import 'repository/postgres_api_diff_store.dart';
import 'repository/postgres_license_policy_store.dart';
import 'repository/postgres_pool.dart';
import 'repository/postgres_project_repository.dart';
import 'repository/project_repository.dart';
import 'ecosystem/ecosystems.dart';
import 'services/git_fetcher.dart';
import 'services/logger.dart';
import 'services/pub_api_client.dart';
import 'services/dependency_analyzer.dart';
import 'services/rate_limiter.dart';
import 'services/remediation_planner.dart';
import 'services/resolver.dart';
import 'services/upgrade_inspector.dart';

/// Tiny process-wide service locator, provided into Dart Frog request context
/// by `routes/_middleware.dart`. Everything the environment decides — which
/// persistence backend, which JWT verifier — is decided once, here.
class Deps {
  /// Builds the production graph from the environment.
  factory Deps() {
    final pubApi = PubApiClient();
    final ecosystems = Ecosystems.standard(pub: pubApi);
    final stores = _buildStores();
    return Deps._(
      repository: stores.repository,
      apiDiffs: stores.apiDiffs,
      licensePolicies: stores.licensePolicies,
      ecosystems: ecosystems,
      gitFetcher: GitFetcher(ecosystems: ecosystems),
      pubApi: pubApi,
      analyzer: DependencyAnalyzer(ecosystems),
      // Simulation, remediation and upgrade detail still answer only for Dart:
      // each reads a single manifest and writes a pubspec diff. They take the
      // Dart ecosystem explicitly rather than the first configured one, so
      // adding another does not silently repoint them.
      resolver: Resolver(ecosystems.require('dart')),
      inspector: UpgradeInspector(pubApi),
      authVerifier: _buildVerifier(),
      limiter: _buildLimiter(),
    );
  }

  /// Builds a [Deps] from explicit collaborators, for tests.
  ///
  /// Nothing here touches the environment, the network, or a database, so route
  /// tests can exercise handlers against in-memory fakes.
  factory Deps.forTesting({
    required ProjectRepository repository,
    required GitFetcher gitFetcher,
    required DependencyAnalyzer analyzer,
    Ecosystems? ecosystems,
    ApiDiffStore? apiDiffs,
    LicensePolicyStore? licensePolicies,
    PubApiClient? pubApi,
    Resolver? resolver,
    UpgradeInspector? inspector,
    JwtVerifier authVerifier = const UnconfiguredVerifier(),
    RateLimiter? limiter,
  }) {
    final api = pubApi ?? PubApiClient();
    final eco = ecosystems ?? Ecosystems.standard(pub: api);
    return Deps._(
      repository: repository,
      apiDiffs: apiDiffs ?? InMemoryApiDiffStore(),
      licensePolicies: licensePolicies ?? InMemoryLicensePolicyStore(),
      ecosystems: eco,
      gitFetcher: gitFetcher,
      pubApi: api,
      analyzer: analyzer,
      resolver: resolver ?? Resolver(eco.require('dart')),
      inspector: inspector ?? UpgradeInspector(api),
      authVerifier: authVerifier,
      limiter: limiter,
    );
  }

  Deps._({
    required this.repository,
    required this.apiDiffs,
    required this.licensePolicies,
    required this.ecosystems,
    required this.gitFetcher,
    required this.pubApi,
    required this.analyzer,
    required this.resolver,
    required this.inspector,
    required this.authVerifier,
    required this.limiter,
  });

  final ProjectRepository repository;

  /// Public-API comparisons computed out of process by `tools/api_differ`. The
  /// server only ever reads from here, and records what it could not find.
  final ApiDiffStore apiDiffs;

  /// Each user's rules about which licenses their code may depend on. Scoped to
  /// the owner, because a license policy is a statement about one organisation.
  final LicensePolicyStore licensePolicies;

  /// Every ecosystem this server can scan. Shared, because each holds a
  /// registry client with its own connection pool.
  final Ecosystems ecosystems;

  final GitFetcher gitFetcher;
  final PubApiClient pubApi;
  final Resolver resolver;

  /// Plans verified fixes for a report's advisories. Built from [resolver],
  /// since a remediation is only offered once it has been resolved.
  RemediationPlanner get planner => RemediationPlanner(resolver);

  final UpgradeInspector inspector;
  final JwtVerifier authVerifier;
  final DependencyAnalyzer analyzer;

  /// Per-user limit on the endpoints that fetch repositories and query pub.dev.
  /// Null when limiting is switched off, which tests and local dev do.
  final RateLimiter? limiter;

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
    final env = readEnvironment();

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
  ///
  /// Both stores come from one connection pool, so the process holds a single
  /// connection budget however many stores are added later.
  static ({
    ProjectRepository repository,
    ApiDiffStore apiDiffs,
    LicensePolicyStore licensePolicies,
  }) _buildStores() {
    final db = log.tagged('db');
    final url = readEnvironment()['DATABASE_URL'];
    if (url != null && url.isNotEmpty) {
      try {
        final pool = postgresPoolFromUrl(url);
        db.info('Using Postgres repository (DATABASE_URL).');
        return (
          repository: PostgresProjectRepository(pool),
          apiDiffs: PostgresApiDiffStore(pool),
          licensePolicies: PostgresLicensePolicyStore(pool),
        );
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
        return _inMemoryStores();
      }
    }
    db.warn(
      'DATABASE_URL not set — using in-memory repository. State is lost '
      'on restart; set DATABASE_URL to persist to Supabase Postgres.',
    );
    return _inMemoryStores();
  }

  /// Builds the per-user rate limiter, reporting what it settled on: a limit
  /// nobody knows about is a limit that gets blamed on the network.
  static RateLimiter? _buildLimiter() {
    final rate = log.tagged('rate');
    final limiter = RateLimiter.fromEnvironment(readEnvironment());

    if (limiter == null) {
      rate.warn(
        'Rate limiting is off (RATE_LIMIT_PER_MINUTE=0). One signed-in user '
        'can drive unbounded outbound traffic from this server.',
      );
      return null;
    }

    rate.info(
      'Limiting repository/pub.dev work to a burst of ${limiter.burst} per '
      'user, refilling one every ${limiter.refill.inMilliseconds}ms.',
    );
    return limiter;
  }

  static ({
    ProjectRepository repository,
    ApiDiffStore apiDiffs,
    LicensePolicyStore licensePolicies,
  }) _inMemoryStores() => (
        repository: InMemoryProjectRepository(),
        apiDiffs: InMemoryApiDiffStore(),
        licensePolicies: InMemoryLicensePolicyStore(),
      );

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
