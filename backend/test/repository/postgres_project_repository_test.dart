import 'dart:io';

import 'package:backend/src/repository/postgres_project_repository.dart';
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
      final id = '22222222-2222-2222-2222-222222222222';

      setUp(() => repo = PostgresProjectRepository.fromUrl(url!));

      // The interface has no delete; the test uses a fixed UUID and upserts, so
      // re-runs overwrite the fixture rather than accumulating rows.
      tearDown(() => repo.close());

      test('round-trips a project and its report', () async {
        final project = Project(
          id: id,
          gitUrl: 'https://example.com/acme.git',
          name: 'acme',
          ref: 'main',
          addedAt: DateTime.utc(2026, 1, 1),
        );
        await repo.add(project);

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

        final fetched = await repo.byId(id);
        expect(fetched, isNotNull);
        expect(fetched!.name, 'acme');
        expect(fetched.ref, 'main');
        expect(fetched.gitUrl, 'https://example.com/acme.git');

        final fetchedReport = await repo.reportFor(id);
        expect(fetchedReport, isNotNull);
        expect(fetchedReport!.nodes, hasLength(1));
        expect(fetchedReport.nodes.single.name, 'http');
        expect(fetchedReport.nodes.single.status, DepStatus.outdated);
        expect(fetchedReport.total, 1);
        expect(fetchedReport.outdated, 1);

        expect(await repo.all(), isNotEmpty);
      });
    },
  );
}
