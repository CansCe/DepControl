import 'dart:io';

import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:backend/src/services/bundle_ingest.dart';
import 'package:dart_frog/dart_frog.dart';

/// POST `/projects/<id>/bundle` -> queue a re-analysis from a fresh bundle, 202.
///
/// What `refresh` is for a git project. A local project cannot be re-fetched —
/// its repository is somewhere this server has never been — so bringing it up to
/// date means running `depcontrol collect` again on the machine that has it and
/// uploading the result here.
///
/// Deliberately keyed on the existing project rather than creating a second one.
/// Uploading the same repository twice through `POST /projects` would leave two
/// projects with two histories describing the same thing, and the version
/// timeline this application exists to keep would be split down the middle.
Future<Response> onRequest(RequestContext context, String id) async {
  if (context.request.method != HttpMethod.post) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }

  final deps = context.read<Deps>();
  final user = context.read<AuthUser>();

  if (bundleTooLarge(
    context.request.headers[HttpHeaders.contentLengthHeader],
  )) {
    return Response.json(
      statusCode: HttpStatus.requestEntityTooLarge,
      body: {
        'error': 'A bundle may be at most ${BundleIngest.maxBytes} bytes. A '
            'real one is a few tens of kilobytes.',
      },
    );
  }

  final Map<String, dynamic> body;
  try {
    body = await context.request.json() as Map<String, dynamic>;
  } catch (_) {
    return Response.json(
      statusCode: HttpStatus.badRequest,
      body: {'error': 'body must be {scanId, bundle}'},
    );
  }

  final outcome = await ingestBundle(
    deps,
    ownerId: user.id,
    rawBundle: body['bundle'],
    rawScanId: body['scanId'],
    projectId: id,
  );

  return outcome.refusal ??
      Response.json(
        statusCode: HttpStatus.accepted,
        body: outcome.status!.toJson(),
      );
}
