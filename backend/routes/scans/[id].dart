// Dart Frog's dynamic-route segments are bracketed by design.
// ignore_for_file: file_names

import 'dart:io';

import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:backend/src/services/scan_watch.dart';
import 'package:dart_frog/dart_frog.dart';

/// GET `/scans/<id>` -> what the scan the caller asked for is doing.
///
/// The scan is a job now, not a request, so this is no longer a side channel
/// onto an open connection — it is the only channel. A client that closed the
/// page, reloaded, or moved to another device reads the scan's state from here.
///
/// **Owner-scoped**, which it was not while progress lived in a map keyed only
/// by an id the client invented: a guessed id used to read somebody else's
/// scan. A scan belonging to another owner is 404 rather than 403, matching
/// `ProjectRepository` — a 403 would confirm the id exists.
///
/// 404 is still an ordinary answer rather than a failure, but it now means
/// something narrower: no such scan for this caller, rather than "not on this
/// machine". A scan that is running somewhere else is found here.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final scanId = scanIdFrom(id);
  if (scanId == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: {'error': 'no such scan'},
    );
  }

  final deps = context.read<Deps>();
  final user = context.read<AuthUser>();
  final job = await deps.scanJobs.byId(scanId, ownerId: user.id);

  if (job == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: {'error': 'no such scan'},
    );
  }

  // The row is written at most once a second, so for a scan running on *this*
  // machine the in-memory store is fresher. Preferred when it has something,
  // which is the same reasoning as before — it is just no longer the only place
  // an answer can come from.
  final live = deps.scanProgress[scanId];
  final status = live == null || job.state.isFinished
      ? job.toStatus()
      : job.copyWith(progress: live).toStatus();

  return Response.json(body: status.toJson());
}
