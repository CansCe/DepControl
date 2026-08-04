import 'dart:async';

import 'logger.dart';

/// Stops the machine when there is neither a request nor a scan.
///
/// This exists because scans stopped being requests. Fly's own
/// `auto_stop_machines` is proxy-driven: it counts connections, so it stops a
/// machine that has no open request however busy the process is. That was
/// harmless while the scan *was* the request — the connection held the machine
/// up for exactly as long as the work took — and it is fatal now that the work
/// outlives the connection. Closing the browser would stop the machine
/// mid-scan, which is the failure this whole phase exists to remove.
///
/// So `auto_stop_machines` is turned off in `fly.toml` and the app owns its own
/// lifecycle instead. Same scale-to-zero behaviour, with one extra condition on
/// "idle": no request for [idleAfter], **and** nothing in the scan queue.
///
/// Exiting is how a machine stops itself. Under an `on-failure` restart policy
/// a process that exits 0 leaves the machine stopped, and `auto_start_machines`
/// brings it back on the next request — the same cold start as before, since a
/// compiled Dart binary on a scratch image boots in well under a second.
///
/// **Off unless configured.** Nothing shuts itself down in development or in a
/// test: an unset `IDLE_SHUTDOWN_SECONDS` means never, and that is the default
/// everywhere except the deployment that asks for it.
class IdleWatchdog {
  IdleWatchdog({
    required Future<int> Function() pendingWork,
    required bool Function() localWork,
    required this.idleAfter,
    // Required rather than defaulted to `dart:io`'s: this ends the process, and
    // a default would let a test that wandered into it take the runner down.
    required void Function(int code) exit,
    this.checkInterval = const Duration(seconds: 15),
    this.unreadableGrace = const Duration(minutes: 1),
  })  : _pendingWork = pendingWork,
        _localWork = localWork,
        _exit = exit;

  /// Whether a scan is running **in this process** right now.
  ///
  /// Asked first, and separately from [_pendingWork], because it is the one
  /// question that needs no database. It is also the only one whose answer must
  /// never be overridden: stopping on top of a scan running here destroys work
  /// in progress, where stopping on top of a job merely queued costs a cold
  /// start when somebody next asks.
  final bool Function() _localWork;

  /// How much work is outstanding, across every owner.
  ///
  /// Not scoped to this machine, and that is the point: a job queued while this
  /// machine was starting up belongs to whoever is awake, and shutting down on
  /// top of it would leave it for the next request to discover — which for a
  /// deployment that scales to zero could be hours.
  final Future<int> Function() _pendingWork;

  /// How long with no request before the machine may stop, when there is also
  /// no work. Fly's own default idle timeout is in the same range; matching it
  /// keeps the cold-start behaviour people are used to.
  final Duration idleAfter;

  /// How long an unreadable queue may keep the machine up.
  ///
  /// Not being able to read the queue used to mean "stay up", full stop — on
  /// the reasoning that staying up costs money and stopping on top of a running
  /// scan costs the scan. That is right for a blip and wrong for anything that
  /// does not resolve. A missing table, a revoked credential or a bad
  /// `DATABASE_URL` never comes back on its own, so the machine stayed up for
  /// ever, which is the one outcome this whole arrangement exists to avoid, and
  /// it announced itself only as a bill.
  ///
  /// So the uncertainty is bounded. Past this, with nothing running here, the
  /// machine stops: it cannot claim a job it cannot read, so there is nothing
  /// left for it to be staying up *for*. The next request starts it again — and
  /// if the queue is still unreadable, it stops again, which is a loop paced by
  /// traffic rather than a machine running all night.
  final Duration unreadableGrace;

  final Duration checkInterval;
  final void Function(int code) _exit;

  static final _log = log.tagged('idle');

  DateTime _lastRequest = DateTime.now();

  /// When the queue first became unreadable in the current run of failures.
  DateTime? _unreadableSince;

  Timer? _timer;

  /// Reads `IDLE_SHUTDOWN_SECONDS`, or null when it is unset, zero or
  /// unreadable — all of which mean "stay up", which is the right default for
  /// anything that is not this deployment.
  static Duration? idleFromEnvironment(Map<String, String> env) {
    final seconds = int.tryParse(env['IDLE_SHUTDOWN_SECONDS'] ?? '');
    if (seconds == null || seconds <= 0) return null;
    return Duration(seconds: seconds);
  }

  /// Call on every request. Cheap on purpose — it is on the hot path.
  void touch() => _lastRequest = DateTime.now();

  void start() {
    _timer ??= Timer.periodic(checkInterval, (_) => unawaited(_check()));
    _log.info(
      'Will stop the machine after ${idleAfter.inSeconds}s with no request '
      'and no scans outstanding.',
    );
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _check() async {
    if (DateTime.now().difference(_lastRequest) < idleAfter) return;

    // Asked before the database, and it settles the case the database cannot:
    // a scan running here is work that would be destroyed by stopping, and
    // knowing about it depends on nothing that can fail.
    if (_localWork()) {
      _unreadableSince = null;
      _log.info('Idle, but a scan is running here — staying up.');
      return;
    }

    final int pending;
    try {
      pending = await _pendingWork();
    } catch (e) {
      final now = DateTime.now();
      final since = _unreadableSince ??= now;
      if (now.difference(since) < unreadableGrace) {
        _log.warn('Could not read the scan queue, staying up for now: $e');
        return;
      }
      // Long enough that this is not a blip. Nothing is running here — checked
      // above, without the database — and nothing can start, because claiming a
      // job needs the same queue that will not answer. Staying up would buy
      // nobody anything and would go on buying it indefinitely.
      _log.error(
        'The scan queue has been unreadable for '
        '${unreadableGrace.inSeconds}s and no scan is running here — stopping '
        'rather than staying up indefinitely. Fix the cause and the next '
        'request will start this again. Last error: $e',
      );
      _shutDown();
      return;
    }
    _unreadableSince = null;

    if (pending > 0) {
      _log.info('Idle, but $pending scan(s) outstanding — staying up.');
      // Deliberately does *not* reset the idle clock. The moment the queue
      // drains, the next check stops the machine rather than waiting out
      // another full idle window from a request that never came.
      return;
    }

    _log.info('No requests for ${idleAfter.inSeconds}s and nothing queued — '
        'stopping. The proxy will start this again on the next request.');
    _shutDown();
  }

  void _shutDown() {
    stop();
    _exit(0);
  }
}
