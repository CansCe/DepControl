import 'dart:io';

import 'package:backend/src/archived_project.dart';
import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:backend/src/repository/scan_job_store.dart';
import 'package:backend/src/services/bundle_ingest.dart';
import 'package:backend/src/services/scan_watch.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:shared/shared.dart';

/// POST `/projects/<id>/bundle` -> queue a re-analysis from a fresh bundle, 202.
///
/// What `refresh` is for a git project. A local project cannot be re-fetched —
/// its repository is somewhere this server has never been — so bringing it up to
/// date means running `depcontrol collect` again on the machine that has it and
/// uploading the result here.
///
/// Deliberately keyed on the existing project rather than creating a second one.
/// Uploading the same repository twice through `POST /projects` would leave two
/// projects with two histories describing the same thing, and the version
/// timeline this application exists to keep would be split down the middle.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final deps = context.read<Deps>();
  final user = context.read<AuthUser>();

  if (bundleTooLarge(
    context.request.headers[HttpHeaders.contentLengthHeader],
  )) {
    return Response.json(
      statusCode: HttpStatus.requestEntityTooLarge,
      body: {
        'error': 'A bundle may be at most ${BundleIngest.maxBytes} bytes. A '
            'real one is a few tens of kilobytes.',
      },
    );
  }

  final project = await deps.repository.byId(id, ownerId: user.id);
  if (project == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: {'error': 'project not found'},
    );
  }

  final refusal = archivedProjectRefusal(project, 're-analysis');
  if (refusal != null) return refusal;

  // A git project is refused, and this is the mirror of `refresh` refusing a
  // local one. Not because converting would be wrong — a repository that moves
  // behind a VPN is a real case — but because a project that is fetched
  // *sometimes* and uploaded *sometimes* has a freshness nobody can state: half
  // its history would be as of a server scan and half as of somebody's laptop,
  // with nothing on the row to say which. Converting a project deserves its own
  // decision rather than being a side effect of an upload.
  if (!project.isLocal) {
    return Response.json(
      statusCode: HttpStatus.conflict,
      body: {
        'error': '${project.name} is fetched from a repository',
        'reason': 'This project has a git URL, so it is brought up to date '
            'with POST /projects/<id>/refresh. Bundles are for repositories '
            'this server cannot reach.',
      },
    );
  }

  final Map<String, dynamic> body;
  try {
    body = await context.request.json() as Map<String, dynamic>;
  } catch (_) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {'error': 'body must be {scanId, bundle}'},
    );
  }

  final CollectedBundle bundle;
  try {
    bundle = readBundle(body['bundle'], ecosystems: deps.ecosystems);
  } on FormatException catch (e) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {'error': e.message},
    );
  }

  final scanId = scanIdFrom(body['scanId']);
  if (scanId == null) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {
        'error': 'scanId is required: 1-$kMaxScanIdLength characters of '
            'A-Z, a-z, 0-9, dot, dash or underscore',
      },
    );
  }

  // Uploading twice is somebody checking whether the first upload registered,
  // as with re-analyze. The difference is that here the second upload carries a
  // *newer reading* of the repository — so the running job is returned rather
  // than a second one queued, and the caller can upload again once it finishes.
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
      bundle: bundle,
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
