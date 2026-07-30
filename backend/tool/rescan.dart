// Re-scans tracked projects, records what changed, and announces it.
//
//   dart run tool/rescan.dart --owner <uuid>
//   dart run tool/rescan.dart --all
//   dart run tool/rescan.dart --all --dry-run
//   dart run tool/rescan.dart --all --limit 5
//
// This is the scheduled half of the registry. Adding a project answers "what
// does this depend on today"; running this repeatedly answers "what changed
// since", which is the question that has to be asked by something other than a
// person.
//
// It is a CLI rather than a timer inside the server on purpose. The API is
// deployed with `min_machines_running = 0` and stops between requests, so an
// in-process schedule would fire only while somebody happened to be using the
// app — exactly when they do not need to be told. Point cron, a Fly scheduled
// machine, or a GitHub Actions workflow at this instead; see
// `.github/workflows/rescan.yml`.
//
// Needs DATABASE_URL, the same connection string the server uses. Safe to run
// twice: a change is announced at most once per target, claimed in the database
// before the request goes out.
import 'dart:io';

import 'package:backend/src/deps.dart';
import 'package:backend/src/env.dart';
import 'package:backend/src/repository/postgres_project_repository.dart';
import 'package:backend/src/services/rescan_service.dart';

Future<void> main(List<String> args) async {
  final dryRun = args.contains('--dry-run');
  final all = args.contains('--all');
  final owner = _valueOf(args, '--owner');
  final limit = int.tryParse(_valueOf(args, '--limit') ?? '');

  if (!all && owner == null) {
    stderr.writeln(
      'Give --owner <uuid> to sweep one account, or --all for every account '
      'that has a project.',
    );
    exit(64); // EX_USAGE
  }

  final url = readEnvironment()['DATABASE_URL'];
  if (url == null || url.isEmpty) {
    // The in-memory repository would report every project as brand new on
    // every run, because it starts empty — a sweep against it is not a weaker
    // answer, it is a meaningless one.
    stderr.writeln(
      'DATABASE_URL is not set. This reads the same database the server '
      'writes, and has nothing to compare against without it.',
    );
    exit(78); // EX_CONFIG
  }

  final deps = Deps();
  final notifier = deps.notifier();
  final service = RescanService(
    repository: deps.repository,
    gitFetcher: deps.gitFetcher,
    analyzer: deps.analyzer,
    notifier: notifier,
  );

  try {
    final owners = owner != null
        ? [owner]
        : await _ownersWithProjects(url);

    if (owners.isEmpty) {
      stdout.writeln('No accounts have projects to scan.');
      return;
    }

    var changed = 0;
    var failed = 0;
    var announced = 0;

    for (final each in owners) {
      final results = dryRun
          ? await _describe(deps, each, limit)
          : await service.rescanOwner(each, limit: limit);

      for (final result in results) {
        if (result.failed) {
          failed++;
          stdout.writeln('  ! ${result.project.name}: ${result.error}');
          continue;
        }
        if (!result.changed) {
          stdout.writeln('  = ${result.project.name}: unchanged');
          continue;
        }

        changed++;
        final diff = result.diff;
        final summary = diff == null
            ? 'first report'
            : '${diff.packages.length} change(s), '
                '${diff.breakingMoves.length} breaking, '
                '${diff.newlyVulnerable.length} newly vulnerable';
        stdout.writeln('  * ${result.project.name}: $summary');

        if (result.notifications case final outcome?) {
          announced += outcome.sent;
          if (outcome.considered > 0) stdout.writeln('      $outcome');
        }
      }
    }

    stdout.writeln('');
    stdout.writeln(
      dryRun
          ? 'Dry run: nothing was scanned, stored or sent.'
          : '$changed changed, $failed could not be scanned, '
              '$announced notification(s) sent.',
    );

    // A project that could not be scanned is reported and does not fail the
    // run — a repository can be deleted, renamed or made private at any time,
    // and a sweep that exits non-zero for that would page somebody every night
    // over a repository nobody has missed.
  } finally {
    notifier.close();
  }
}

/// The projects a sweep would touch, without touching them.
Future<List<RescanResult>> _describe(Deps deps, String owner, int? limit) async {
  final projects = await deps.repository.allForOwner(owner);
  final active = projects.where((p) => !p.isArchived).toList();
  final chosen = limit == null ? active : active.take(limit).toList();
  return [
    for (final project in chosen)
      RescanResult(project: project, error: 'dry run'),
  ];
}

/// Every owner with at least one project that is not archived.
///
/// Read straight from the table: the repository interface is deliberately
/// owner-scoped — every read takes an owner id, so no route can accidentally
/// serve somebody else's registry — and a sweep is the one caller that has to
/// cut across that. It is an operator CLI holding the database credential
/// rather than a request, which is the only context where that is appropriate.
Future<List<String>> _ownersWithProjects(String url) async {
  final repository = PostgresProjectRepository.fromUrl(url);
  try {
    return await repository.ownersWithActiveProjects();
  } finally {
    await repository.close();
  }
}

String? _valueOf(List<String> args, String flag) {
  final index = args.indexOf(flag);
  if (index < 0 || index + 1 >= args.length) return null;
  return args[index + 1];
}
