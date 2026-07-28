import 'dart:io';

import 'package:backend/src/repository/postgres_api_diff_store.dart';
import 'package:backend/src/repository/postgres_pool.dart';
import 'package:postgres/postgres.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

/// Integration test against a real Postgres. Skipped unless `DATABASE_URL` is
/// set, so `dart test` stays green in environments without a database.
///
///   $env:DATABASE_URL="postgresql://...:5432/postgres?sslmode=require"; dart test
void main() {
  final url = Platform.environment['DATABASE_URL'];

  group(
    'PostgresApiDiffStore (integration)',
    skip: url == null || url.isEmpty
        ? 'set DATABASE_URL to run Postgres integration tests'
        : null,
    () {
      late Pool<void> pool;
      late PostgresApiDiffStore store;

      // A package name no real diff will ever use, so a test run cannot collide
      // with stored data and its rows are trivial to identify.
      const package = 'depcontrol-test-fixture';

      setUp(() {
        pool = postgresPoolFromUrl(url!);
        store = PostgresApiDiffStore(pool);
      });

      tearDown(() async {
        await pool.execute(
          Sql.named('delete from api_diffs where package = @p:text'),
          parameters: {'p': package},
        );
        await pool.execute(
          Sql.named('delete from api_diff_requests where package = @p:text'),
          parameters: {'p': package},
        );
        await pool.close();
      });

      test('round-trips a diff through jsonb', () async {
        await store.save(
          const ApiDiff(
            package: package,
            from: '1.0.0',
            to: '2.0.0',
            changes: [
              ApiChange(
                kind: ApiChangeKind.removed,
                declaration: 'class Pair',
                before: 'Pair',
              ),
              ApiChange(
                kind: ApiChangeKind.changed,
                declaration: 'Response.url',
                before: 'String',
                after: 'Uri',
              ),
            ],
          ),
        );

        final found = await store.find(package, from: '1.0.0', to: '2.0.0');
        expect(found, isNotNull);
        expect(found!.changes, hasLength(2));
        expect(found.removed.single.declaration, 'class Pair');
        expect(found.changed.single.before, 'String');
        expect(found.changed.single.after, 'Uri');
        // Stamped by the default on the column when the differ gave no time.
        expect(found.generatedAt, isNotNull);
      });

      test('returns null for a pair that was never computed', () async {
        expect(await store.find(package, from: '9.9.9', to: '9.9.10'), isNull);
      });

      test('re-saving replaces the stored changes', () async {
        await store.save(
          const ApiDiff(
            package: package,
            from: '1.0.0',
            to: '2.0.0',
            changes: [
              ApiChange(
                kind: ApiChangeKind.removed,
                declaration: 'gone',
                before: 'void ()',
              ),
            ],
          ),
        );
        await store.save(
          const ApiDiff(package: package, from: '1.0.0', to: '2.0.0'),
        );

        final found = await store.find(package, from: '1.0.0', to: '2.0.0');
        expect(found!.changes, isEmpty);
      });

      test('records a request and hands it back as pending', () async {
        await store.request(package, from: '1.0.0', to: '2.0.0');

        final pending = await store.pendingRequests(limit: 200);
        final mine = pending.where((r) => r.package == package);
        expect(mine, hasLength(1));
        expect(mine.single.from, '1.0.0');
        expect(mine.single.to, '2.0.0');
      });

      test('asking twice records one request', () async {
        await store.request(package, from: '1.0.0', to: '2.0.0');
        await store.request(package, from: '1.0.0', to: '2.0.0');

        final mine = (await store.pendingRequests(limit: 200))
            .where((r) => r.package == package);
        expect(mine, hasLength(1));
      });

      test('storing a diff clears its pending request', () async {
        await store.request(package, from: '1.0.0', to: '2.0.0');
        await store.save(
          const ApiDiff(package: package, from: '1.0.0', to: '2.0.0'),
        );

        final mine = (await store.pendingRequests(limit: 200))
            .where((r) => r.package == package);
        expect(mine, isEmpty);
      });
    },
  );
}
