import 'package:shared/shared.dart';

/// A scan somebody asked for, as the queue holds it.
///
/// The durable half of what used to be a request. [ScanStatus] is the view of
/// this a client gets; everything here that is not in that view — attempts, the
/// claim, the heartbeat — is the queue's own business and no client's.
class ScanJob {
  const ScanJob({
    required this.id,
    required this.ownerId,
    required this.kind,
    required this.gitUrl,
    required this.progress,
    required this.createdAt,
    this.ref = 'HEAD',
    this.projectId,
    this.state = ScanJobState.queued,
    this.error,
    this.attempts = 0,
    this.claimedAt,
    this.heartbeatAt,
    this.finishedAt,
  });

  /// The client's own scan id, which is also the primary key.
  ///
  /// The caller names its scan so it can start watching without waiting for the
  /// server to hand an id back. That predates this table and is worth keeping;
  /// it is also exactly why [ownerId] is on the row and why every read is scoped
  /// by it. An id a client chose is an id another client could guess.
  final String id;
  final String ownerId;

  final ScanJobKind kind;
  final String gitUrl;
  final String ref;

  /// Set from the start for a refresh; only once the scan succeeds for an add.
  final String? projectId;

  final ScanJobState state;
  final ScanProgress progress;
  final String? error;

  /// How many times this job has been claimed. A scan that kills its machine
  /// every time must not be able to do it forever.
  final int attempts;

  final DateTime createdAt;
  final DateTime? claimedAt;
  final DateTime? heartbeatAt;
  final DateTime? finishedAt;

  ScanStatus toStatus() => ScanStatus(
        scanId: id,
        state: state,
        progress: progress,
        gitUrl: gitUrl,
        projectId: projectId,
        error: error,
      );

  ScanJob copyWith({
    String? projectId,
    ScanJobState? state,
    ScanProgress? progress,
    String? error,
    int? attempts,
    DateTime? claimedAt,
    DateTime? heartbeatAt,
    DateTime? finishedAt,
  }) =>
      ScanJob(
        id: id,
        ownerId: ownerId,
        kind: kind,
        gitUrl: gitUrl,
        ref: ref,
        projectId: projectId ?? this.projectId,
        state: state ?? this.state,
        progress: progress ?? this.progress,
        error: error ?? this.error,
        attempts: attempts ?? this.attempts,
        createdAt: createdAt,
        claimedAt: claimedAt ?? this.claimedAt,
        heartbeatAt: heartbeatAt ?? this.heartbeatAt,
        finishedAt: finishedAt ?? this.finishedAt,
      );
}

/// Which of the two scanning endpoints asked for this.
///
/// The work is nearly the same and the difference is what happens at the end: an
/// add creates a project once it has a report to give it, a refresh updates one
/// that already exists.
enum ScanJobKind {
  add,
  refresh;

  static ScanJobKind parse(String? raw) => ScanJobKind.values.firstWhere(
        (k) => k.name == raw,
        orElse: () => ScanJobKind.add,
      );
}

/// The scan queue.
///
/// Owner-scoped at the store like everything else (see `ProjectRepository`): a
/// scan belonging to somebody else reads as absent, and the route turns that
/// into 404 rather than 403.
///
/// The exception is [claimNext] and [reapAbandoned], which are the worker's and
/// deliberately see every owner's jobs. They are never reachable from a request.
abstract class ScanJobStore {
  /// Records a scan to be run. Returns what was stored.
  Future<ScanJob> enqueue(ScanJob job);

  /// The scan with [id], if [ownerId] asked for it.
  Future<ScanJob?> byId(String id, {required String ownerId});

  /// [ownerId]'s scans that have not finished, oldest first.
  ///
  /// What a client asks for when it is reopened: the work carried on without it,
  /// and re-attaching to a running scan is the difference between the feature
  /// working and the user starting a second one.
  Future<List<ScanJob>> unfinishedFor(String ownerId);

  /// The unfinished scan for [projectId], if there is one.
  ///
  /// So a second refresh returns the first rather than queueing a duplicate
  /// clone of the same repository — the server-side half of the guard
  /// `ScanQueue.reanalyze` has always applied on the client.
  Future<ScanJob?> unfinishedForProject(String projectId);

  /// Takes the oldest job that is waiting, marking it claimed, or null when
  /// there is nothing to do.
  ///
  /// Also picks up a job whose worker has stopped heart-beating for
  /// [staleAfter] — that is what makes a machine dying mid-scan survivable.
  /// Atomic: two workers draining at once must not both get the same job.
  Future<ScanJob?> claimNext({
    Duration staleAfter = const Duration(minutes: 2),
    int maxAttempts = 3,
  });

  /// Fails jobs abandoned once too often, so a scan that reliably kills its
  /// worker stops being retried and starts being reported.
  Future<int> reapAbandoned({
    Duration staleAfter = const Duration(minutes: 2),
    int maxAttempts = 3,
  });

  /// Writes what a running scan is doing, and says it is still alive.
  ///
  /// One call for both because they happen together: the flush is the heartbeat.
  Future<void> recordProgress(String id, ScanProgress progress);

  /// Ends a job, one way or the other.
  Future<void> finish(
    String id, {
    required ScanJobState state,
    ScanProgress? progress,
    String? projectId,
    String? error,
  });

  /// How many jobs are queued or running, across every owner.
  ///
  /// The watchdog's question, and the reason it is not scoped: a machine may not
  /// shut itself down while anybody's scan is outstanding.
  Future<int> pendingCount();
}

/// In-memory [ScanJobStore], used when no database is configured and by tests.
///
/// State is lost on restart — which for this store is the whole thing it exists
/// to prevent, so a deployment running on this one has not got the feature. The
/// warning `Deps` already prints about the in-memory repository covers it.
class InMemoryScanJobStore implements ScanJobStore {
  final _jobs = <String, ScanJob>{};

  @override
  Future<ScanJob> enqueue(ScanJob job) async {
    _jobs[job.id] = job;
    return job;
  }

  @override
  Future<ScanJob?> byId(String id, {required String ownerId}) async {
    final job = _jobs[id];
    return job == null || job.ownerId != ownerId ? null : job;
  }

  @override
  Future<List<ScanJob>> unfinishedFor(String ownerId) async =>
      _jobs.values
          .where((j) => j.ownerId == ownerId && !j.state.isFinished)
          .toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  @override
  Future<ScanJob?> unfinishedForProject(String projectId) async {
    for (final job in _jobs.values) {
      if (job.projectId == projectId && !job.state.isFinished) return job;
    }
    return null;
  }

  @override
  Future<ScanJob?> claimNext({
    Duration staleAfter = const Duration(minutes: 2),
    int maxAttempts = 3,
  }) async {
    final now = DateTime.now().toUtc();
    final candidates = _jobs.values
        .where((j) => _isClaimable(j, now, staleAfter, maxAttempts))
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (candidates.isEmpty) return null;

    // Single-threaded by construction here — a Dart isolate cannot interleave
    // between these two lines, which is the same guarantee `for update skip
    // locked` buys the Postgres one.
    final claimed = candidates.first.copyWith(
      state: ScanJobState.running,
      attempts: candidates.first.attempts + 1,
      claimedAt: now,
      heartbeatAt: now,
    );
    _jobs[claimed.id] = claimed;
    return claimed;
  }

  @override
  Future<int> reapAbandoned({
    Duration staleAfter = const Duration(minutes: 2),
    int maxAttempts = 3,
  }) async {
    final now = DateTime.now().toUtc();
    var reaped = 0;
    for (final job in _jobs.values.toList()) {
      if (job.state != ScanJobState.running) continue;
      if (!_isStale(job, now, staleAfter)) continue;
      if (job.attempts < maxAttempts) continue;
      _jobs[job.id] = job.copyWith(
        state: ScanJobState.failed,
        error: 'abandoned after $maxAttempts attempts',
        finishedAt: now,
      );
      reaped++;
    }
    return reaped;
  }

  @override
  Future<void> recordProgress(String id, ScanProgress progress) async {
    final job = _jobs[id];
    if (job == null || job.state.isFinished) return;
    _jobs[id] = job.copyWith(
      progress: progress,
      heartbeatAt: DateTime.now().toUtc(),
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
    final job = _jobs[id];
    if (job == null) return;
    _jobs[id] = job.copyWith(
      state: state,
      progress: progress,
      projectId: projectId,
      error: error,
      finishedAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<int> pendingCount() async =>
      _jobs.values.where((j) => !j.state.isFinished).length;

  static bool _isClaimable(
    ScanJob job,
    DateTime now,
    Duration staleAfter,
    int maxAttempts,
  ) {
    if (job.attempts >= maxAttempts) return false;
    if (job.state == ScanJobState.queued) return true;
    return job.state == ScanJobState.running && _isStale(job, now, staleAfter);
  }

  static bool _isStale(ScanJob job, DateTime now, Duration staleAfter) {
    final beat = job.heartbeatAt ?? job.claimedAt;
    return beat == null || now.difference(beat) > staleAfter;
  }
}
