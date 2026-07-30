import 'package:shared/shared.dart';

/// Where a running scan writes what it is doing.
///
/// Passed down into the analyzer, which knows the counts but nothing about
/// HTTP, scan ids or who is asking. Analysis code calls these; what happens to
/// the numbers is the caller's business.
abstract class ScanProgressSink {
  /// Nothing is listening. The default, so every code path that analyzes
  /// without a client watching costs nothing.
  static const ScanProgressSink none = _NullSink();

  /// Moves to [phase], restarting the clock used to work out a rate.
  void phase(ScanPhase phase);

  /// Says how many manifests the repository holds, once that is known.
  void manifestsTotal(int count);

  /// A manifest's package set has been worked out: [count] more packages to
  /// examine, and one more manifest under way.
  void manifestStarted(int count);

  /// One package examined.
  void packageDone();

  /// The scan ended badly.
  void failed(String reason);
}

class _NullSink implements ScanProgressSink {
  const _NullSink();

  @override
  void phase(ScanPhase phase) {}

  @override
  void manifestsTotal(int count) {}

  @override
  void manifestStarted(int count) {}

  @override
  void packageDone() {}

  @override
  void failed(String reason) {}
}

/// Progress for the scans currently running, in memory.
///
/// In memory on purpose. Progress is worth nothing once the scan it describes
/// has finished — the report is the durable artefact — and putting a row per
/// package tick through Postgres would cost more than the analysis it is
/// reporting on. The same reasoning the rate limiter already runs on.
///
/// The consequence, stated plainly: with more than one server instance a poll
/// can land on a machine that is not running the scan, and gets a 404. Clients
/// must treat an unknown scan as "no progress available" and fall back to an
/// indeterminate bar rather than as an error.
class ScanProgressStore {
  ScanProgressStore({
    this.retention = const Duration(minutes: 5),
    this.capacity = 200,
  });

  /// How long a finished scan's progress is still answerable, so a client that
  /// polls once more after the result lands gets a sensible reply.
  final Duration retention;

  /// A hard ceiling, because the scan id comes from the client. Without it, a
  /// caller passing a fresh id on every request would grow this without bound.
  final int capacity;

  final Map<String, ScanProgress> _entries = {};

  ScanProgress? operator [](String id) => _entries[id];

  /// A sink that records into this store under [id].
  ScanProgressSink sinkFor(String id) => _StoreSink(this, id);

  void put(String id, ScanProgress progress) {
    _entries[id] = progress;
    _prune();
  }

  void remove(String id) => _entries.remove(id);

  /// Drops what is stale, and then what is merely oldest if still over
  /// [capacity]. Runs on write rather than on a timer: a store nobody is
  /// writing to is a store that does not need tidying.
  void _prune() {
    final now = DateTime.now().toUtc();
    _entries.removeWhere(
      (_, p) => p.isFinished && now.difference(p.startedAt) > retention,
    );
    if (_entries.length <= capacity) return;

    final byAge = _entries.entries.toList()
      ..sort((a, b) => a.value.startedAt.compareTo(b.value.startedAt));
    for (final entry in byAge.take(_entries.length - capacity)) {
      _entries.remove(entry.key);
    }
  }
}

class _StoreSink implements ScanProgressSink {
  _StoreSink(this._store, this._id) {
    final now = DateTime.now().toUtc();
    _store.put(
      _id,
      ScanProgress(
        phase: ScanPhase.queued,
        startedAt: now,
        phaseStartedAt: now,
      ),
    );
  }

  final ScanProgressStore _store;
  final String _id;

  ScanProgress get _current =>
      _store[_id] ??
      ScanProgress(
        phase: ScanPhase.queued,
        startedAt: DateTime.now().toUtc(),
        phaseStartedAt: DateTime.now().toUtc(),
      );

  @override
  void phase(ScanPhase phase) {
    final current = _current;
    if (current.phase == phase) return;
    _store.put(
      _id,
      current.copyWith(phase: phase, phaseStartedAt: DateTime.now().toUtc()),
    );
  }

  @override
  void manifestsTotal(int count) {
    _store.put(_id, _current.copyWith(manifestsTotal: count));
  }

  @override
  void manifestStarted(int count) {
    final current = _current;
    _store.put(
      _id,
      current.copyWith(
        packagesTotal: current.packagesTotal + count,
        manifestsSeen: current.manifestsSeen + 1,
        // A repository with a single manifest never gets a total announced, so
        // it is inferred from the first one starting.
        manifestsTotal: current.manifestsTotal == 0 ? 1 : null,
        // Started once, at the first manifest, and left alone after that —
        // `copyWith` keeps the existing value when this is null.
        analysisStartedAt: DateTime.now().toUtc(),
      ),
    );
  }

  @override
  void packageDone() {
    final current = _current;
    _store.put(_id, current.copyWith(packagesDone: current.packagesDone + 1));
  }

  @override
  void failed(String reason) {
    _store.put(
      _id,
      _current.copyWith(
        phase: ScanPhase.failed,
        phaseStartedAt: DateTime.now().toUtc(),
        error: reason,
      ),
    );
  }
}
