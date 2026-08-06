import 'dart:io';

import 'package:backend/src/deps.dart';
import 'package:backend/src/services/bundle_ingest.dart';
import 'package:backend/src/services/collector_code.dart';
import 'package:dart_frog/dart_frog.dart';

/// POST `/collector/bundles` -> claim a pairing code and queue the bundle it
/// carries, 202.
///
/// Body is `{code, scanId, bundle}`. The credential is the code, not a
/// session — this is what the collector binary posts to instead of ever
/// holding a Supabase JWT. [CollectorSessionStore.claim] spends it before
/// anything else happens; a code that is wrong, already used, or expired all
/// answer the same way, since only the person holding a live code has any
/// business learning which of those it was.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final deps = context.read<Deps>();

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
      body: {'error': 'body must be {code, scanId, bundle}'},
    );
  }

  final code = body['code'] as String?;
  if (code == null || code.isEmpty) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {'error': 'code is required'},
    );
  }

  final grant = await deps.collectorSessions.claim(CollectorCode.hash(code));
  if (grant == null) {
    return Response.json(
      statusCode: HttpStatus.unauthorized,
      body: {
        'error': 'That pairing code is not open',
        'reason': 'It may be wrong, already used, or older than fifteen '
            'minutes. Mint a new one from the registry screen.',
      },
    );
  }

  final outcome = await ingestBundle(
    deps,
    ownerId: grant.ownerId,
    rawBundle: body['bundle'],
    rawScanId: body['scanId'],
    projectId: grant.projectId,
  );

  // The session is spent either way — a claim is single-use even when what it
  // unlocked turned out to be a bad bundle. Only a successful queue gets a
  // scan id worth remembering; a refusal leaves the session claimed and
  // scan-less, and the page reads that as "claimed, ask again with a fresh
  // code" rather than as still waiting.
  if (outcome.status != null) {
    await deps.collectorSessions.attachScan(grant.id, outcome.status!.scanId);
  }

  return outcome.refusal ??
      Response.json(
        statusCode: HttpStatus.accepted,
        body: outcome.status!.toJson(),
      );
}
