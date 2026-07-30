import 'dart:io';

import 'package:backend/src/archived_project.dart';
import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:backend/src/services/scan_watch.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:shared/shared.dart';

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

  // Optional, and read leniently: a POST with no body at all is still a valid
  // refresh, and was the only shape this endpoint accepted until now.
  final progress = scanSinkFor(deps, await _scanId(context));

  try {
    progress.phase(ScanPhase.fetching);
    final files =
        await deps.gitFetcher.fetchAll(project.gitUrl, ref: project.ref);
    final report = await deps.analyzer.analyzeRepository(
      project.id,
      files,
      progress: progress,
    );

    final updated = project.copyWith(lastCheckedAt: DateTime.now().toUtc());
    progress.phase(ScanPhase.saving);
    await deps.repository.add(updated);
    await deps.repository.saveReport(report);
    progress.phase(ScanPhase.done);

    return Response.json(
      body: {'project': updated.toJson(), 'report': report.toJson()},
    );
  } on StateError catch (e) {
    // The repository moved, was made private, or lost its pubspec.
    progress.failed(e.message);
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {'error': e.message},
    );
  } on UnsupportedError catch (e) {
    progress.failed('${e.message}');
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {'error': e.message},
    );
  }
}

Future<Object?> _scanId(RequestContext context) async {
  try {
    final body = await context.request.json();
    return body is Map<String, dynamic> ? body['scanId'] : null;
  } catch (_) {
    // No body, or not JSON. Neither is an error here — it just means nobody is
    // watching this scan.
    return null;
  }
}
