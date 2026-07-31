// Reads the release notes the API has been asked for and could not serve.
//
//   dart run tool/fill_changelogs.dart
//   dart run tool/fill_changelogs.dart --limit 5
//   dart run tool/fill_changelogs.dart --dry-run
//
// Every time somebody opens a report with `?changelogs=true` and a moved
// package has no stored notes, the version is recorded as wanted. This drains
// that backlog: for each one it downloads the published archive, reads
// `CHANGELOG.md` out of it in memory, and stores every section it holds.
//
// A changelog is cumulative, so one archive answers a great many questions —
// reading `foo 3.0.0` stores the sections for 2.x and 1.x too, and every
// project that later crosses any part of that range is served without another
// fetch.
//
// Run it against the same database as the server, on a schedule or by hand. It
// is safe to run twice: a version that has been read is no longer pending, and
// that includes the ones that turned out to have no changelog at all.
import 'dart:io';

import 'package:backend/src/deps.dart';
import 'package:backend/src/env.dart';
import 'package:backend/src/services/changelog_reader.dart';

Future<void> main(List<String> args) async {
  final dryRun = args.contains('--dry-run');
  final limit = int.tryParse(_valueOf(args, '--limit') ?? '') ?? 20;

  final url = readEnvironment()['DATABASE_URL'];
  if (url == null || url.isEmpty) {
    // The in-memory store starts empty every run, so a backlog written by the
    // server would not be visible here — and notes written here would live in
    // this process and never be read.
    stderr.writeln(
      'DATABASE_URL is not set. This drains a backlog the server wrote, and '
      'shares nothing with it without one.',
    );
    exit(78); // EX_CONFIG
  }

  final deps = Deps();
  final reader = ChangelogReader();

  try {
    final pending = await deps.changelogs.pendingRequests(limit: limit);
    if (pending.isEmpty) {
      stdout.writeln('Nothing pending. Every changelog that has been asked '
          'for has been read.');
      return;
    }

    stdout.writeln('${pending.length} archive(s) to read:');
    for (final request in pending) {
      stdout.writeln('  $request');
    }
    if (dryRun) {
      stdout.writeln('');
      stdout.writeln('Dry run: nothing was fetched or stored.');
      return;
    }
    stdout.writeln('');

    var read = 0;
    var empty = 0;
    var failed = 0;

    for (final request in pending) {
      try {
        final entries = await reader.read(
          request.package,
          request.version,
          ecosystem: request.ecosystem,
        );

        await deps.changelogs.saveRead(
          request.package,
          ecosystem: request.ecosystem,
          version: request.version,
          entries: entries,
        );

        if (entries.isEmpty) {
          empty++;
          // Recorded as read, so it leaves the backlog. A package that ships no
          // changelog would otherwise be asked for every day forever.
          stdout.writeln('  = $request: no changelog');
        } else {
          read++;
          stdout.writeln('  * $request: ${entries.length} section(s)');
        }
      } on ChangelogUnavailable catch (e) {
        failed++;
        // Stored as a failed read rather than left pending. The reason is kept
        // so an archive that is too large, or a host that will not answer, is
        // visible here instead of being retried silently forever.
        await deps.changelogs.saveRead(
          request.package,
          ecosystem: request.ecosystem,
          version: request.version,
          entries: const [],
          failure: e.reason,
        );
        stdout.writeln('  ! $request: ${e.reason}');
      }
    }

    stdout.writeln('');
    stdout.writeln('$read read, $empty with no changelog, $failed refused.');
  } finally {
    reader.close();
  }
}

String? _valueOf(List<String> args, String flag) {
  final index = args.indexOf(flag);
  if (index < 0 || index + 1 >= args.length) return null;
  return args[index + 1];
}
