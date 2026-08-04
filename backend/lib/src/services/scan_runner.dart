import 'dart:async';

import 'package:shared/shared.dart';
import 'package:uuid/uuid.dart';

import '../repository/project_repository.dart';
import '../repository/scan_job_store.dart';
import 'dependency_analyzer.dart';
import 'git_fetcher.dart';
import 'logger.dart';
import 'scan_progress_store.dart';

/// Runs the scans in [ScanJobStore], one at a time.
///
/// The scan used to happen inside the POST that asked for it, which made it
/// exactly as durable as the browser tab — and on a deployment that scales to
/// zero, exactly as durable as the connection holding the machine up. Closing
/// the page took the scan with it.
///
/// So the request writes a job and returns, and this drains it. It runs **in
/// the API process rather than beside it**, which is the deliberate part: a
/// separate worker would have to be always-on, because the only thing that
/// knows a scan was asked for is the API, and a worker that scaled to zero
/// would have nothing to start it. One process, one machine, started by the
/// proxy on a request and stopped by [IdleWatchdog] once there is neither a
/// request nor a job.
///
/// **One job at a time.** Not a throughput decision — the analyzer's own
/// concurrency already saturates a shared CPU, and peak RSS for a large
/// repository is around 350 MB against a 512 MB machine. Two at once is how
/// both of them die.
class ScanRunner {
  ScanRunner({
    required ScanJobStore jobs,
    required ProjectRepository repository,
    required GitFetcher gitFetcher,
    required DependencyAnalyzer analyzer,
    required ScanProgressStore progress,
    this.sweepInterval = const Duration(seconds: 20),
    this.flushInterval = const Duration(seconds: 1),
    this.staleAfter = const Duration(minutes: 2),
    this.maxAttempts = 3,
  })  : _jobs = jobs,
        _repository = repository,
        _gitFetcher = gitFetcher,
        _analyzer = analyzer,
        _progress = progress;

  final ScanJobStore _jobs;
  final ProjectRepository _repository;
  final GitFetcher _gitFetcher;
  final DependencyAnalyzer _analyzer;
  final ScanProgressStore _progress;

  /// How often to look for work nobody woke us about — a job left behind by a
  /// machine that died, or one enqueued against a different instance.
  final Duration sweepInterval;

  /// How often a running scan's progress is written to its row.
  ///
  /// The in-memory store is the live copy and the row is the durable one, for
  /// the reason `scan_jobs.sql` gives: `packageDone()` fires once per package,
  /// and a write each would cost more than the registry calls it is reporting
  /// on. The flush doubles as the heartbeat, since they happen together.
  final Duration flushInterval;

  /// How long a claimed job may go without a heartbeat before another worker
  /// may take it. This is the window in which an OOM becomes survivable.
  final Duration staleAfter;

  /// How many times a job may be claimed before it is reported as failed rather
  /// than retried. A scan that reliably kills its worker must not do so forever.
  final int maxAttempts;

  static final _log = log.tagged('scan');

  Timer? _sweep;

  /// The drain in progress, or null. Held as a future rather than a flag so
  /// that a second caller can *wait for* the drain rather than being told one
  /// is already happening and left with nothing to await.
  Future<void>? _drain;

  /// Whether a scan is running on this machine right now.
  bool get isBusy => _drain != null;

  /// Begins draining, and keeps looking.
  void start() {
    _sweep ??= Timer.periodic(sweepInterval, (_) => wake());
    wake();
  }

  /// Stops looking. Does not interrupt a scan already under way — there is
  /// nothing safe to interrupt it at, and the job would only be reclaimed.
  void stop() {
    _sweep?.cancel();
    _sweep = null;
  }

  /// Asks for a drain now, because something was just enqueued.
  ///
  /// Fire-and-forget: the request that calls this is about to answer 202 and
  /// must not wait for a repository to be cloned.
  void wake() => unawaited(drain());

  /// Runs everything claimable, then returns.
  ///
  /// Returns the drain **already in progress** when there is one, rather than
  /// returning immediately. The loop only ends when there is nothing left to
  /// claim, so awaiting the running drain is as good a guarantee as awaiting a
  /// fresh one — and a caller that wants to know when the queue is empty has
  /// something to await either way. A flag would have handed the second caller
  /// a completed future and a queue still full.
  Future<void> drain() => _drain ??= _drainLoop().whenComplete(
        () => _drain = null,
      );

  Future<void> _drainLoop() async {
    try {
      while (true) {
        await _jobs.reapAbandoned(
          staleAfter: staleAfter,
          maxAttempts: maxAttempts,
        );
        final job = await _jobs.claimNext(
          staleAfter: staleAfter,
          maxAttempts: maxAttempts,
        );
        if (job == null) {
          _lastFailure = null;
          return;
        }
        await _run(job);
      }
    } catch (e) {
      // A drain that throws must not leave the runner wedged: the sweep will
      // come back. Most likely cause is the database being briefly unreachable,
      // which is not this job's fault and not worth failing anything over.
      _reportDrainFailure(e);
    }
  }

  /// The last drain failure, so a permanent one is said once rather than every
  /// [sweepInterval] for as long as the machine lives.
  ///
  /// The failure worth designing for is not the blip: it is a cause that never
  /// clears — a table that was never created, a credential that was revoked —
  /// where the same line every twenty seconds buries everything else in the log
  /// and still says nothing new. Repeats are dropped until the error changes or
  /// a drain succeeds.
  String? _lastFailure;

  void _reportDrainFailure(Object error) {
    final message = '$error';
    if (message == _lastFailure) return;
    _lastFailure = message;

    _log.warn('Drain stopped early: $message');
    if (message.contains('scan_jobs') && message.contains('does not exist')) {
      // Worth naming, because the symptom is a 500 on every scan and an error
      // code, and the cause is one file nobody has run yet.
      _log.error(
        'The scan queue table is missing. Apply backend/sql/scan_jobs.sql to '
        'the database DATABASE_URL points at; until then no scan can be '
        'queued or run.',
      );
    }
  }

  Future<void> _run(ScanJob job) async {
    _log.info('Scanning ${job.gitUrl} (${job.kind.name}, attempt '
        '${job.attempts} of $maxAttempts)');

    final sink = _progress.sinkFor(job.id);
    final flush = Timer.periodic(flushInterval, (_) {
      final current = _progress[job.id];
      if (current != null) unawaited(_jobs.recordProgress(job.id, current));
    });

    try {
      final project = await _resolveProject(job);

      sink.phase(ScanPhase.fetching);
      final files = await _gitFetcher.fetchAll(job.gitUrl, ref: job.ref);
      final report = await _analyzer.analyzeRepository(
        project.id,
        files,
        progress: sink,
      );

      sink.phase(ScanPhase.saving);
      await _repository.add(
        project.copyWith(lastCheckedAt: DateTime.now().toUtc()),
      );
      await _repository.saveReport(report);
      sink.phase(ScanPhase.done);

      await _jobs.finish(
        job.id,
        state: ScanJobState.done,
        progress: _progress[job.id],
        projectId: project.id,
      );
      _log.info('Scanned ${project.name}: ${report.total} packages');
    } on StateError catch (e) {
      // The repository moved, was made private, or lost its manifest.
      await _fail(job, sink, e.message);
    } on UnsupportedError catch (e) {
      await _fail(job, sink, '${e.message}');
    } catch (e) {
      await _fail(job, sink, '$e');
    } finally {
      flush.cancel();
    }
  }

  /// The project this job is about — the existing one for a refresh, a new one
  /// for an add.
  ///
  /// An add's project is *built* here but not stored until the report is, which
  /// keeps the rule the synchronous version had: a git URL nobody can clone
  /// leaves nothing behind. The id is minted up front because the report is
  /// keyed by it.
  Future<Project> _resolveProject(ScanJob job) async {
    if (job.kind == ScanJobKind.add) {
      return Project(
        id: const Uuid().v4(),
        gitUrl: job.gitUrl,
        name: _repoName(job.gitUrl),
        ownerId: job.ownerId,
        ref: job.ref,
        addedAt: DateTime.now().toUtc(),
      );
    }

    // Re-read rather than trusting what the route saw. A job can sit in the
    // queue across a machine restart, and in that time the project can be
    // deleted or archived — and archiving means "do not re-fetch this", which a
    // queued scan would otherwise go on to do.
    final id = job.projectId;
    final project =
        id == null ? null : await _repository.byId(id, ownerId: job.ownerId);
    if (project == null) {
      throw StateError('the project was deleted before this scan ran');
    }
    if (project.isArchived) {
      throw StateError('the project was archived before this scan ran');
    }
    return project;
  }

  Future<void> _fail(ScanJob job, ScanProgressSink sink, String reason) async {
    _log.warn('Could not scan ${job.gitUrl}: $reason');
    sink.failed(reason);
    await _jobs.finish(
      job.id,
      state: ScanJobState.failed,
      progress: _progress[job.id],
      error: reason,
    );
  }

  static String _repoName(String gitUrl) {
    final segments = Uri.parse(gitUrl).pathSegments;
    if (segments.isEmpty) return gitUrl;
    return segments.last.replaceAll('.git', '');
  }
}
