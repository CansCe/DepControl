// Stores one public-API diff produced by `tools/api_differ`.
//
//   dart run api_differ yaml 3.1.2 3.1.3 --json | dart run tool/import_api_diff.dart
//   dart run tool/import_api_diff.dart yaml-diff.json
//
// The API serves these and never computes them, so this is how a comparison
// gets in. For the whole backlog at once, use tool/fill_api_diffs.dart.
import 'dart:convert';
import 'dart:io';

import 'package:shared/shared.dart';

import '_api_diff_store.dart';

Future<void> main(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.length > 1) {
    stderr.writeln('usage: dart run tool/import_api_diff.dart [file.json]');
    stderr.writeln('       (reads stdin when no file is given)');
    exit(64);
  }

  final raw = positional.isEmpty
      ? await _readStdin()
      : await File(positional.single).readAsString();

  if (raw.trim().isEmpty) {
    stderr.writeln('No JSON on stdin. Pipe `api_differ ... --json` into this, '
        'or pass a file.');
    exit(64);
  }

  final ApiDiff diff;
  try {
    diff = ApiDiff.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  } catch (e) {
    // Most likely the differ printed an error, or its output format moved.
    stderr.writeln('That is not an api_differ diff: $e');
    exit(65);
  }

  final (:pool, :store) = openStore();
  try {
    await store.save(diff);
  } finally {
    await pool.close();
  }

  stdout.writeln('Stored ${diff.package} ${diff.from} -> ${diff.to}: '
      '${diff.removed.length} removed, ${diff.changed.length} changed, '
      '${diff.added.length} added.');
}

Future<String> _readStdin() => stdin.transform(utf8.decoder).join();
