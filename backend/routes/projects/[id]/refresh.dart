import 'dart:io';

import 'package:backend/src/archived_project.dart';
import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:dart_frog/dart_frog.dart';

/// POST `/projects/<id>/refresh` -> re-fetch the repository and re-analyze it.
///
/// A report describes the dependency set at the moment it was generated, so it
/// goes stale as soon as anything publishes a new version or an advisory. This
/// re-runs the analysis for an existing project in place, replacing its report
/// and stamping `lastCheckedAt`, rather than creating a second project the way
/// re-adding the same git URL would.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
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

  final refusal = archivedProjectRefusal(project, 're-analysis');
  if (refusal != null) return refusal;

  try {
    final files =
        await deps.gitFetcher.fetchAll(project.gitUrl, ref: project.ref);
    final report = await deps.analyzer.analyzeRepository(project.id, files);

    final updated = project.copyWith(lastCheckedAt: DateTime.now().toUtc());
    await deps.repository.add(updated);
    await deps.repository.saveReport(report);

    return Response.json(
      body: {'project': updated.toJson(), 'report': report.toJson()},
    );
  } on StateError catch (e) {
    // The repository moved, was made private, or lost its pubspec.
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {'error': e.message},
    );
  } on UnsupportedError catch (e) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {'error': e.message},
    );
  }
}
