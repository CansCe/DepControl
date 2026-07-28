// Computes the public-API diffs the API has been asked for and could not serve.
//
//   dart run tool/fill_api_diffs.dart
//   dart run tool/fill_api_diffs.dart --limit 5
//   dart run tool/fill_api_diffs.dart --dry-run
//
// Every time someone opens a package the server has no diff for, the pair is
// recorded as wanted. This drains that backlog: for each pair it runs
// `tools/api_differ` — a separate process, with its own pinned analyzer, doing
// the archive fetching and Dart parsing that has no business in a request path
// — and stores what comes back.
//
// Run it against the same database as the server, on a schedule or by hand. It
// is safe to run twice: a pair that has been computed is no longer pending.
import 'dart:convert';
import 'dart:io';

import 'package:backend/src/repository/api_diff_store.dart';
import 'package:shared/shared.dart';

import '_api_diff_store.dart';

Future<void> main(List<String> args) async {
  final dryRun = args.contains('--dry-run');
  final limit = int.tryParse(_valueOf(args, '--limit') ?? '') ?? 20;
  final differ = _differDirectory(_valueOf(args, '--differ'));

  final (:pool, :store) = openStore();
  try {
    final pending = await store.pendingRequests(limit: limit);
    if (pending.isEmpty) {
      stdout.writeln('Nothing pending. Every diff that has been asked for '
          'is stored.');
      return;
    }

    stdout.writeln('${pending.length} comparison(s) to compute:');
    for (final request in pending) {
      stdout.writeln('  $request');
    }
    if (dryRun) return;
    stdout.writeln('');

    var stored = 0;
    for (final request in pending) {
      if (await _compute(request, differ: differ, store: store)) stored++;
    }

    stdout.writeln('');
    stdout.writeln('Stored $stored of ${pending.length}.');
    if (stored < pending.length) {
      // Failures stay pending, so the next run tries them again. A package
      // whose sources were never published will keep failing — that is visible
      // here rather than silently retried forever in the background.
      stdout.writeln('The rest are still pending and will be retried.');
    }
  } finally {
    await pool.close();
  }
}

/// Runs the differ for one pair and stores the result. Returns whether it
/// produced a diff.
Future<bool> _compute(
  ApiDiffRequest request, {
  required Directory differ,
  required ApiDiffStore store,
}) async {
  stdout.write('$request ... ');

  // The differ is not a dependency of this package — it pins an analyzer this
  // workspace cannot resolve, which is the whole reason it lives outside it —
  // so it is driven as a subprocess. Note this only ever runs from a CLI: the
  // server does not start processes.
  final result = await Process.run(
    Platform.resolvedExecutable,
    [
      'run',
      'api_differ',
      request.package,
      request.from,
      request.to,
      '--json',
    ],
    workingDirectory: differ.path,
  );

  if (result.exitCode != 0) {
    final reason = (result.stderr as String).trim();
    stdout.writeln('failed${reason.isEmpty ? '' : ' — $reason'}');
    return false;
  }

  final ApiDiff diff;
  try {
    diff = ApiDiff.fromJson(
      jsonDecode(result.stdout as String) as Map<String, dynamic>,
    );
  } catch (e) {
    stdout.writeln('failed — unreadable output ($e)');
    return false;
  }

  await store.save(diff);
  stdout.writeln('${diff.removed.length} removed, ${diff.changed.length} '
      'changed, ${diff.added.length} added');
  return true;
}

/// Locates `tools/api_differ`, which sits beside `backend/` in the repository
/// rather than inside this pub workspace.
Directory _differDirectory(String? override) {
  final path = override ??
      Platform.environment['API_DIFFER_DIR'] ??
      Platform.script.resolve('../../tools/api_differ/').toFilePath();

  final directory = Directory(path);
  if (!File('${directory.path}${Platform.pathSeparator}pubspec.yaml')
      .existsSync()) {
    stderr.writeln('No api_differ package at ${directory.path}.');
    stderr.writeln('Pass --differ <dir> or set API_DIFFER_DIR.');
    exit(2);
  }
  return directory;
}

String? _valueOf(List<String> args, String flag) {
  final index = args.indexOf(flag);
  if (index >= 0 && index + 1 < args.length) return args[index + 1];

  final inline = args.firstWhere(
    (a) => a.startsWith('$flag='),
    orElse: () => '',
  );
  return inline.isEmpty ? null : inline.substring(flag.length + 1);
}
