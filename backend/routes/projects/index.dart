import 'dart:io';

import 'package:backend/src/deps.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:shared/shared.dart';
import 'package:uuid/uuid.dart';

/// GET  /projects        -> list tracked projects
/// POST /projects        -> ingest a project by git URL, returns the report
Future<Response> onRequest(RequestContext context) async {
  final deps = context.read<Deps>();
  switch (context.request.method) {
    case HttpMethod.get:
      final projects = await deps.repository.all();
      return Response.json(
        body: {'projects': projects.map((p) => p.toJson()).toList()},
      );
    case HttpMethod.post:
      return _add(context, deps);
    default:
      return Response(statusCode: HttpStatus.methodNotAllowed);
  }
}

Future<Response> _add(RequestContext context, Deps deps) async {
  final body = await context.request.json() as Map<String, dynamic>;
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

    // Parse the name from the report's first pass by analyzing.
    final report = await deps.analyzer.analyze(id, files);
    final project = Project(
      id: id,
      gitUrl: gitUrl,
      name: _nameFromReport(report) ?? _repoName(gitUrl),
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

String? _nameFromReport(DepReport r) => null; // name lives in pubspec; see TODO
String _repoName(String gitUrl) =>
    Uri.parse(gitUrl).pathSegments.isNotEmpty
        ? Uri.parse(gitUrl).pathSegments.last.replaceAll('.git', '')
        : gitUrl;
