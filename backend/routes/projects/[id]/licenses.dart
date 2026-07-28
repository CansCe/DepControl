import 'dart:io';

import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:shared/shared.dart';

/// GET `/projects/<id>/licenses` -> every dependency's license, judged against
/// the caller's policy.
///
/// `?format=csv` returns the same thing as a manifest to hand to whoever signs
/// off on shipping. JSON otherwise.
///
/// Reads the *stored* report and evaluates it, which is the entire request —
/// there is no outbound call here. Two things follow from that. It is not rate
/// limited, and it works for an archived project: a license is a fact about the
/// versions in the snapshot, the same way an advisory is, rather than a
/// comparison against pub.dev as it is today. Re-analyze first if the report is
/// old and you want today's dependencies.
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
  if (report == null) {
    return Response.json(
      statusCode: HttpStatus.notFound,
      body: {'error': 'no report for this project yet'},
    );
  }

  final stored = await deps.licensePolicies.forOwner(user.id);
  final licenses = LicenseReport.of(report, stored.policy);

  if (context.request.uri.queryParameters['format'] == 'csv') {
    return Response(
      body: licenses.toCsv(),
      headers: {
        'Content-Type': 'text/csv; charset=utf-8',
        'Content-Disposition':
            'attachment; filename="${_manifestFilename(project)}"',
      },
    );
  }

  return Response.json(
    body: {
      'report': licenses.toJson(),
      // Whether anyone actually wrote these rules. A reader looking at a
      // forbidden dependency needs to know whether they are reading their
      // company's decision or this app's default.
      'policyIsCustom': stored.isCustom,
    },
  );
}

/// `demo-licenses-2026-07-28.csv`.
///
/// Dated because this is a document someone files, and two of them a quarter
/// apart are the point. The project name is reduced to characters that survive
/// a `Content-Disposition` header and a filesystem — it comes from a fetched
/// `pubspec.yaml`, so it is not this server's to trust.
String _manifestFilename(Project project) {
  final name = project.name
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9._-]+'), '-')
      .replaceAll(RegExp('^-+|-+\$'), '');
  final date =
      DateTime.now().toUtc().toIso8601String().split('T').first;
  return '${name.isEmpty ? 'project' : name}-licenses-$date.csv';
}
