import 'dart:io';

import 'package:backend/src/deps.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:shared/shared.dart';

/// POST `/projects/<id>/resolve`  {package, targetConstraint}
/// Simulates the change and returns a [ResolutionResult].
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }
  final deps = context.read<Deps>();
  final project = await deps.repository.byId(id);
  if (project == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: {'error': 'project not found'},
    );
  }

  final body = await context.request.json() as Map<String, dynamic>;
  final request = ResolutionRequest.fromJson(body);

  // Re-fetch the current pubspecs to resolve against live content.
  final files = await deps.gitFetcher.fetch(project.gitUrl, ref: project.ref);
  final result = await deps.resolver.simulate(files, request);

  return Response.json(body: result.toJson());
}
