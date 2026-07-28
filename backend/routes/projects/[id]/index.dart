import 'dart:io';

import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:dart_frog/dart_frog.dart';

/// `/projects/<id>`
///
/// * `GET` -> the cached dependency report for a project.
/// * `PATCH` `{archived: bool}` -> archive or restore it.
/// * `DELETE` -> remove it and its report.
///
/// Projects owned by another user are reported as 404 rather than 403, so the
/// response never confirms that an id exists — including on the two methods
/// that change something, where ownership is part of the write itself rather
/// than a separate check.
Future<Response> onRequest(RequestContext context, String id) async {
  return switch (context.request.method) {
    HttpMethod.get => _get(context, id),
    HttpMethod.patch => _patch(context, id),
    HttpMethod.delete => _delete(context, id),
    _ => Response(statusCode: HttpStatus.methodNotAllowed),
  };
}

Future<Response> _get(RequestContext context, String id) async {
  final deps = context.read<Deps>();
  final user = context.read<AuthUser>();

  final project = await deps.repository.byId(id, ownerId: user.id);
  if (project == null) return _notFound();

  final report = await deps.repository.reportFor(id);
  return Response.json(
    body: {
      'project': project.toJson(),
      'report': report?.toJson(),
    },
  );
}

/// Archives or restores. Both directions live here because "undo" has to be as
/// easy to reach as the thing it undoes.
Future<Response> _patch(RequestContext context, String id) async {
  final deps = context.read<Deps>();
  final user = context.read<AuthUser>();

  final bool archived;
  try {
    final body = await context.request.json() as Map<String, dynamic>;
    archived = body['archived'] as bool;
  } catch (_) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {'error': 'body must be {archived: true|false}'},
    );
  }

  final project = await deps.repository.setArchived(
    id,
    ownerId: user.id,
    archived: archived,
  );
  if (project == null) return _notFound();

  return Response.json(body: {'project': project.toJson()});
}

Future<Response> _delete(RequestContext context, String id) async {
  final deps = context.read<Deps>();
  final user = context.read<AuthUser>();

  final deleted = await deps.repository.delete(id, ownerId: user.id);
  if (!deleted) return _notFound();

  return Response(statusCode: HttpStatus.noContent);
}

Response _notFound() => Response.json(
      statusCode: HttpStatus.notFound,
      body: {'error': 'project not found'},
    );
