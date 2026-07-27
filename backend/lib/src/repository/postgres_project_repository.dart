import 'dart:convert';

import 'package:postgres/postgres.dart';
import 'package:shared/shared.dart';

import 'project_repository.dart';

/// Postgres-backed [ProjectRepository] (Phase 3). Persists tracked projects and
/// their latest dependency report to Supabase Postgres, so state survives
/// restarts. The dependency graph is stored as JSONB (`dep_reports.nodes`).
///
/// Backed by a lazily-opened connection [Pool] so concurrent Dart Frog requests
/// don't contend on a single connection. The pool opens connections on first
/// use, which keeps [Deps] construction synchronous.
class PostgresProjectRepository implements ProjectRepository {
  PostgresProjectRepository(this._pool);

  /// Builds a repository from a `postgres://user:pass@host:port/db` URL, as
  /// provided by Supabase (Project Settings → Database → Connection string).
  ///
  /// TLS is required by Supabase, so `sslmode` defaults to `require`; pass
  /// `?sslmode=disable` in the URL for a plaintext local Postgres.
  factory PostgresProjectRepository.fromUrl(String url) {
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

    return PostgresProjectRepository(
      Pool.withEndpoints(
        [endpoint],
        settings: PoolSettings(sslMode: sslMode, maxConnectionCount: 5),
      ),
    );
  }

  final Pool _pool;

  /// Closes the underlying connection pool. Call on server shutdown.
  Future<void> close() => _pool.close();

  @override
  Future<Project> add(Project project) async {
    if (project.ownerId == null) {
      throw ArgumentError('Project.ownerId is required to persist a project');
    }
    await _pool.execute(
      Sql.named('''
        insert into projects (id, git_url, name, owner_id, ref, added_at,
                              last_checked_at)
        values (@id:uuid, @gitUrl:text, @name:text, @ownerId:uuid, @ref:text,
                @addedAt:timestamptz, @lastCheckedAt:timestamptz)
        on conflict (id) do update set
          git_url         = excluded.git_url,
          name            = excluded.name,
          ref             = excluded.ref,
          last_checked_at = excluded.last_checked_at
        where projects.owner_id = excluded.owner_id
      '''),
      parameters: {
        'id': project.id,
        'gitUrl': project.gitUrl,
        'name': project.name,
        'ownerId': project.ownerId,
        'ref': project.ref,
        'addedAt': project.addedAt ?? DateTime.now().toUtc(),
        'lastCheckedAt': project.lastCheckedAt,
      },
    );
    return project;
  }

  @override
  Future<List<Project>> allForOwner(String ownerId) async {
    final result = await _pool.execute(
      Sql.named(
        'select id, git_url, name, owner_id, ref, added_at, last_checked_at '
        'from projects where owner_id = @ownerId:uuid order by added_at desc',
      ),
      parameters: {'ownerId': ownerId},
    );
    return result.map((row) => _projectFromRow(row.toColumnMap())).toList();
  }

  @override
  Future<Project?> byId(String id, {required String ownerId}) async {
    final result = await _pool.execute(
      Sql.named(
        'select id, git_url, name, owner_id, ref, added_at, last_checked_at '
        'from projects where id = @id:uuid and owner_id = @ownerId:uuid',
      ),
      parameters: {'id': id, 'ownerId': ownerId},
    );
    if (result.isEmpty) return null;
    return _projectFromRow(result.first.toColumnMap());
  }

  @override
  Future<void> saveReport(DepReport report) async {
    await _pool.execute(
      Sql.named('''
        insert into dep_reports (project_id, generated_at, nodes)
        values (@projectId:uuid, @generatedAt:timestamptz, @nodes:jsonb)
        on conflict (project_id) do update set
          generated_at = excluded.generated_at,
          nodes        = excluded.nodes
      '''),
      parameters: {
        'projectId': report.projectId,
        'generatedAt': report.generatedAt,
        'nodes': report.nodes.map((n) => n.toJson()).toList(),
      },
    );
  }

  @override
  Future<DepReport?> reportFor(String projectId) async {
    final result = await _pool.execute(
      Sql.named('select project_id, generated_at, nodes '
          'from dep_reports where project_id = @id:uuid'),
      parameters: {'id': projectId},
    );
    if (result.isEmpty) return null;
    final row = result.first.toColumnMap();

    // jsonb decodes to a parsed Dart structure (List of node maps).
    final rawNodes = row['nodes'];
    final nodeList = rawNodes is String
        ? (jsonDecodeList(rawNodes))
        : (rawNodes as List? ?? const []);

    return DepReport(
      projectId: row['project_id'].toString(),
      generatedAt: row['generated_at'] as DateTime,
      nodes: nodeList
          .map((e) => DepNode.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
    );
  }

  Project _projectFromRow(Map<String, dynamic> row) => Project(
        id: row['id'].toString(),
        gitUrl: row['git_url'] as String,
        name: row['name'] as String,
        ownerId: row['owner_id']?.toString(),
        ref: (row['ref'] as String?) ?? 'HEAD',
        addedAt: row['added_at'] as DateTime?,
        lastCheckedAt: row['last_checked_at'] as DateTime?,
      );
}

/// Fallback for drivers/paths that surface jsonb as a raw string.
List<dynamic> jsonDecodeList(String s) {
  final decoded = _json.decode(s);
  return decoded is List ? decoded : const [];
}

const _json = JsonCodec();
