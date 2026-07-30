import 'package:postgres/postgres.dart';
import 'package:shared/shared.dart';

import 'notification_store.dart';

/// Postgres-backed [NotificationStore]. Tables in `backend/sql/notifications.sql`.
class PostgresNotificationStore implements NotificationStore {
  const PostgresNotificationStore(this._pool);

  final Pool _pool;

  static const _columns = 'id, owner_id, project_id, channel, url, '
      'min_severity, on_new_advisory, on_breaking_change, created_at';

  @override
  Future<List<NotificationTarget>> targetsFor(String ownerId) async {
    final result = await _pool.execute(
      Sql.named(
        'select $_columns from notification_targets '
        'where owner_id = @ownerId:uuid order by created_at desc',
      ),
      parameters: {'ownerId': ownerId},
    );
    return [for (final row in result) _fromRow(row.toColumnMap())];
  }

  @override
  Future<List<NotificationTarget>> targetsWatching({
    required String ownerId,
    required String projectId,
  }) async {
    // Filtered in the query rather than in Dart: a sweep asks this once per
    // project, and an owner with one channel and forty projects would otherwise
    // read the same rows forty times.
    final result = await _pool.execute(
      Sql.named(
        'select $_columns from notification_targets '
        'where owner_id = @ownerId:uuid '
        '  and (project_id is null or project_id = @projectId:uuid) '
        'order by created_at desc',
      ),
      parameters: {'ownerId': ownerId, 'projectId': projectId},
    );
    return [for (final row in result) _fromRow(row.toColumnMap())];
  }

  @override
  Future<NotificationTarget> save(NotificationTarget target) async {
    final result = await _pool.execute(
      Sql.named('''
        insert into notification_targets
          (id, owner_id, project_id, channel, url, min_severity,
           on_new_advisory, on_breaking_change)
        values
          (@id:uuid, @ownerId:uuid, @projectId:uuid, @channel:text, @url:text,
           @minSeverity:text, @onNewAdvisory:boolean, @onBreaking:boolean)
        on conflict (id) do update set
          project_id         = excluded.project_id,
          channel            = excluded.channel,
          url                = excluded.url,
          min_severity       = excluded.min_severity,
          on_new_advisory    = excluded.on_new_advisory,
          on_breaking_change = excluded.on_breaking_change
        where notification_targets.owner_id = excluded.owner_id
        returning $_columns
      '''),
      parameters: {
        'id': target.id,
        'ownerId': target.ownerId,
        'projectId': target.projectId,
        'channel': target.channel.name,
        'url': target.url,
        'minSeverity': target.minSeverity.name,
        'onNewAdvisory': target.onNewAdvisory,
        'onBreaking': target.onBreakingChange,
      },
    );

    // The `where` on the conflict clause means an update against someone
    // else's row matches nothing rather than taking it over.
    if (result.isEmpty) {
      throw StateError('notification target ${target.id} belongs to another '
          'owner');
    }
    return _fromRow(result.first.toColumnMap());
  }

  @override
  Future<bool> delete(String id, {required String ownerId}) async {
    final result = await _pool.execute(
      Sql.named(
        'delete from notification_targets '
        'where id = @id:uuid and owner_id = @ownerId:uuid returning id',
      ),
      parameters: {'id': id, 'ownerId': ownerId},
    );
    return result.isNotEmpty;
  }

  @override
  Future<bool> claimDelivery({
    required String targetId,
    required String revisionId,
  }) async {
    // The primary key is the lock. `on conflict do nothing` returns no row to
    // the loser, so exactly one caller is told it may send — including across
    // two processes, which is what a scheduler firing twice looks like.
    final result = await _pool.execute(
      Sql.named('''
        insert into notification_deliveries (target_id, revision_id)
        values (@targetId:uuid, @revisionId:uuid)
        on conflict (target_id, revision_id) do nothing
        returning target_id
      '''),
      parameters: {'targetId': targetId, 'revisionId': revisionId},
    );
    return result.isNotEmpty;
  }

  @override
  Future<void> recordDelivery({
    required String targetId,
    required String revisionId,
    required bool succeeded,
    String? detail,
  }) async {
    await _pool.execute(
      Sql.named('''
        update notification_deliveries
        set succeeded = @succeeded:boolean, detail = @detail:text
        where target_id = @targetId:uuid and revision_id = @revisionId:uuid
      '''),
      parameters: {
        'targetId': targetId,
        'revisionId': revisionId,
        'succeeded': succeeded,
        'detail': detail,
      },
    );
  }

  static NotificationTarget _fromRow(Map<String, dynamic> row) =>
      NotificationTarget(
        id: row['id'].toString(),
        ownerId: row['owner_id'].toString(),
        projectId: row['project_id']?.toString(),
        channel: NotificationChannel.values.byName(row['channel'] as String),
        url: row['url'] as String,
        minSeverity: AdvisorySeverity.values.byName(
          (row['min_severity'] as String?) ?? 'high',
        ),
        onNewAdvisory: (row['on_new_advisory'] as bool?) ?? true,
        onBreakingChange: (row['on_breaking_change'] as bool?) ?? true,
        createdAt: row['created_at'] as DateTime?,
      );
}
