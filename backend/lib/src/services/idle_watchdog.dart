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
    required this.idleAfter,
    // Required rather than defaulted to `dart:io`'s: this ends the process, and
    // a default would let a test that wandered into it take the runner down.
    required void Function(int code) exit,
    this.checkInterval = const Duration(seconds: 15),
  })  : _pendingWork = pendingWork,
        _exit = exit;

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

  final Duration checkInterval;
  final void Function(int code) _exit;

  static final _log = log.tagged('idle');

  DateTime _lastRequest = DateTime.now();
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

    final int pending;
    try {
      pending = await _pendingWork();
    } catch (e) {
      // Cannot tell whether there is work, so do not stop. Staying up costs
      // money; stopping on top of a running scan costs the scan.
      _log.warn('Could not read the scan queue, staying up: $e');
      return;
    }

    if (pending > 0) {
      _log.info('Idle, but $pending scan(s) outstanding — staying up.');
      // Deliberately does *not* reset the idle clock. The moment the queue
      // drains, the next check stops the machine rather than waiting out
      // another full idle window from a request that never came.
      return;
    }

    _log.info('No requests for ${idleAfter.inSeconds}s and nothing queued — '
        'stopping. The proxy will start this again on the next request.');
    stop();
    _exit(0);
  }
}
