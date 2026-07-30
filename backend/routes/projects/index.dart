import 'dart:io';

import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:backend/src/services/scan_watch.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:shared/shared.dart';
import 'package:uuid/uuid.dart';

/// GET  /projects              -> the caller's active projects
/// GET  /projects?archived=true -> the caller's archived projects instead
/// POST /projects              -> ingest by git URL, returns the report
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

  // The caller names its own scan so it can watch it. Optional: a client that
  // does not care — the rescan tool, an integration test — passes nothing and
  // the analysis reports to a sink that discards everything.
  final progress = scanSinkFor(deps, body['scanId']);

  try {
    progress.phase(ScanPhase.fetching);
    // Every pubspec in the repository, not just the one at its root: a
    // monorepo's other packages are dependencies of the project too.
    final files = await deps.gitFetcher.fetchAll(gitUrl, ref: ref);
    final id = const Uuid().v4();
    final report = await deps.analyzer.analyzeRepository(
      id,
      files,
      progress: progress,
    );

    final project = Project(
      id: id,
      gitUrl: gitUrl,
      name: _repoName(gitUrl),
      ownerId: user.id,
      ref: ref,
      addedAt: DateTime.now().toUtc(),
    );

    progress.phase(ScanPhase.saving);
    await deps.repository.add(project);
    await deps.repository.saveReport(report);
    progress.phase(ScanPhase.done);

    return Response.json(
      statusCode: HttpStatus.created,
      body: {'project': project.toJson(), 'report': report.toJson()},
    );
  } on StateError catch (e) {
    progress.failed(e.message);
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {'error': e.message},
    );
  } on UnsupportedError catch (e) {
    progress.failed('${e.message}');
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
