import 'dart:io';

import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:backend/src/services/changelog_aggregator.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:shared/shared.dart';

/// GET `/projects/<id>/changes` -> what changed between two of this project's
/// stored reports.
///
/// With no arguments, the two newest revisions: "what changed last time
/// anything did". `?from=<revision>&to=<revision>` compares any two, in either
/// order — the caller says which is the baseline and this does not second-guess
/// it, so comparing forwards and backwards are both legitimate questions.
///
/// A pure comparison of two stored documents. No outbound call, so it is not
/// rate limited and it works for an archived project: what a project depended
/// on, and when that changed, are facts about snapshots already taken.
///
/// The answer is derived rather than stored. Two reports and this endpoint
/// always produce the same diff, so nothing has to be migrated when the
/// comparison learns to notice something new.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final deps = context.read<Deps>();
  final user = context.read<AuthUser>();

  final project = await deps.repository.byId(id, ownerId: user.id);
  if (project == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: {'error': 'project not found'},
    );
  }

  final query = context.request.uri.queryParameters;
  final fromId = query['from'];
  final toId = query['to'];

  // Both or neither. One alone is ambiguous — comparing a named revision
  // against "the newest" reads reasonably until the newest *is* the named one,
  // and answering an ambiguous request with a plausible number is worse than
  // saying what was wrong with it.
  if ((fromId == null) != (toId == null)) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {
        'error': 'give both from and to, or neither',
      },
    );
  }

  final DepReport? from;
  final DepReport? to;

  if (fromId != null && toId != null) {
    from = await deps.repository.reportAt(id, fromId);
    to = await deps.repository.reportAt(id, toId);
    if (from == null || to == null) {
      return Response.json(
        statusCode: HttpStatus.notFound,
        body: {'error': 'no such revision for this project'},
      );
    }
  } else {
    final revisions = await deps.repository.revisionsFor(id, limit: 2);
    if (revisions.length < 2) {
      // Not an error: a project scanned once, or scanned repeatedly and never
      // changed, has a real and reportable answer — nothing has changed yet.
      // A 404 here would read as "this project is unknown".
      return Response.json(
        body: {
          'projectId': id,
          'packages': <Object>[],
          'summary': const {
            'added': 0,
            'removed': 0,
            'moved': 0,
            'breaking': 0,
            'newlyVulnerable': 0,
          },
          'note': revisions.isEmpty
              ? 'No report for this project yet.'
              : 'Only one revision so far, so there is nothing to compare it '
                  'with.',
        },
      );
    }

    // revisionsFor is newest first, so the older of the two is the baseline.
    to = await deps.repository.reportAt(id, revisions[0].id);
    from = await deps.repository.reportAt(id, revisions[1].id);
    if (from == null || to == null) {
      return Response.json(
        statusCode: HttpStatus.notFound,
        body: {'error': 'no such revision for this project'},
      );
    }
  }

  final diff = ReportDiff.between(from, to);
  final body = diff.toJson();

  // `?changelogs=true` adds what each moved package's author wrote about the
  // move. Opt-in because it is a second read per moved package, and because a
  // first request for an unread package queues a fetch — a caller that only
  // wants the version numbers should not be filling a backlog.
  if (context.request.uri.queryParameters['changelogs'] == 'true') {
    final changelogs =
        await ChangelogAggregator(deps.changelogs).forDiff(diff);
    body['changelogs'] = [for (final each in changelogs) each.toJson()];
  }

  return Response.json(body: body);
}
