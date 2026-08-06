// Dart Frog's dynamic-route segments are bracketed by design.
// ignore_for_file: file_names

import 'dart:io';

import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:dart_frog/dart_frog.dart';

/// GET `/collector/sessions/<id>` -> what a pairing session is doing.
///
/// This is the whole of "the web listens to the tool": the page that minted
/// the code polls here, and once [CollectorSessionState.claimed] it already
/// has the `scanId` to hand straight to `ScanQueue.reattach` — no separate
/// discovery step, and no code in the answer either way.
///
/// Owner-scoped like `GET /scans/<id>`: a session belonging to someone else
/// reads as 404, not 403.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final deps = context.read<Deps>();
  final user = context.read<AuthUser>();

  final grant = await deps.collectorSessions.byId(id, ownerId: user.id);
  if (grant == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: {'error': 'no such session'},
    );
  }

  return Response.json(body: grant.toSession().toJson());
}
