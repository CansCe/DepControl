// Says whether DATABASE_URL points at a database this code can actually use,
// and which of the ways it cannot.
//
//   dart run tool/check_database.dart
//
// The integration tests skip when DATABASE_URL is unset and fail when it is set
// but wrong — twenty-five at once, each reporting the same single problem in
// whatever terms the query it happened to reach first produced. Twenty-five red
// tests look like twenty-five broken behaviours; they were one connection
// string. This runs before them and says so in one line.
//
// It distinguishes three failures, because the fix for each is somewhere else:
//
//   * the host does not resolve or does not answer — the connection string
//     names the wrong endpoint, and on a runner without IPv6 that is usually
//     Supabase's *direct* connection where the session pooler was meant;
//   * the credentials are refused — the password is stale or was truncated on
//     its way into the secret store;
//   * the schema is behind — a file in backend/sql/ has not been applied to
//     this database, which is the failure that looks most like a code bug.
//
// Reads only the process environment, like the server: a file on disk that
// silently overrides it is how a staging credential reaches production. The
// tests read backend/.env too, deliberately, and that difference is theirs.
//
// Every query here is a read. Nothing is created, written or dropped — this
// points at whatever DATABASE_URL points at, which is a database with real
// projects in it.
import 'dart:io';

import 'package:backend/src/env.dart';
import 'package:backend/src/repository/postgres_api_diff_store.dart';
import 'package:backend/src/repository/postgres_pool.dart';
import 'package:backend/src/repository/postgres_project_repository.dart';
import 'package:postgres/postgres.dart';

/// An id that matches nothing, so the reads below return no rows.
///
/// The point is never the result. It is that the statement plans and runs at
/// all, which is what proves the tables and columns behind it are there.
const _nobody = '00000000-0000-0000-0000-000000000000';

Future<void> main() async {
  final url = readEnvironment()['DATABASE_URL'];
  if (url == null || url.isEmpty) {
    stdout.writeln(
      'DATABASE_URL is not set. The integration tests will skip, which is the '
      'intended behaviour without a database — nothing to check.',
    );
    return;
  }

  // Only to say which endpoint is about to be tried, so a failure names it —
  // "cannot reach the database" is a different sentence when you can see it was
  // about to reach for the wrong host. Deliberately not validation: a URL this
  // cannot parse is left for `postgresPoolFromUrl` to reject below, which knows
  // to recognise the .env.example placeholder and says so in those terms.
  // Validating in two places means the worse message wins by going first.
  final parsed = Uri.tryParse(unwrapEnvValue(url));
  final where = parsed == null || parsed.host.isEmpty
      ? 'the configured host'
      : '${parsed.host}:${parsed.hasPort ? parsed.port : 5432}';
  stdout.writeln('Checking $where.');

  // Built inside the try, not before it: `postgresPoolFromUrl` rejects a URL
  // that still holds the `[YOUR-DB-PASSWORD]` placeholder, and a secret set
  // from an uncompleted copy of .env.example is exactly the mistake worth
  // catching here. Left outside, that throw would leave the job with an
  // unhandled exception instead of the sentence explaining it.
  PostgresProjectRepository? repo;
  Pool<void>? pool;

  try {
    repo = PostgresProjectRepository.fromUrl(url);
    pool = postgresPoolFromUrl(url);
    final diffs = PostgresApiDiffStore(pool);

    // Ordered by (first_seen_at, seq) and reading manifests and coverage_note,
    // so between them these four cover every column added after the original
    // schema. Calling the real repository rather than hand-written SQL is what
    // keeps that true: when a store learns a new column, this learns it too.
    await repo.allForOwner(_nobody);
    await repo.revisionsFor(_nobody, limit: 1);
    await diffs.find('depcontrol-preflight', from: '0.0.0', to: '0.0.1');
    await diffs.pendingRequests(limit: 1);
  } on ArgumentError catch (e) {
    _fail(
      'DATABASE_URL was rejected before a connection was attempted.',
      '${e.message}',
    );
  } on SocketException catch (e) {
    _fail(
      'Cannot reach the database at $where (${e.osError?.message ?? e.message}).',
      'The endpoint is wrong or unreachable from here. Supabase offers a '
          'direct connection (db.<ref>.supabase.co) and a session pooler '
          '(aws-<n>-<region>.pooler.supabase.com:5432). The direct one resolves '
          'to IPv6 only, and a GitHub Actions runner has no IPv6 — it works '
          'from a developer machine and fails here. Use the session pooler '
          'string, as backend/.env.example does.',
    );
  } on PgException catch (e) {
    final message = e.toString();
    if (message.contains('28P01') || message.contains('password')) {
      _fail(
        'The database refused these credentials.',
        'The password in DATABASE_URL is stale, or lost characters on its way '
            'into the secret. Re-copy the connection string from Supabase: '
            'Project Settings -> Database -> Connection string.',
      );
    }
    _fail(
      'Connected to $where, but a query the API depends on failed: $message',
      'This is schema drift, not a code bug: a file in backend/sql/ has not '
          'been applied to this database. Apply them in the Supabase SQL '
          'editor. A missing column names itself in the message above.',
    );
  } finally {
    await repo?.close();
    await pool?.close();
  }

  stdout.writeln('Reachable, and the schema has everything the API reads.');
}

/// Prints [problem] and [remedy] and exits non-zero, as a GitHub annotation
/// when there is one to annotate.
///
/// [Never] so the caller does not have to return afterwards; the analyzer knows
/// the code below a call to this is unreachable.
Never _fail(String problem, String remedy) {
  if (Platform.environment['GITHUB_ACTIONS'] == 'true') {
    stderr.writeln('::error::$problem');
  } else {
    stderr.writeln(problem);
  }
  stderr.writeln('');
  stderr.writeln(remedy);
  exit(1);
}
