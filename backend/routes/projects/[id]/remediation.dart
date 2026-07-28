import 'dart:io';

import 'package:backend/src/archived_project.dart';
import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:shared/shared.dart';

/// GET `/projects/<id>/remediation` -> a verified fix for each advisory in the
/// stored report.
///
/// Every suggestion in the response has been through the resolver, which is why
/// this is a request and not a field on the report: each candidate change costs
/// a full resolution, and the answer goes stale as soon as anything publishes.
///
/// It reads the *stored* report rather than re-analyzing, so the fixes line up
/// with the advisories the user is looking at. Re-analyze first if the report
/// is old.
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

  final refusal = archivedProjectRefusal(project, 'planning remediations');
  if (refusal != null) return refusal;

  final report = await deps.repository.reportFor(id);
  if (report == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: {'error': 'no report for this project yet'},
    );
  }

  if (report.affectedNodes.isEmpty) {
    return Response.json(
      body: RemediationPlan(projectId: id).toJson(),
    );
  }

  // Resolve against live content: a fix is only worth offering if it works
  // against the pubspec as it stands now.
  final files = await deps.gitFetcher.fetch(project.gitUrl, ref: project.ref);
  final plan = await deps.planner.plan(report, files);

  return Response.json(body: plan.toJson());
}
