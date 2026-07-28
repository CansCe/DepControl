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
