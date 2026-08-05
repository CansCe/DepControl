import 'dart:io';

import 'package:dart_frog/dart_frog.dart';
import 'package:shared/shared.dart';

/// The response for an operation that needs a repository this server cannot
/// reach.
///
/// A local project was collected on somebody else's machine and uploaded already
/// parsed. That is the feature, and it is also a limit: the server holds the
/// project's *dependency facts* and never held its files. Anything that needs to
/// read the manifest again — simulating a constraint change, planning a
/// remediation, re-fetching the repository — has nothing to read.
///
/// 409 for the same reason [archivedProjectRefusal] gives: the request is
/// well-formed and the caller is entitled to make it, but the project is in a
/// state that does not accept it. Unlike archiving, the caller cannot fix this
/// from the UI — so the message says what they can do instead, which is to run
/// the collector again on the machine that has the repository.
Response? localProjectRefusal(
  Project project,
  String action, {
  String? because,
}) {
  if (!project.isLocal) return null;

  return Response.json(
    statusCode: HttpStatus.conflict,
    body: {
      'error': '${project.name} was uploaded, not fetched',
      'reason': because ??
          '$action needs this repository\'s files, and a local project is '
              'collected on your own machine and uploaded as a dependency list. '
              'Run `depcontrol collect` there and upload the bundle again.',
    },
  );
}
