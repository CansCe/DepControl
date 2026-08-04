import 'dart:convert';

import 'package:postgres/postgres.dart';
import 'package:shared/shared.dart';

import 'postgres_pool.dart';
import 'report_digest.dart';
import 'project_repository.dart';

/// Postgres-backed [ProjectRepository] (Phase 3). Persists tracked projects and
/// the history of their dependency reports to Supabase Postgres, so state
/// survives restarts. Each dependency graph is stored as JSONB
/// (`dep_report_revisions.nodes`).
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

  /// Every owner with at least one project that is not archived.
  ///
  /// The one read in this class that is *not* scoped to an owner, and it is
  /// deliberately not on [ProjectRepository]. That interface takes an owner id
  /// on every method so no route can serve somebody else's registry by
  /// forgetting to filter; a scheduled sweep has to cut across all of them, and
  /// putting the capability on the interface would put it within reach of a
  /// request handler. Only `tool/rescan.dart` calls this, holding the database
  /// credential rather than a JWT.
  Future<List<String>> ownersWithActiveProjects() async {
    final result = await _pool.execute(
      'select distinct owner_id from projects where archived_at is null',
    );
    return [for (final row in result) row[0].toString()];
  }

  /// The revision summary columns, in the order [_revisionFromRow] reads them.
  static const _revisionColumns = 'id, project_id, first_seen_at, last_seen_at, '
      'content_digest, commit_sha';

  /// The revision counts, computed from the stored node list in Postgres.
  ///
  /// Shared between reading a history and writing a sighting so the two cannot
  /// answer differently — the sighting refreshes `nodes`, so counting the report
  /// in hand instead would be counting something the row may not hold.
  static const _revisionCounts = '''
        jsonb_array_length(nodes) as total,
        (select count(*) from jsonb_array_elements(nodes) as e
          where e.value ->> 'status' = 'outdated') as outdated,
        (select count(*) from jsonb_array_elements(nodes) as e
          where e.value ->> 'status' = 'vulnerable') as vulnerable''';

  @override
  Future<SavedReport> saveReport(
    DepReport report, {
    String? commitSha,
  }) async {
    final digest = reportDigest(report);

    // Insert only when this differs from the project's *newest* revision.
    // Compared against the newest rather than the whole history because a
    // project that goes A -> B -> A has been in three states over time, and
    // folding the second A into the first would stretch that row's window
    // across the period when B held.
    //
    // "Newest" is ordered by (first_seen_at, seq) rather than the timestamp
    // alone. The timestamp is unique in practice and not by construction, and a
    // tie would make this compare against an arbitrary revision — see
    // backend/sql/report_revision_order.sql.
    //
    // The check is inside the statement rather than a read followed by a write,
    // so the common case costs one round trip. Two scans of one project
    // finishing at the same moment can still both insert; the result is a
    // duplicate revision, which reads as a change that changed nothing. That is
    // a benign outcome for a path whose writers are a rate-limited endpoint and
    // one scheduler, and the alternative — a unique digest constraint — buys it
    // at the cost of getting reverts wrong.
    final inserted = await _pool.execute(
      Sql.named('''
        insert into dep_report_revisions
          (project_id, first_seen_at, last_seen_at, content_digest, commit_sha,
           nodes, manifests, coverage_note)
        select @projectId:uuid, @firstSeen:timestamptz, @lastSeen:timestamptz,
               @digest:text, @commitSha:text, @nodes:jsonb, @manifests:jsonb,
               @coverageNote:text
        where not exists (
          select 1 from (
            select content_digest from dep_report_revisions
            where project_id = @projectId:uuid
            order by first_seen_at desc, seq desc
            limit 1
          ) newest
          where newest.content_digest = @digest:text
        )
        returning $_revisionColumns
      '''),
      parameters: {
        'projectId': report.projectId,
        // The same instant under two names: a revision seen once was first
        // seen and last seen at the moment the scan generated it.
        'firstSeen': report.generatedAt,
        'lastSeen': report.generatedAt,
        'digest': digest,
        'commitSha': commitSha,
        'nodes': report.nodes.map((n) => n.toJson()).toList(),
        'manifests': report.manifests,
        'coverageNote': report.coverageNote,
      },
    );

    if (inserted.isNotEmpty) {
      await _pruneRevisions(report.projectId);
      return SavedReport(
        revision: _revisionFromRow(inserted.first.toColumnMap(), report: report),
        isNewRevision: true,
      );
    }

    // Nothing was inserted, so the newest revision already says this. Mark it
    // seen again. `greatest` because scans can finish out of order and a report
    // generated before the one on record says nothing newer; `coalesce` because
    // a commit id already recorded belongs to the first sighting, which is
    // where this state began.
    //
    // `nodes` refreshes on the same condition that moves `last_seen_at`, and
    // this is phase 0.8: the digest decides whether a *revision* is written,
    // never whether the *body* is. Keeping the old node list here meant every
    // field the digest deliberately excludes — `latest`, `status`, `size`,
    // `imported` — was frozen at first sighting on any project whose
    // dependencies had not moved. `manifests` and `coverage_note` are inside
    // the digest, so a match has already established they agree and there is
    // nothing to write.
    final seen = await _pool.execute(
      Sql.named('''
        update dep_report_revisions set
          last_seen_at = greatest(last_seen_at, @lastSeen:timestamptz),
          commit_sha   = coalesce(commit_sha, @commitSha:text),
          nodes        = case when @lastSeen:timestamptz > last_seen_at
                              then @nodes:jsonb
                              else nodes
                         end
        where id = (
          select id from dep_report_revisions
          where project_id = @projectId:uuid
          order by first_seen_at desc, seq desc
          limit 1
        )
        returning $_revisionColumns, $_revisionCounts
      '''),
      parameters: {
        'projectId': report.projectId,
        'lastSeen': report.generatedAt,
        'commitSha': commitSha,
        'nodes': report.nodes.map((n) => n.toJson()).toList(),
      },
    );

    // Counts read back from the updated row rather than taken from the report,
    // because an out-of-order scan leaves the stored body alone and its counts
    // would then describe a state that was not written.
    return SavedReport(
      revision: _revisionFromRow(seen.first.toColumnMap()),
      isNewRevision: false,
    );
  }

  /// Drops everything past [maxRevisionsPerProject] for one project, oldest
  /// first.
  ///
  /// Each revision holds a full node list, and a project scanned daily for a
  /// year accumulates as many revisions as it has changes. Nothing else prunes
  /// them, so this runs on the write that could have added one.
  Future<void> _pruneRevisions(String projectId) async {
    await _pool.execute(
      Sql.named('''
        delete from dep_report_revisions
        where project_id = @projectId:uuid
          and id not in (
            select id from dep_report_revisions
            where project_id = @projectId:uuid
            order by first_seen_at desc, seq desc
            limit @keep:int8
          )
      '''),
      parameters: {'projectId': projectId, 'keep': maxRevisionsPerProject},
    );
  }

  @override
  Future<DepReport?> reportFor(String projectId) async {
    final result = await _pool.execute(
      Sql.named('''
        select project_id, first_seen_at, nodes, manifests, coverage_note
        from dep_report_revisions
        where project_id = @id:uuid
        order by first_seen_at desc, seq desc
        limit 1
      '''),
      parameters: {'id': projectId},
    );
    if (result.isEmpty) return null;
    return _reportFromRow(result.first.toColumnMap());
  }

  @override
  Future<List<ReportRevision>> revisionsFor(
    String projectId, {
    int limit = 50,
  }) async {
    // The counts are computed in Postgres rather than by reading every
    // revision's nodes back into Dart. A history of 100 revisions of a
    // 400-package project is 40,000 nodes to decode so that a list can print
    // three numbers per row.
    final result = await _pool.execute(
      Sql.named('''
        select $_revisionColumns, $_revisionCounts
        from dep_report_revisions
        where project_id = @id:uuid
        order by first_seen_at desc, seq desc
        limit @limit:int8
      '''),
      parameters: {'id': projectId, 'limit': limit},
    );

    return [
      for (final row in result) _revisionFromRow(row.toColumnMap()),
    ];
  }

  @override
  Future<DepReport?> reportAt(String projectId, String revisionId) async {
    final result = await _pool.execute(
      Sql.named('''
        select project_id, first_seen_at, nodes, manifests, coverage_note
        from dep_report_revisions
        where id = @revisionId:uuid and project_id = @projectId:uuid
      '''),
      parameters: {'revisionId': revisionId, 'projectId': projectId},
    );
    if (result.isEmpty) return null;
    return _reportFromRow(result.first.toColumnMap());
  }

  /// Rows written before backend/sql/report_coverage.sql have no manifests and
  /// no note, which reads back the same as a single-package scan.
  static DepReport _reportFromRow(Map<String, dynamic> row) => DepReport(
        projectId: row['project_id'].toString(),
        generatedAt: row['first_seen_at'] as DateTime,
        nodes: _jsonbList(row['nodes'])
            .map((e) => DepNode.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
        manifests: _jsonbList(row['manifests']).cast<String>(),
        coverageNote: row['coverage_note'] as String?,
      );

  /// A revision summary.
  ///
  /// [report] supplies the counts on the *insert* path, where the row was just
  /// written from it and computing them in SQL would mean asking for numbers
  /// already in hand. Every other path counts the stored nodes, which after
  /// phase 0.8 are not necessarily the ones the caller passed.
  static ReportRevision _revisionFromRow(
    Map<String, dynamic> row, {
    DepReport? report,
  }) =>
      ReportRevision(
        id: row['id'].toString(),
        projectId: row['project_id'].toString(),
        firstSeenAt: row['first_seen_at'] as DateTime,
        lastSeenAt: row['last_seen_at'] as DateTime,
        digest: row['content_digest'] as String,
        commitSha: row['commit_sha'] as String?,
        total: report?.total ?? _count(row['total']),
        outdated: report?.outdated ?? _count(row['outdated']),
        vulnerable: report?.vulnerable ?? _count(row['vulnerable']),
      );

  /// `count(*)` comes back as an int64 and `jsonb_array_length` as an int32;
  /// both are absent on the write path, where the report supplies them.
  static int _count(Object? value) => switch (value) {
        final int n => n,
        final num n => n.toInt(),
        _ => 0,
      };

  /// A jsonb column as a Dart list. The driver hands back a parsed structure,
  /// but a null column (a row predating the column) and a driver that surfaces
  /// jsonb as a raw string both reach here too.
  static List<dynamic> _jsonbList(Object? value) => switch (value) {
        final String s => jsonDecodeList(s),
        final List l => l,
        _ => const [],
      };

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
