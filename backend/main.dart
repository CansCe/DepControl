import 'dart:io';

import 'package:backend/src/deps.dart';
import 'package:backend/src/env.dart';
import 'package:backend/src/services/idle_watchdog.dart';
import 'package:backend/src/services/logger.dart';
import 'package:dart_frog/dart_frog.dart';

/// Custom Dart Frog entrypoint.
///
/// It exists for one reason: this server now has work that is not a request.
/// Scans are queued in `scan_jobs` and drained by `ScanRunner`, which has to be
/// started by something — and the generated entrypoint only ever starts a
/// listener.
///
/// The second thing here is the machine's own lifecycle. `fly.toml` turns
/// `auto_stop_machines` off, because the proxy stops a machine that has no open
/// connection however busy the process is, and that is exactly what a
/// backgrounded scan looks like from outside. [IdleWatchdog] takes over: the
/// machine stops itself when there is neither a request nor a job, which is the
/// same scale-to-zero behaviour with one condition added.
Future<HttpServer> run(Handler handler, InternetAddress ip, int port) async {
  final watchdog = _startWatchdog();

  // A pass before the listener opens, so a job left behind by a machine that
  // died is picked up by the one replacing it rather than waiting for somebody
  // to happen to make a request. Not awaited: a large repository takes minutes
  // and the port should be answering long before that.
  deps.scanRunner.start();

  final server = await serve(
    watchdog == null ? handler : handler.use(_touching(watchdog)),
    ip,
    port,
  );

  // Both are best-effort on the way out. A scan interrupted by a deploy is
  // reclaimed by whichever machine drains next, which is the difference between
  // "the work is delayed" and "the work is lost".
  ProcessSignal.sigterm.watch().listen((_) async {
    log.tagged('server').info('SIGTERM — closing.');
    deps.scanRunner.stop();
    watchdog?.stop();
    await server.close();
    exit(0);
  });

  return server;
}

/// Marks the machine busy on every request, so the watchdog's idle clock means
/// what it says.
Middleware _touching(IdleWatchdog watchdog) => (handler) => (context) {
      watchdog.touch();
      return handler(context);
    };

IdleWatchdog? _startWatchdog() {
  final idleAfter = IdleWatchdog.idleFromEnvironment(readEnvironment());
  if (idleAfter == null) {
    // The default everywhere that is not the deployment asking for it, which
    // includes every local run: a dev server that shut itself down after five
    // quiet minutes would be a bug report, not a feature.
    return null;
  }

  final watchdog = IdleWatchdog(
    idleAfter: idleAfter,
    pendingWork: deps.scanJobs.pendingCount,
    exit: exit,
  )..start();
  return watchdog;
}
