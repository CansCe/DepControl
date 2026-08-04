import 'dart:convert';

import 'package:postgres/postgres.dart';
import 'package:shared/shared.dart';

import 'scan_job_store.dart';

/// Postgres-backed [ScanJobStore] — see `backend/sql/scan_jobs.sql`.
///
/// This is the store whose durability is the point. Every other store here
/// persists an answer; this one persists a *request*, so that the work outlives
/// the connection that asked for it and the machine that started it.
///
/// Shares the connection [Pool] with the other stores — see `Deps`.
class PostgresScanJobStore implements ScanJobStore {
  PostgresScanJobStore(this._pool);

  final Pool _pool;

  static const _columns = 'id, owner_id, kind, git_url, ref, project_id, '
      'state, progress, error, attempts, created_at, claimed_at, '
      'heartbeat_at, finished_at';

  @override
  Future<ScanJob> enqueue(ScanJob job) async {
    await _pool.execute(
      Sql.named('''
        insert into scan_jobs (id, owner_id, kind, git_url, ref, project_id,
                               state, progress, created_at)
        values (@id:text, @ownerId:uuid, @kind:text, @gitUrl:text, @ref:text,
                @projectId:uuid, @state:text, @progress:jsonb,
                @createdAt:timestamptz)
        on conflict (id) do nothing
      '''),
      parameters: {
        'id': job.id,
        'ownerId': job.ownerId,
        'kind': job.kind.name,
        'gitUrl': job.gitUrl,
        'ref': job.ref,
        'projectId': job.projectId,
        'state': job.state.name,
        'progress': job.progress.toJson(),
        'createdAt': job.createdAt,
      },
    );
    return job;
  }

  @override
  Future<ScanJob?> byId(String id, {required String ownerId}) async {
    final result = await _pool.execute(
      Sql.named(
        'select $_columns from scan_jobs '
        'where id = @id:text and owner_id = @ownerId:uuid',
      ),
      parameters: {'id': id, 'ownerId': ownerId},
    );
    if (result.isEmpty) return null;
    return _fromRow(result.first.toColumnMap());
  }

  @override
  Future<List<ScanJob>> unfinishedFor(String ownerId) async {
    final result = await _pool.execute(
      Sql.named(
        "select $_columns from scan_jobs "
        "where owner_id = @ownerId:uuid and state in ('queued', 'running') "
        'order by created_at',
      ),
      parameters: {'ownerId': ownerId},
    );
    return [for (final row in result) _fromRow(row.toColumnMap())];
  }

  @override
  Future<ScanJob?> unfinishedForProject(String projectId) async {
    final result = await _pool.execute(
      Sql.named(
        "select $_columns from scan_jobs "
        "where project_id = @projectId:uuid and state in ('queued', 'running') "
        'order by created_at limit 1',
      ),
      parameters: {'projectId': projectId},
    );
    if (result.isEmpty) return null;
    return _fromRow(result.first.toColumnMap());
  }

  @override
  Future<ScanJob?> claimNext({
    Duration staleAfter = const Duration(minutes: 2),
    int maxAttempts = 3,
  }) async {
    // The claim is one statement, and `for update skip locked` is what makes it
    // safe: two workers draining at the same moment take two different rows
    // rather than both taking the oldest. Selecting and then updating would be
    // the same code with a race in the middle.
    //
    // The cutoff is computed here rather than as an `interval` so the parameter
    // stays a plain timestamptz.
    final result = await _pool.execute(
      Sql.named('''
        update scan_jobs set
          state        = 'running',
          claimed_at   = now(),
          heartbeat_at = now(),
          attempts     = attempts + 1
        where id = (
          select id from scan_jobs
          where attempts < @maxAttempts:integer
            and (
              state = 'queued'
              or (state = 'running'
                  and coalesce(heartbeat_at, claimed_at, created_at)
                        < @cutoff:timestamptz)
            )
          order by created_at
          limit 1
          for update skip locked
        )
        returning $_columns
      '''),
      parameters: {
        'maxAttempts': maxAttempts,
        'cutoff': DateTime.now().toUtc().subtract(staleAfter),
      },
    );
    if (result.isEmpty) return null;
    return _fromRow(result.first.toColumnMap());
  }

  @override
  Future<int> reapAbandoned({
    Duration staleAfter = const Duration(minutes: 2),
    int maxAttempts = 3,
  }) async {
    final result = await _pool.execute(
      Sql.named('''
        update scan_jobs set
          state       = 'failed',
          error       = @error:text,
          finished_at = now()
        where state = 'running'
          and attempts >= @maxAttempts:integer
          and coalesce(heartbeat_at, claimed_at, created_at)
                < @cutoff:timestamptz
        returning id
      '''),
      parameters: {
        'error': 'abandoned after $maxAttempts attempts',
        'maxAttempts': maxAttempts,
        'cutoff': DateTime.now().toUtc().subtract(staleAfter),
      },
    );
    return result.length;
  }

  @override
  Future<void> recordProgress(String id, ScanProgress progress) async {
    // Guarded on `state = 'running'` so a flush already in flight when the scan
    // ended cannot reopen a finished job or overwrite its final progress.
    await _pool.execute(
      Sql.named('''
        update scan_jobs set
          progress     = @progress:jsonb,
          heartbeat_at = now()
        where id = @id:text and state = 'running'
      '''),
      parameters: {'id': id, 'progress': progress.toJson()},
    );
  }

  @override
  Future<void> finish(
    String id, {
    required ScanJobState state,
    ScanProgress? progress,
    String? projectId,
    String? error,
  }) async {
    await _pool.execute(
      Sql.named('''
        update scan_jobs set
          state       = @state:text,
          progress    = coalesce(@progress:jsonb, progress),
          project_id  = coalesce(@projectId:uuid, project_id),
          error       = @error:text,
          finished_at = now()
        where id = @id:text
      '''),
      parameters: {
        'id': id,
        'state': state.name,
        'progress': progress?.toJson(),
        'projectId': projectId,
        'error': error,
      },
    );
  }

  @override
  Future<int> pendingCount() async {
    final result = await _pool.execute(
      Sql.named(
        "select count(*) from scan_jobs where state in ('queued', 'running')",
      ),
    );
    return (result.first.toColumnMap()['count'] as num?)?.toInt() ?? 0;
  }

  static ScanJob _fromRow(Map<String, dynamic> row) => ScanJob(
        id: row['id'] as String,
        ownerId: '${row['owner_id']}',
        kind: ScanJobKind.parse(row['kind'] as String?),
        gitUrl: row['git_url'] as String,
        ref: (row['ref'] as String?) ?? 'HEAD',
        projectId: row['project_id'] == null ? null : '${row['project_id']}',
        state: ScanJobState.parse(row['state'] as String?),
        progress: _progressFrom(row['progress']),
        error: row['error'] as String?,
        attempts: (row['attempts'] as num?)?.toInt() ?? 0,
        createdAt: (row['created_at'] as DateTime).toUtc(),
        claimedAt: (row['claimed_at'] as DateTime?)?.toUtc(),
        heartbeatAt: (row['heartbeat_at'] as DateTime?)?.toUtc(),
        finishedAt: (row['finished_at'] as DateTime?)?.toUtc(),
      );

  /// jsonb usually decodes to a parsed Dart map; some driver paths hand it back
  /// as the raw string. An empty object is what a freshly enqueued job holds,
  /// and `ScanProgress.fromJson` reads that as a queued scan.
  static ScanProgress _progressFrom(Object? raw) {
    final decoded = switch (raw) {
      final String json => jsonDecode(json),
      final Map map => map,
      _ => const <String, dynamic>{},
    };
    return ScanProgress.fromJson(
      decoded is Map ? decoded.cast<String, dynamic>() : const {},
    );
  }
}
