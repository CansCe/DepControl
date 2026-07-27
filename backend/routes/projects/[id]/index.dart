import 'dart:io';

import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:dart_frog/dart_frog.dart';

/// GET `/projects/<id>` -> the cached dependency report for a project.
///
/// Projects owned by another user are reported as 404 rather than 403, so the
/// response never confirms that an id exists.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.get) {
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

  final report = await deps.repository.reportFor(id);
  return Response.json(
    body: {
      'project': project.toJson(),
      'report': report?.toJson(),
    },
  );
}
