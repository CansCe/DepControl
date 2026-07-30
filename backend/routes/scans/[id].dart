// Dart Frog's dynamic-route segments are bracketed by design.
// ignore_for_file: file_names

import 'dart:io';

import 'package:backend/src/deps.dart';
import 'package:backend/src/services/scan_watch.dart';
import 'package:dart_frog/dart_frog.dart';

/// GET `/scans/<id>` -> how far the scan the caller started has got.
///
/// The scan itself is a single long POST to `/projects` or
/// `/projects/<id>/refresh`; this is the side channel that says what that
/// request is doing while it is still open. The caller invents the id and sends
/// it with the scan, so nothing has to be handed back before the work starts.
///
/// 404 is an ordinary answer, not a failure: progress lives in this process's
/// memory, so a scan that has finished and aged out, or one running on another
/// instance, is simply not here. Clients fall back to an indeterminate bar.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final scanId = scanIdFrom(id);
  final progress = scanId == null ? null : context.read<Deps>().scanProgress[scanId];

  if (progress == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: {'error': 'no progress for this scan'},
    );
  }

  return Response.json(body: progress.toJson());
}
