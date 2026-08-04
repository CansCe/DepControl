import 'dart:io';

import 'package:backend/src/archived_project.dart';
import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:ecosystem/ecosystem.dart';
import 'package:shared/shared.dart';

/// POST `/projects/<id>/resolve`  {package, targetConstraint}
/// Simulates the change and returns a [ResolutionResult].
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
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

  final refusal = archivedProjectRefusal(project, 'simulating a change');
  if (refusal != null) return refusal;

  final ResolutionRequest request;
  try {
    final body = await context.request.json() as Map<String, dynamic>;
    request = ResolutionRequest.fromJson(body);
  } catch (_) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {'error': 'body must be {package, targetConstraint}'},
    );
  }

  // Re-fetch the current pubspecs to resolve against live content.
  //
  // Simulation resolves against pub.dev and reads a `pubspec.yaml`, so it
  // covers Dart and nothing else — `Deps` builds the resolver with
  // `ecosystems.require('dart')` for exactly that reason. A repository without
  // one throws here, which for an npm project is the ordinary case rather than
  // a fault, and answering 500 told the caller nothing about which of the two
  // it was.
  final ManifestFiles files;
  try {
    files = await deps.gitFetcher.fetch(project.gitUrl, ref: project.ref);
  } on StateError {
    final manifest = deps.resolver.ecosystem.naming.manifest;
    return Response.json(
      statusCode: HttpStatus.conflict,
      body: {
        'error': 'Simulating a change needs a $manifest, and '
            '${project.gitUrl} (${project.ref}) has none. Resolution covers '
            '${deps.resolver.ecosystem.displayName} only.',
      },
    );
  }

  final result = await deps.resolver.simulate(files, request);

  return Response.json(body: result.toJson());
}
