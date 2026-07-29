import 'dart:io';

import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:dart_frog/dart_frog.dart';

/// GET `/projects/<id>/history` -> the states this project's dependencies have
/// been in, newest first.
///
/// A revision per *change*, not per scan. A project re-scanned nightly and
/// never touched has one revision with a widening window, which is the honest
/// answer: the alternative is a list of three hundred identical entries with
/// the four that matter somewhere inside it.
///
/// Summaries only — id, when the state was first and last seen, the commit
/// where one was recorded, and the counts. `?revision=<id>` returns that
/// revision's full report instead; a history of a 400-package project is a
/// great deal of JSON to send so a list can print three numbers per row.
///
/// Reads stored rows and makes no outbound call, so it is not rate limited and
/// it works for an archived project. An archived project is frozen, not
/// erased — what it depended on, and when that changed, are facts about the
/// snapshots already taken.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final deps = context.read<Deps>();
  final user = context.read<AuthUser>();

  // Ownership first, and by the same rule as everywhere else: a project owned
  // by someone else is a 404, because a 403 would confirm the id exists.
  final project = await deps.repository.byId(id, ownerId: user.id);
  if (project == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: {'error': 'project not found'},
    );
  }

  final revisionId = context.request.uri.queryParameters['revision'];
  if (revisionId != null) {
    final report = await deps.repository.reportAt(id, revisionId);
    if (report == null) {
      return Response.json(
        statusCode: HttpStatus.notFound,
        body: {'error': 'no such revision for this project'},
      );
    }
    return Response.json(body: report.toJson());
  }

  final limit = _limit(context.request.uri.queryParameters['limit']);
  final revisions = await deps.repository.revisionsFor(id, limit: limit);

  return Response.json(
    body: {
      'projectId': id,
      'revisions': [for (final revision in revisions) revision.toJson()],
    },
  );
}

/// How many revisions to return.
///
/// Clamped rather than rejected: a caller asking for a thousand gets the
/// maximum, which is a more useful answer than an error, and a garbled value
/// gets the default rather than deciding the size of a query.
int _limit(String? raw) {
  const fallback = 50;
  const most = 100;

  final parsed = raw == null ? null : int.tryParse(raw);
  if (parsed == null || parsed < 1) return fallback;
  return parsed > most ? most : parsed;
}
