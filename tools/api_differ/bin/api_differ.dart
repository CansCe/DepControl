// Compares the public API of two published versions of a pub package.
//
//   dart run api_differ http 1.2.0 2.0.0
//   dart run api_differ http 1.2.0 2.0.0 --json
//
// Runs outside the server: it fetches package archives and parses Dart, and
// neither belongs in the request path. Output is meant to be stored and served
// from there.
import 'dart:convert';
import 'dart:io';

import 'package:api_differ/api_differ.dart';

Future<void> main(List<String> args) async {
  final asJson = args.contains('--json');
  final positional = args.where((a) => !a.startsWith('--')).toList();

  if (positional.length != 3) {
    stderr.writeln('usage: dart run api_differ <package> <from> <to> [--json]');
    exit(64);
  }

  final [package, from, to] = positional;

  final ApiDiff? diff;
  try {
    diff = await compareVersions(package, from: from, to: to);
  } on ArchiveRejected catch (e) {
    stderr.writeln(e.reason);
    exit(1);
  }

  if (diff == null) {
    stderr.writeln('No sources published for $package $from or $to.');
    exit(1);
  }

  if (asJson) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(diff.toJson()));
    return;
  }

  stdout.writeln('$package $from -> $to');
  stdout.writeln('  ${diff.removed.length} removed, '
      '${diff.changed.length} changed, ${diff.added.length} added');

  if (diff.removed.isNotEmpty) {
    stdout.writeln('\nRemoved (callers of these will not compile):');
    for (final change in diff.removed) {
      stdout.writeln('  ${change.declaration}');
    }
  }

  if (diff.changed.isNotEmpty) {
    stdout.writeln('\nSignature changed:');
    for (final change in diff.changed) {
      stdout.writeln('  ${change.declaration}');
      stdout.writeln('      ${change.before}  ->  ${change.after}');
    }
  }
}
