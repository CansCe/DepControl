import 'dart:io';

import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:backend/src/repository/scan_job_store.dart';
import 'package:backend/src/services/bundle_ingest.dart';
import 'package:backend/src/services/git_fetcher.dart';
import 'package:backend/src/services/scan_watch.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:shared/shared.dart';

/// GET  /projects              -> the caller's active projects
/// GET  /projects?archived=true -> the caller's archived projects instead
/// POST /projects              -> queue a scan, returns 202. Either
///                                `{gitUrl}` for a repository this server can
///                                fetch, or `{bundle}` for one it cannot.
///
/// Guarded by `requireAuth` in `_middleware.dart`, so the `AuthUser` is
/// guaranteed present and every project is scoped to its owner.
Future<Response> onRequest(RequestContext context) async {
  final deps = context.read<Deps>();
  final user = context.read<AuthUser>();

  switch (context.request.method) {
    case HttpMethod.get:
      // Archived projects are a separate view rather than a flag in the same
      // list: mixing them would put the things someone chose to hide back in
      // front of them.
      final archived =
          context.request.uri.queryParameters['archived'] == 'true';
      final projects = await deps.repository.allForOwner(
        user.id,
        includeArchived: archived,
      );
      return Response.json(
        body: {
          'projects': projects
              .where((p) => p.isArchived == archived)
              .map((p) => p.toJson())
              .toList(),
        },
      );
    case HttpMethod.post:
      return _add(context, deps, user);
    default:
      return Response(statusCode: HttpStatus.methodNotAllowed);
  }
}

/// Writes the scan down and returns.
///
/// This used to clone the repository and analyze it before answering, which
/// made a scan exactly as durable as the connection that asked for it — and on
/// a deployment that scales to zero, the connection was also the only thing
/// keeping the machine alive. Closing the tab ended the scan. Now the request
/// does the part that has to be synchronous — validating the input, and saying
/// the work was accepted — and `ScanRunner` does the rest whether or not
/// anybody is still watching.
///
/// **No project is created here.** An add's project appears once its first
/// report does, exactly as before, so a git URL nobody can clone leaves nothing
/// behind for someone to tidy up.
Future<Response> _add(
  RequestContext context,
  Deps deps,
  AuthUser user,
) async {
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

  final Map<String, dynamic> body;
  try {
    body = await context.request.json() as Map<String, dynamic>;
  } catch (_) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {'error': 'body must be a JSON object'},
    );
  }

  final gitUrl = body['gitUrl'] as String?;
  final rawBundle = body['bundle'];

  // Exactly one, and said plainly. "Both" is a client bug rather than an
  // instruction to guess which one was meant, and guessing would scan a
  // repository nobody asked about.
  if ((gitUrl == null || gitUrl.isEmpty) && rawBundle == null) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {
        'error': 'gitUrl or bundle is required. Use bundle for a repository '
            'this server cannot reach — run `depcontrol collect` where the '
            'repository is.',
      },
    );
  }
  if (gitUrl != null && gitUrl.isNotEmpty && rawBundle != null) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {'error': 'give either gitUrl or bundle, not both'},
    );
  }

  final ref = (body['ref'] as String?) ?? 'HEAD';

  CollectedBundle? bundle;
  if (rawBundle != null) {
    try {
      bundle = readBundle(rawBundle, ecosystems: deps.ecosystems);
    } on FormatException catch (e) {
      return Response.json(
        statusCode: HttpStatus.badRequest,
        body: {'error': e.message},
      );
    }
  } else {
    // Refused here rather than a minute into a queued job. This is the part of a
    // scan that can be judged without the network, and a caller who typed the
    // wrong host should hear about it now rather than read it off a failed
    // report later.
    try {
      GitFetcher.validate(gitUrl!, ref: ref);
    } on StateError catch (e) {
      return Response.json(
        statusCode: HttpStatus.badRequest,
        body: {'error': e.message},
      );
    }
  }

  // The caller names its own scan so it can start watching without waiting for
  // an id to come back. That is now also the job's primary key, which is why
  // one is required here where it used to be optional — a scan nobody can name
  // is a scan nobody can find again after closing the page.
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

  final existing = await deps.scanJobs.byId(scanId, ownerId: user.id);
  if (existing != null) {
    // The same scan asked for twice — a retried request, or a client that did
    // not hear the first answer. Returning the job it already has is the whole
    // of what "at most once" needs here.
    return Response.json(
      statusCode: HttpStatus.accepted,
      body: existing.toStatus().toJson(),
    );
  }

  final job = await deps.scanJobs.enqueue(
    ScanJob(
      id: scanId,
      ownerId: user.id,
      kind: ScanJobKind.add,
      gitUrl: bundle == null ? gitUrl : null,
      bundle: bundle,
      ref: ref,
      progress: ScanProgress(
        phase: ScanPhase.queued,
        startedAt: DateTime.now().toUtc(),
        phaseStartedAt: DateTime.now().toUtc(),
      ),
      createdAt: DateTime.now().toUtc(),
    ),
  );

  deps.scanRunner.wake();

  return Response.json(
    statusCode: HttpStatus.accepted,
    body: job.toStatus().toJson(),
  );
}
