import 'dart:io';

import 'package:backend/src/archived_project.dart';
import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:backend/src/repository/scan_job_store.dart';
import 'package:backend/src/services/scan_watch.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:shared/shared.dart';

/// POST `/projects/<id>/refresh` -> queue a re-fetch and re-analysis, 202.
///
/// A report describes the dependency set at the moment it was generated, so it
/// goes stale as soon as anything publishes a new version or an advisory. This
/// re-runs the analysis for an existing project in place, replacing its report
/// and stamping `lastCheckedAt`, rather than creating a second project the way
/// re-adding the same git URL would.
///
/// Queued rather than run here, for the reason `POST /projects` gives: a scan
/// that lives inside its request dies with the page that started it.
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
  final scanId = scanIdFrom(await _scanId(context));
  if (scanId == null) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {
        'error': 'scanId is required: 1-$kMaxScanIdLength characters of '
            'A-Z, a-z, 0-9, dot, dash or underscore',
      },
    );
  }

  // Pressing Re-analyze twice is somebody checking whether the first press
  // registered, not a request for two clones of the same repository. The
  // client has always guarded this; now that the queue outlives the client it
  // has to be guarded here too, where a second device can be the one asking.
  final running = await deps.scanJobs.unfinishedForProject(project.id);
  if (running != null) {
    return Response.json(
      statusCode: HttpStatus.accepted,
      body: running.toStatus().toJson(),
    );
  }

  final existing = await deps.scanJobs.byId(scanId, ownerId: user.id);
  if (existing != null) {
    return Response.json(
      statusCode: HttpStatus.accepted,
      body: existing.toStatus().toJson(),
    );
  }

  final now = DateTime.now().toUtc();
  final job = await deps.scanJobs.enqueue(
    ScanJob(
      id: scanId,
      ownerId: user.id,
      kind: ScanJobKind.refresh,
      gitUrl: project.gitUrl,
      ref: project.ref,
      projectId: project.id,
      progress: ScanProgress(
        phase: ScanPhase.queued,
        startedAt: now,
        phaseStartedAt: now,
      ),
      createdAt: now,
    ),
  );

  deps.scanRunner.wake();

  return Response.json(
    statusCode: HttpStatus.accepted,
    body: job.toStatus().toJson(),
  );
}

Future<Object?> _scanId(RequestContext context) async {
  try {
    final body = await context.request.json();
    return body is Map<String, dynamic> ? body['scanId'] : null;
  } catch (_) {
    // No body, or not JSON.
    return null;
  }
}
