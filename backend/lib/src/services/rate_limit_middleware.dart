import 'dart:io';

import 'package:dart_frog/dart_frog.dart';

import '../auth/auth_user.dart';
import '../deps.dart';
import 'logger.dart';
import 'rate_limiter.dart';

/// Limits the requests that make this server do outbound work.
///
/// Reading a stored report is a database round trip and costs nothing worth
/// counting. Adding or re-analyzing a project fetches a repository and then
/// queries pub.dev two or three times per dependency — one signed-in user can
/// turn a handful of requests into hundreds of outbound ones. That asymmetry,
/// not the request count, is what this protects: both the server and the
/// reputation of its IP address with pub.dev.
///
/// Must be applied *inside* `requireAuth`, so that the caller is known and the
/// limit is per user rather than per process. Counting anonymous traffic would
/// need a different key anyway, and there is none here — every route under
/// `/projects` is authenticated.
Middleware rateLimitOutboundWork({Logger? logger}) {
  final rate = (logger ?? log).tagged('rate');

  return (handler) {
    return (context) async {
      final limiter = context.read<Deps>().limiter;
      if (limiter == null || !_doesOutboundWork(context.request)) {
        return handler(context);
      }

      final user = context.read<AuthUser>();
      final decision = limiter.check(user.id);
      if (decision.allowed) return handler(context);

      rate.warn(
        'Rate limited ${user.id} on ${context.request.uri.path} — '
        'retry in ${decision.retryAfterSeconds}s.',
      );

      return Response.json(
        statusCode: HttpStatus.tooManyRequests,
        headers: retryAfterHeaders(decision),
        body: {
          'error': 'Too many requests',
          'reason': 'This endpoint fetches the repository and queries pub.dev, '
              'so it is rate limited. Retry in '
              '${decision.retryAfterSeconds}s.',
          'retryAfterSeconds': decision.retryAfterSeconds,
        },
      );
    };
  };
}

/// Whether serving this request means calling something else.
///
/// Every write does: adding, re-analyzing and simulating all re-fetch the
/// repository. Among reads, only the two that serve stored data are free —
/// `GET /projects` and `GET /projects/<id>`. Anything deeper (upgrade,
/// remediation) re-reads the pubspec and queries pub.dev.
///
/// Stated as "everything except these two" rather than as a list of the
/// expensive ones so that an endpoint added later is limited by default. The
/// failure mode of guessing wrong in that direction is a needless 429; the
/// other way round it is an unmetered hole.
bool _doesOutboundWork(Request request) {
  final segments = request.uri.pathSegments;

  // Archiving and deleting are single statements against the database. Charging
  // them from the same budget would mean someone tidying their registry runs
  // out of allowance for the work that actually costs something.
  final isProjectItself = segments.length == 2;
  if (isProjectItself &&
      (request.method == HttpMethod.delete ||
          request.method == HttpMethod.patch)) {
    return false;
  }

  if (request.method != HttpMethod.get) return true;

  // The license report is the third read that serves stored data: it runs the
  // caller's policy over the report already in the database and calls nothing.
  // Named here rather than left to the default because the default is a guess
  // and this is not — the endpoint's whole point is that it needs no network.
  if (segments.length == 3 && segments.last == 'licenses') return false;

  return segments.length > 2;
}
