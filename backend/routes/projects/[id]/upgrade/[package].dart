// Dart Frog derives the route parameter from the file name, so the brackets
// are required here and the lint cannot be satisfied.
// ignore_for_file: file_names

import 'dart:io';

import 'package:backend/src/archived_project.dart';
import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:shared/shared.dart';

/// GET `/projects/<id>/upgrade/<package>` -> what moving a dependency to the
/// latest published version actually changes.
///
/// Two answers, from two sources. `impact` comes from published metadata and is
/// computed on demand: it only matters when someone is looking at one package,
/// and it would otherwise go stale with every new release. `apiDiff` is the
/// package's public API compared between the two versions, which needs its
/// archives fetched and its sources parsed — far too slow for a request, and
/// pinned to an analyzer this workspace cannot resolve. So it is computed out
/// of process by `tools/api_differ` and only read here.
///
/// When no diff has been computed, the pair is recorded as wanted and the
/// response says so, rather than implying the API did not change.
Future<Response> onRequest(
  RequestContext context,
  String id,
  String package,
) async {
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

  final refusal = archivedProjectRefusal(project, 'upgrade detail');
  if (refusal != null) return refusal;

  final report = await deps.repository.reportFor(id);
  final node = report?.nodes.where((n) => n.name == package).firstOrNull;
  if (node == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: {'error': 'package not in this project\'s report'},
    );
  }

  // The project's own SDK range decides whether a newer version is reachable.
  String? projectSdk;
  try {
    final files = await deps.gitFetcher.fetch(project.gitUrl, ref: project.ref);
    projectSdk =
        Pubspec.parse(files.manifest).environment['sdk']?.toString();
  } catch (_) {
    // Without it the SDK check is simply skipped; everything else still holds.
  }

  final impact = await deps.inspector.inspect(
    package,
    from: node.installed,
    projectSdk: projectSdk,
  );

  if (impact == null) {
    return Response.json(
      body: const UpgradeDetails(
        reason: 'Nothing to compare — the installed version is unknown or '
            'already the newest published.',
      ).toJson(),
    );
  }

  final apiDiff = await deps.apiDiffs.find(
    package,
    from: impact.from,
    to: impact.to,
  );

  // Nothing computed this pair yet. Record it so whoever runs the differ knows
  // it is worth the archive fetch — demand comes from pages people actually
  // open, not from guessing at pub.dev.
  if (apiDiff == null) {
    await deps.apiDiffs.request(package, from: impact.from, to: impact.to);
  }

  return Response.json(
    body: UpgradeDetails(impact: impact, apiDiff: apiDiff).toJson(),
  );
}
