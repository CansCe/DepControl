// Dart Frog derives the route parameter from the file name, so the brackets
// are required here and the lint cannot be satisfied.
// ignore_for_file: file_names

import 'dart:io';

import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:pubspec_parse/pubspec_parse.dart';

/// GET `/projects/<id>/upgrade/<package>` -> what moving a dependency to the
/// latest published version actually changes.
///
/// Computed on demand rather than stored with the report: it only matters when
/// someone is looking at one package, and it would otherwise go stale with
/// every new release.
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
    projectSdk = Pubspec.parse(files.pubspecYaml).environment['sdk']?.toString();
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
      body: {
        'impact': null,
        'reason': 'Nothing to compare — the installed version is unknown or '
            'already the newest published.',
      },
    );
  }

  return Response.json(body: {'impact': impact.toJson()});
}
