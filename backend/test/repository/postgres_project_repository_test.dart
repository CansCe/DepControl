import 'dart:io';

import 'package:backend/src/repository/postgres_project_repository.dart';
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
    'PostgresProjectRepository (integration)',
    skip: url == null || url.isEmpty
        ? 'set DATABASE_URL to run Postgres integration tests'
        : null,
    () {
      late PostgresProjectRepository repo;

      const id = '22222222-2222-2222-2222-222222222222';
      const owner = '33333333-3333-3333-3333-333333333333';
      const otherOwner = '44444444-4444-4444-4444-444444444444';

      Project fixture() => Project(
            id: id,
            gitUrl: 'https://example.com/acme.git',
            name: 'acme',
            ownerId: owner,
            ref: 'main',
            addedAt: DateTime.utc(2026, 1, 1),
          );

      setUp(() => repo = PostgresProjectRepository.fromUrl(url!));

      // Remove the fixtures so a test run leaves no rows behind in a shared
      // development database. The report cascades with its project.
      tearDown(() async {
        await repo.close();
        final connection = await Connection.openFromUrl(url!);
        try {
          await connection.execute(
            Sql.named('delete from projects where owner_id = any(@owners)'),
            parameters: {
              'owners': TypedValue(
                Type.uuidArray,
                const [owner, otherOwner],
              ),
            },
          );
        } finally {
          await connection.close();
        }
      });

      test('round-trips a project and its report', () async {
        await repo.add(fixture());

        final report = DepReport(
          projectId: id,
          generatedAt: DateTime.utc(2026, 1, 2),
          nodes: const [
            DepNode(
              name: 'http',
              kind: DepKind.direct,
              installed: '1.2.0',
              constraint: '^1.0.0',
              latest: '1.3.0',
              status: DepStatus.outdated,
            ),
          ],
        );
        await repo.saveReport(report);

        final fetched = await repo.byId(id, ownerId: owner);
        expect(fetched, isNotNull);
        expect(fetched!.name, 'acme');
        expect(fetched.ref, 'main');
        expect(fetched.ownerId, owner);
        expect(fetched.gitUrl, 'https://example.com/acme.git');

        final fetchedReport = await repo.reportFor(id);
        expect(fetchedReport, isNotNull);
        expect(fetchedReport!.nodes, hasLength(1));
        expect(fetchedReport.nodes.single.name, 'http');
        expect(fetchedReport.nodes.single.status, DepStatus.outdated);
        expect(fetchedReport.total, 1);
        expect(fetchedReport.outdated, 1);
        expect(fetchedReport.manifests, isEmpty);
        expect(fetchedReport.coverageNote, isNull);
      });

      // A note saying the scan reached less than the whole repository is the
      // report's own admission of what it missed, so losing it in the store
      // turns a partial count into one that looks complete.
      test('round-trips what the report covered', () async {
        await repo.add(fixture());

        const note = 'read 20 of 34 pubspecs';
        await repo.saveReport(
          DepReport(
            projectId: id,
            generatedAt: DateTime.utc(2026, 1, 2),
            nodes: const [
              DepNode(name: 'http', kind: DepKind.direct, installed: '1.2.0'),
            ],
            manifests: const ['', 'packages/shared', 'tools/api_differ'],
            coverageNote: note,
          ),
        );

        final fetched = await repo.reportFor(id);
        expect(
          fetched!.manifests,
          ['', 'packages/shared', 'tools/api_differ'],
        );
        expect(fetched.coverageNote, note);
      });

      // Re-analyzing after the gap is closed has to clear the note, or the
      // project keeps apologising for a scan it no longer has.
      test('re-saving clears a coverage note that no longer applies', () async {
        await repo.add(fixture());

        DepReport report({List<String> manifests = const [], String? note}) =>
            DepReport(
              projectId: id,
              generatedAt: DateTime.utc(2026, 1, 2),
              nodes: const [
                DepNode(name: 'http', kind: DepKind.direct, installed: '1.2.0'),
              ],
              manifests: manifests,
              coverageNote: note,
            );

        await repo.saveReport(
          report(manifests: const ['', 'packages/shared'], note: 'truncated'),
        );
        await repo.saveReport(report());

        final fetched = await repo.reportFor(id);
        expect(fetched!.coverageNote, isNull);
        expect(fetched.manifests, isEmpty);
      });

      // The history's rules are pinned down against the in-memory store in
      // report_history_test.dart, which runs everywhere. What is checked here
      // is that the SQL implements the same ones — the digest comparison, the
      // ordering, the counts computed in Postgres rather than in Dart.
      group('report history', () {
        DepReport reportOf(
          String version, {
          required DateTime at,
          DepStatus status = DepStatus.outdated,
        }) =>
            DepReport(
              projectId: id,
              generatedAt: at,
              nodes: [
                DepNode(
                  name: 'http',
                  kind: DepKind.direct,
                  installed: version,
                  status: status,
                ),
              ],
            );

        test('the same dependencies scanned twice is one revision', () async {
          await repo.add(fixture());

          await repo.saveReport(reportOf('1.2.0', at: DateTime.utc(2026, 1, 2)));
          final seen =
              await repo.saveReport(reportOf('1.2.0', at: DateTime.utc(2026, 2, 2)));

          final history = await repo.revisionsFor(id);
          expect(history, hasLength(1));
          expect(history.single.firstSeenAt, DateTime.utc(2026, 1, 2));
          expect(history.single.lastSeenAt, DateTime.utc(2026, 2, 2));
          expect(seen.id, history.single.id);
        });

        test('a version bump is a new revision, newest first', () async {
          await repo.add(fixture());

          await repo.saveReport(reportOf('1.2.0', at: DateTime.utc(2026, 1, 2)));
          await repo.saveReport(reportOf('1.3.0', at: DateTime.utc(2026, 2, 2)));

          final history = await repo.revisionsFor(id);
          expect(history, hasLength(2));
          expect(history.first.firstSeenAt, DateTime.utc(2026, 2, 2));

          final latest = await repo.reportFor(id);
          expect(latest!.nodes.single.installed, '1.3.0');
        });

        test('a revert reads back as the state reverted to', () async {
          await repo.add(fixture());

          await repo.saveReport(reportOf('1.2.0', at: DateTime.utc(2026, 1, 2)));
          await repo.saveReport(reportOf('1.3.0', at: DateTime.utc(2026, 2, 2)));
          await repo.saveReport(reportOf('1.2.0', at: DateTime.utc(2026, 3, 2)));

          expect(await repo.revisionsFor(id), hasLength(3));
          final latest = await repo.reportFor(id);
          expect(latest!.nodes.single.installed, '1.2.0');
        });

        test('counts come back from the jsonb without decoding it', () async {
          await repo.add(fixture());

          await repo.saveReport(
            DepReport(
              projectId: id,
              generatedAt: DateTime.utc(2026, 1, 2),
              nodes: const [
                DepNode(
                  name: 'http',
                  kind: DepKind.direct,
                  installed: '1.2.0',
                  status: DepStatus.vulnerable,
                ),
                DepNode(
                  name: 'yaml',
                  kind: DepKind.direct,
                  installed: '3.1.0',
                  status: DepStatus.outdated,
                ),
                DepNode(name: 'meta', kind: DepKind.direct, installed: '1.0.0'),
              ],
            ),
          );

          // Read back through revisionsFor, which computes them in SQL rather
          // than taking them from the report in hand.
          final revision = (await repo.revisionsFor(id)).single;
          expect(revision.total, 3);
          expect(revision.vulnerable, 1);
          expect(revision.outdated, 1);
        });

        test('a revision is read back in full by id', () async {
          await repo.add(fixture());

          final first =
              await repo.saveReport(reportOf('1.2.0', at: DateTime.utc(2026, 1, 2)));
          await repo.saveReport(reportOf('1.3.0', at: DateTime.utc(2026, 2, 2)));

          final stored = await repo.reportAt(id, first.id);
          expect(stored!.nodes.single.installed, '1.2.0');
        });

        test('a revision is not readable through another project', () async {
          await repo.add(fixture());
          final revision =
              await repo.saveReport(reportOf('1.2.0', at: DateTime.utc(2026, 1, 2)));

          expect(
            await repo.reportAt(
              '55555555-5555-5555-5555-555555555555',
              revision.id,
            ),
            isNull,
          );
        });

        test('a commit id learned later fills the gap on the same revision',
            () async {
          await repo.add(fixture());

          await repo.saveReport(reportOf('1.2.0', at: DateTime.utc(2026, 1, 2)));
          final seen = await repo.saveReport(
            reportOf('1.2.0', at: DateTime.utc(2026, 2, 2)),
            commitSha: 'abc123',
          );

          expect(await repo.revisionsFor(id), hasLength(1));
          expect(seen.commitSha, 'abc123');
        });

        test('lastSeenAt never moves backwards', () async {
          await repo.add(fixture());

          await repo.saveReport(reportOf('1.2.0', at: DateTime.utc(2026, 6, 1)));
          final seen =
              await repo.saveReport(reportOf('1.2.0', at: DateTime.utc(2026, 3, 1)));

          expect(seen.lastSeenAt, DateTime.utc(2026, 6, 1));
        });

        test('deleting a project cascades to its history', () async {
          await repo.add(fixture());
          await repo.saveReport(reportOf('1.2.0', at: DateTime.utc(2026, 1, 2)));

          expect(await repo.delete(id, ownerId: owner), isTrue);
          expect(await repo.revisionsFor(id), isEmpty);
        });
      });

      test('byId does not return a project owned by someone else', () async {
        await repo.add(fixture());
        expect(await repo.byId(id, ownerId: otherOwner), isNull);
      });

      test('allForOwner only returns that owner\'s projects', () async {
        await repo.add(fixture());

        final mine = await repo.allForOwner(owner);
        expect(mine.map((p) => p.id), contains(id));
        expect(mine.every((p) => p.ownerId == owner), isTrue);

        final theirs = await repo.allForOwner(otherOwner);
        expect(theirs.map((p) => p.id), isNot(contains(id)));
      });

      test('archiving hides it from the default listing and is reversible',
          () async {
        await repo.add(fixture());

        final archived = await repo.setArchived(
          id,
          ownerId: owner,
          archived: true,
        );
        expect(archived!.isArchived, isTrue);
        expect(await repo.allForOwner(owner), isEmpty);
        expect(
          (await repo.allForOwner(owner, includeArchived: true))
              .map((p) => p.id),
          contains(id),
        );

        final restored = await repo.setArchived(
          id,
          ownerId: owner,
          archived: false,
        );
        expect(restored!.isArchived, isFalse);
        expect(await repo.allForOwner(owner), hasLength(1));
      });

      test('does not archive a project owned by someone else', () async {
        await repo.add(fixture());

        expect(
          await repo.setArchived(id, ownerId: otherOwner, archived: true),
          isNull,
        );
        expect(
          (await repo.byId(id, ownerId: owner))!.isArchived,
          isFalse,
        );
      });

      // The report is removed by the foreign key's cascade rather than by a
      // second statement, so it is worth proving against a real database.
      test('deleting takes the report with it', () async {
        await repo.add(fixture());
        await repo.saveReport(
          DepReport(
            projectId: id,
            generatedAt: DateTime.utc(2026, 1, 2),
            nodes: const [
              DepNode(name: 'http', kind: DepKind.direct, installed: '1.2.0'),
            ],
          ),
        );

        expect(await repo.delete(id, ownerId: owner), isTrue);
        expect(await repo.byId(id, ownerId: owner), isNull);
        expect(await repo.reportFor(id), isNull);
      });

      test('does not delete a project owned by someone else', () async {
        await repo.add(fixture());

        expect(await repo.delete(id, ownerId: otherOwner), isFalse);
        expect(await repo.byId(id, ownerId: owner), isNotNull);
      });

      test('rejects a project with no owner', () async {
        final orphan = Project(
          id: '55555555-5555-5555-5555-555555555555',
          gitUrl: 'https://example.com/x.git',
          name: 'x',
        );
        expect(() => repo.add(orphan), throwsArgumentError);
      });
    },
  );
}
