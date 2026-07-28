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
/// queries pub.dev once or twice per dependency — one signed-in user can turn a
/// handful of requests into hundreds of outbound ones. That asymmetry, not the
/// request count, is what this protects: both the server and the reputation of
/// its IP address with pub.dev.
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
/// repository. Among reads only the upgrade endpoint does, because it re-reads
/// the pubspec and asks pub.dev for a package's release history — listing
/// projects and reading a stored report do not.
bool _doesOutboundWork(Request request) {
  if (request.method != HttpMethod.get) return true;
  return request.uri.pathSegments.contains('upgrade');
}
