import 'dart:convert';

import 'package:postgres/postgres.dart';
import 'package:shared/shared.dart';

import 'postgres_pool.dart';
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

  /// Builds a repository owning a pool of its own, from a
  /// `postgres://user:pass@host:port/db` URL.
  ///
  /// The server shares one pool across its stores instead — see `Deps` — so
  /// this is for callers that only need the repository, such as a CLI or an
  /// integration test.
  factory PostgresProjectRepository.fromUrl(String url) =>
      PostgresProjectRepository(postgresPoolFromUrl(url));

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

  static const _columns = 'id, git_url, name, owner_id, ref, added_at, '
      'last_checked_at, archived_at';

  @override
  Future<List<Project>> allForOwner(
    String ownerId, {
    bool includeArchived = false,
  }) async {
    final result = await _pool.execute(
      Sql.named(
        'select $_columns from projects where owner_id = @ownerId:uuid '
        '${includeArchived ? '' : 'and archived_at is null '}'
        'order by added_at desc',
      ),
      parameters: {'ownerId': ownerId},
    );
    return result.map((row) => _projectFromRow(row.toColumnMap())).toList();
  }

  @override
  Future<Project?> byId(String id, {required String ownerId}) async {
    final result = await _pool.execute(
      Sql.named(
        'select $_columns from projects '
        'where id = @id:uuid and owner_id = @ownerId:uuid',
      ),
      parameters: {'id': id, 'ownerId': ownerId},
    );
    if (result.isEmpty) return null;
    return _projectFromRow(result.first.toColumnMap());
  }

  @override
  Future<Project?> setArchived(
    String id, {
    required String ownerId,
    required bool archived,
  }) async {
    // Ownership is in the WHERE clause rather than checked first, so there is
    // no window between the check and the write.
    final result = await _pool.execute(
      Sql.named(
        'update projects set archived_at = @archivedAt:timestamptz '
        'where id = @id:uuid and owner_id = @ownerId:uuid '
        'returning $_columns',
      ),
      parameters: {
        'id': id,
        'ownerId': ownerId,
        'archivedAt': archived ? DateTime.now().toUtc() : null,
      },
    );
    if (result.isEmpty) return null;
    return _projectFromRow(result.first.toColumnMap());
  }

  @override
  Future<bool> delete(String id, {required String ownerId}) async {
    // The report is removed by the foreign key's ON DELETE CASCADE.
    final result = await _pool.execute(
      Sql.named(
        'delete from projects '
        'where id = @id:uuid and owner_id = @ownerId:uuid returning id',
      ),
      parameters: {'id': id, 'ownerId': ownerId},
    );
    return result.isNotEmpty;
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
        archivedAt: row['archived_at'] as DateTime?,
      );
}

/// Fallback for drivers/paths that surface jsonb as a raw string.
List<dynamic> jsonDecodeList(String s) {
  final decoded = _json.decode(s);
  return decoded is List ? decoded : const [];
}

const _json = JsonCodec();
