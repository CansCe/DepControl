import 'dart:io';

import 'package:backend/src/deps.dart';
import 'package:dart_frog/dart_frog.dart';

/// GET `/projects/<id>` -> the cached dependency report for a project.
Future<Response> onRequest(RequestContext context, String id) async {
  final deps = context.read<Deps>();
  final project = await deps.repository.byId(id);
  if (project == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: {'error': 'project not found'},
    );
  }
  final report = await deps.repository.reportFor(id);
  return Response.json(
    body: {
      'project': project.toJson(),
      'report': report?.toJson(),
    },
  );
}
