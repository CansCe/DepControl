// Dart Frog's dynamic-route segments are bracketed by design.
// ignore_for_file: file_names

import 'dart:io';

import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:dart_frog/dart_frog.dart';

/// DELETE `/notifications/<id>` — stop announcing to this target.
///
/// Deleting rather than disabling: a target is a webhook URL, and the reason to
/// remove one is usually that the URL should no longer be held. Keeping a
/// disabled row would keep the credential.
///
/// A target owned by somebody else is a 404 rather than a 403, the same rule
/// projects follow — a 403 would confirm the id exists.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.delete) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final deps = context.read<Deps>();
  final user = context.read<AuthUser>();

  final deleted = await deps.notifications.delete(id, ownerId: user.id);
  if (!deleted) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: {'error': 'notification target not found'},
    );
  }

  return Response(statusCode: HttpStatus.noContent);
}
