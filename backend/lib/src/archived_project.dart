import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:shared/shared.dart';

/// The response for an operation that an archived project will not do.
///
/// Archiving means "stop working on this". A snapshot that keeps re-fetching a
/// repository and re-querying pub.dev is not archived in any sense that matters
/// — it still costs requests, still ages, and still competes for the caller's
/// rate limit. So everything that reaches outward refuses here, and only the
/// stored report remains readable.
///
/// 409 rather than 403: the request is well-formed and the caller is entitled
/// to make it, but the project is in a state that does not accept it. Restoring
/// the project makes the same request work.
Response? archivedProjectRefusal(Project project, String action) {
  if (!project.isArchived) return null;

  return Response.json(
    statusCode: HttpStatus.conflict,
    body: {
      'error': '${project.name} is archived',
      'reason': 'Archived projects are kept as a snapshot, so $action is not '
          'available. Restore it to work on it again.',
    },
  );
}
