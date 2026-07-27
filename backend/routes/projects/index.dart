import 'dart:io';

import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:shared/shared.dart';
import 'package:uuid/uuid.dart';

/// GET  /projects        -> the caller's tracked projects
/// POST /projects        -> ingest a project by git URL, returns the report
///
/// Guarded by `requireAuth` in `_middleware.dart`, so the `AuthUser` is
/// guaranteed present and every project is scoped to its owner.
Future<Response> onRequest(RequestContext context) async {
  final deps = context.read<Deps>();
  final user = context.read<AuthUser>();

  switch (context.request.method) {
    case HttpMethod.get:
      final projects = await deps.repository.allForOwner(user.id);
      return Response.json(
        body: {'projects': projects.map((p) => p.toJson()).toList()},
      );
    case HttpMethod.post:
      return _add(context, deps, user);
    default:
      return Response(statusCode: HttpStatus.methodNotAllowed);
  }
}

Future<Response> _add(
  RequestContext context,
  Deps deps,
  AuthUser user,
) async {
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
  if (gitUrl == null || gitUrl.isEmpty) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {'error': 'gitUrl is required'},
    );
  }
  final ref = (body['ref'] as String?) ?? 'HEAD';

  try {
    final files = await deps.gitFetcher.fetch(gitUrl, ref: ref);
    final id = const Uuid().v4();
    final report = await deps.analyzer.analyze(id, files);

    final project = Project(
      id: id,
      gitUrl: gitUrl,
      name: _repoName(gitUrl),
      ownerId: user.id,
      ref: ref,
      addedAt: DateTime.now().toUtc(),
    );

    await deps.repository.add(project);
    await deps.repository.saveReport(report);

    return Response.json(
      statusCode: HttpStatus.created,
      body: {'project': project.toJson(), 'report': report.toJson()},
    );
  } on StateError catch (e) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {'error': e.message},
    );
  } on UnsupportedError catch (e) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {'error': e.message},
    );
  }
}

String _repoName(String gitUrl) {
  final segments = Uri.parse(gitUrl).pathSegments;
  if (segments.isEmpty) return gitUrl;
  return segments.last.replaceAll('.git', '');
}
