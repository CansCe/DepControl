import 'package:shared/shared.dart';

/// A pairing session as the store holds it — more than [CollectorSession]
/// exposes to a client, since [ownerId] is who the enqueued scan belongs to
/// and must never be read back over the wire.
class CollectorSessionGrant {
  const CollectorSessionGrant({
    required this.id,
    required this.ownerId,
    required this.expiresAt,
    this.projectId,
    this.scanId,
    this.claimedAt,
  });

  final String id;
  final String ownerId;
  final DateTime expiresAt;

  /// Set for a re-upload to an existing project; null for a new one. Mirrors
  /// `ScanJob.projectId`'s two shapes.
  final String? projectId;

  /// The scan this grant's claim enqueued, once there is one.
  final String? scanId;

  final DateTime? claimedAt;

  CollectorSessionGrant copyWith({String? scanId, DateTime? claimedAt}) =>
      CollectorSessionGrant(
        id: id,
        ownerId: ownerId,
        expiresAt: expiresAt,
        projectId: projectId,
        scanId: scanId ?? this.scanId,
        claimedAt: claimedAt ?? this.claimedAt,
      );

  /// The view a client is allowed to see. State is derived rather than
  /// stored: "expired" is just "the clock passed [expiresAt] before anyone
  /// claimed it", read fresh on every request rather than written down once
  /// and left to go stale.
  CollectorSession toSession({DateTime? now}) {
    final state = claimedAt != null
        ? CollectorSessionState.claimed
        : (now ?? DateTime.now().toUtc()).isAfter(expiresAt)
            ? CollectorSessionState.expired
            : CollectorSessionState.waiting;
    return CollectorSession(
      id: id,
      state: state,
      expiresAt: expiresAt,
      projectId: projectId,
      scanId: scanId,
    );
  }
}

/// One-shot grants for the local collector to submit a bundle without ever
/// holding a Supabase JWT. See `backend/sql/collector_sessions.sql`.
///
/// Owner-scoped at [byId] like every other store here: a session belonging to
/// somebody else reads as absent. [claim] is the exception — it is reached by
/// the code alone, before any owner is known, which is the entire point of
/// the code.
abstract class CollectorSessionStore {
  /// Mints a new grant. [codeHash] is the only trace of the code kept — the
  /// plaintext exists nowhere past the route that generated it.
  Future<CollectorSessionGrant> mint({
    required String ownerId,
    required String codeHash,
    required DateTime expiresAt,
    String? projectId,
  });

  /// The grant with [id], if [ownerId] asked for it.
  Future<CollectorSessionGrant?> byId(String id, {required String ownerId});

  /// Claims the grant behind [codeHash], single-use.
  ///
  /// Null when no unclaimed, unexpired grant hashes to this — a code that
  /// never existed, one already used, and one that expired are all the same
  /// answer to a caller who only has the code. Must be one atomic statement:
  /// a read followed by a write leaves a window where two collectors racing
  /// the same code could both win.
  Future<CollectorSessionGrant?> claim(String codeHash);

  /// Records the scan a claim enqueued, so a client polling [byId] can hand
  /// off to it.
  Future<void> attachScan(String id, String scanId);
}

/// In-memory [CollectorSessionStore], used when no database is configured and
/// by tests. Lost on restart, same caveat as `InMemoryScanJobStore`.
class InMemoryCollectorSessionStore implements CollectorSessionStore {
  final _sessions = <String, CollectorSessionGrant>{};
  final _byHash = <String, String>{};
  var _nextId = 0;

  @override
  Future<CollectorSessionGrant> mint({
    required String ownerId,
    required String codeHash,
    required DateTime expiresAt,
    String? projectId,
  }) async {
    final grant = CollectorSessionGrant(
      id: 'session-${_nextId++}',
      ownerId: ownerId,
      expiresAt: expiresAt,
      projectId: projectId,
    );
    _sessions[grant.id] = grant;
    _byHash[codeHash] = grant.id;
    return grant;
  }

  @override
  Future<CollectorSessionGrant?> byId(
    String id, {
    required String ownerId,
  }) async {
    final grant = _sessions[id];
    return grant == null || grant.ownerId != ownerId ? null : grant;
  }

  @override
  Future<CollectorSessionGrant?> claim(String codeHash) async {
    final id = _byHash[codeHash];
    if (id == null) return null;
    final grant = _sessions[id];
    if (grant == null) return null;
    if (grant.claimedAt != null) return null;

    // Single-threaded by construction here, the same guarantee the Postgres
    // store buys with `where claimed_at is null ... returning`.
    final now = DateTime.now().toUtc();
    if (now.isAfter(grant.expiresAt)) return null;

    final claimed = grant.copyWith(claimedAt: now);
    _sessions[id] = claimed;
    return claimed;
  }

  @override
  Future<void> attachScan(String id, String scanId) async {
    final grant = _sessions[id];
    if (grant == null) return;
    _sessions[id] = grant.copyWith(scanId: scanId);
  }
}
