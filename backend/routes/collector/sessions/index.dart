import 'dart:io';

import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:backend/src/services/collector_code.dart';
import 'package:dart_frog/dart_frog.dart';

/// POST `/collector/sessions` -> mint a pairing code, 201.
///
/// Optional `{projectId}` in the body: set, the session re-uploads to an
/// existing project once claimed; absent, it creates one. The same two shapes
/// `POST /projects` and `POST /projects/<id>/bundle` already have, decided
/// here instead of at claim time because the web page minting the code
/// already knows which project it is pairing for, if any.
///
/// The code is returned here and **only** here — `GET /collector/sessions/<id>`
/// never carries it. See `CollectorCode` for what travels instead, and the
/// README for what a live code can and cannot do.
Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final deps = context.read<Deps>();
  final user = context.read<AuthUser>();

  var body = const <String, dynamic>{};
  try {
    final raw = await context.request.json();
    if (raw is Map<String, dynamic>) body = raw;
  } on Object {
    // An empty or absent body mints a session for a new project — the common
    // case, and nobody should have to send `{}` to reach it.
  }

  final projectId = body['projectId'] as String?;
  if (projectId != null) {
    final project = await deps.repository.byId(projectId, ownerId: user.id);
    if (project == null) {
      return Response.json(
        statusCode: HttpStatus.notFound,
        body: {'error': 'project not found'},
      );
    }
  }

  final code = CollectorCode.generate();
  final grant = await deps.collectorSessions.mint(
    ownerId: user.id,
    codeHash: CollectorCode.hash(code),
    expiresAt: DateTime.now().toUtc().add(_ttl),
    projectId: projectId,
  );

  return Response.json(
    statusCode: HttpStatus.created,
    body: {
      'id': grant.id,
      'code': code,
      'expiresAt': grant.expiresAt.toUtc().toIso8601String(),
    },
  );
}

/// How long a code stays open. Long enough to download the collector and run
/// it, short enough that a code left in a chat log or a screenshot is not a
/// standing risk.
const _ttl = Duration(minutes: 15);
