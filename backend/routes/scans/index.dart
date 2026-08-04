import 'dart:io';

import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:backend/src/repository/scan_job_store.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:shared/shared.dart';

/// GET `/scans` -> the caller's scans that have not finished.
///
/// This is what makes a durable scan visible. The work carries on when the page
/// closes, and without this the client that comes back has no way to know: it
/// would show nothing, and the person would start the same scan again.
///
/// Unfinished only. A history of completed scans is a different feature and one
/// the report revisions already answer better — this is "what is happening
/// right now", and the answer is usually an empty list.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final deps = context.read<Deps>();
  final user = context.read<AuthUser>();
  final jobs = await deps.scanJobs.unfinishedFor(user.id);

  return Response.json(
    body: {
      'scans': [
        for (final job in jobs) _statusOf(deps, job).toJson(),
      ],
    },
  );
}

/// Same freshness rule as `GET /scans/<id>`: the row is written at most once a
/// second, so a scan running on *this* machine is described better by memory.
ScanStatus _statusOf(Deps deps, ScanJob job) {
  final live = deps.scanProgress[job.id];
  return live == null ? job.toStatus() : job.copyWith(progress: live).toStatus();
}
