import 'package:postgres/postgres.dart';

import 'collector_session_store.dart';

/// Postgres-backed [CollectorSessionStore] — see
/// `backend/sql/collector_sessions.sql`.
///
/// Shares the connection [Pool] with the other stores — see `Deps`.
class PostgresCollectorSessionStore implements CollectorSessionStore {
  PostgresCollectorSessionStore(this._pool);

  final Pool _pool;

  static const _columns =
      'id, owner_id, project_id, scan_id, expires_at, claimed_at';

  @override
  Future<CollectorSessionGrant> mint({
    required String ownerId,
    required String codeHash,
    required DateTime expiresAt,
    String? projectId,
  }) async {
    final result = await _pool.execute(
      Sql.named('''
        insert into collector_sessions (owner_id, code_hash, project_id, expires_at)
        values (@ownerId:uuid, @codeHash:text, @projectId:uuid, @expiresAt:timestamptz)
        returning $_columns
      '''),
      parameters: {
        'ownerId': ownerId,
        'codeHash': codeHash,
        'projectId': projectId,
        'expiresAt': expiresAt,
      },
    );
    return _fromRow(result.first.toColumnMap());
  }

  @override
  Future<CollectorSessionGrant?> byId(
    String id, {
    required String ownerId,
  }) async {
    final result = await _pool.execute(
      Sql.named(
        'select $_columns from collector_sessions '
        'where id = @id:uuid and owner_id = @ownerId:uuid',
      ),
      parameters: {'id': id, 'ownerId': ownerId},
    );
    if (result.isEmpty) return null;
    return _fromRow(result.first.toColumnMap());
  }

  @override
  Future<CollectorSessionGrant?> claim(String codeHash) async {
    // One statement: the `where` clause is what makes a claim single-use and
    // race-free, the same reasoning as `ScanJobStore.claimNext`'s `for update
    // skip locked` — a select followed by an update would leave a window
    // where two collectors racing the same code both win.
    final result = await _pool.execute(
      Sql.named('''
        update collector_sessions set
          claimed_at = now()
        where code_hash = @codeHash:text
          and claimed_at is null
          and expires_at > now()
        returning $_columns
      '''),
      parameters: {'codeHash': codeHash},
    );
    if (result.isEmpty) return null;
    return _fromRow(result.first.toColumnMap());
  }

  @override
  Future<void> attachScan(String id, String scanId) async {
    await _pool.execute(
      Sql.named('''
        update collector_sessions set scan_id = @scanId:text
        where id = @id:uuid
      '''),
      parameters: {'id': id, 'scanId': scanId},
    );
  }

  static CollectorSessionGrant _fromRow(Map<String, dynamic> row) =>
      CollectorSessionGrant(
        id: '${row['id']}',
        ownerId: '${row['owner_id']}',
        expiresAt: (row['expires_at'] as DateTime).toUtc(),
        projectId: row['project_id'] == null ? null : '${row['project_id']}',
        scanId: row['scan_id'] as String?,
        claimedAt: (row['claimed_at'] as DateTime?)?.toUtc(),
      );
}
