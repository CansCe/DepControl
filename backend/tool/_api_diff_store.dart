// Shared setup for the API-diff CLIs. Not part of the server.
import 'dart:io';

import 'package:backend/src/repository/api_diff_store.dart';
import 'package:backend/src/repository/postgres_api_diff_store.dart';
import 'package:backend/src/repository/postgres_pool.dart';
import 'package:postgres/postgres.dart';

/// Opens the diff store from `DATABASE_URL`, exiting with a usable message when
/// it is missing.
///
/// These tools always talk to Postgres. The in-memory store the dev server
/// falls back to lives in that server's process, so writing to it from here
/// would store a diff nothing can ever read.
///
/// The environment is read directly — `backend/.env` is loaded by `run.ps1`, not
/// by Dart — so a shell that has not run it needs the variable set explicitly.
({Pool<void> pool, ApiDiffStore store}) openStore() {
  final url = Platform.environment['DATABASE_URL'];
  if (url == null || url.isEmpty) {
    stderr.writeln('DATABASE_URL is not set.');
    stderr.writeln('');
    stderr.writeln('Diffs are stored in Postgres, so this needs the same '
        'connection string the server uses. From backend/, in PowerShell:');
    stderr.writeln('');
    stderr.writeln(r"  $env:DATABASE_URL = ((Get-Content .env | "
        r"Select-String '^DATABASE_URL=') -split '=', 2)[1]");
    exit(2);
  }

  final Pool<void> pool;
  try {
    pool = postgresPoolFromUrl(url);
  } on ArgumentError catch (e) {
    stderr.writeln(e.message);
    exit(2);
  }

  return (pool: pool, store: PostgresApiDiffStore(pool));
}
