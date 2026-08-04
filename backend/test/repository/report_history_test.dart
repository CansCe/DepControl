import 'package:backend/src/repository/project_repository.dart';
import 'package:backend/src/repository/report_digest.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

/// The report history's semantics, against the in-memory repository.
///
/// The Postgres implementation is held to the same behaviour in
/// `postgres_project_repository_test.dart`, which needs a database and is
/// skipped without one. These run everywhere, so this is where the rules
/// themselves are pinned down.
void main() {
  const projectId = '11111111-1111-1111-1111-111111111111';

  DepNode node(
    String name, {
    String version = '1.0.0',
    String? latest,
    DepStatus status = DepStatus.upToDate,
    List<DepAdvisory> advisories = const [],
    PackageLicense? license,
  }) =>
      DepNode(
        name: name,
        kind: DepKind.direct,
        installed: version,
        latest: latest,
        status: status,
        advisories: advisories,
        license: license,
      );

  DepReport report(
    List<DepNode> nodes, {
    DateTime? at,
    List<String> manifests = const [],
    String? coverageNote,
  }) =>
      DepReport(
        projectId: projectId,
        generatedAt: at ?? DateTime.utc(2026, 1, 1),
        nodes: nodes,
        manifests: manifests,
        coverageNote: coverageNote,
      );

  group('what counts as a change', () {
    test('the same dependencies scanned twice is one revision', () async {
      final repo = InMemoryProjectRepository();

      await repo.saveReport(report([node('http')], at: DateTime.utc(2026, 1, 1)));
      await repo.saveReport(report([node('http')], at: DateTime.utc(2026, 2, 1)));

      final history = await repo.revisionsFor(projectId);
      expect(history, hasLength(1));
      expect(history.single.firstSeenAt, DateTime.utc(2026, 1, 1));
      expect(history.single.lastSeenAt, DateTime.utc(2026, 2, 1));
      expect(history.single.seenAgain, isTrue);
    });

    test('a version bump is a new revision', () async {
      final repo = InMemoryProjectRepository();

      await repo.saveReport(report([node('http')]));
      await repo.saveReport(
        report([node('http', version: '1.1.0')], at: DateTime.utc(2026, 2, 1)),
      );

      expect(await repo.revisionsFor(projectId), hasLength(2));
    });

    test('a newly published advisory on an unchanged version is a change',
        () async {
      // The whole point of re-scanning a project nobody has touched.
      final repo = InMemoryProjectRepository();

      await repo.saveReport(report([node('http')]));
      await repo.saveReport(
        report(
          [
            node(
              'http',
              status: DepStatus.vulnerable,
              advisories: const [DepAdvisory(id: 'GHSA-1111-1111-1111')],
            ),
          ],
          at: DateTime.utc(2026, 2, 1),
        ),
      );

      expect(await repo.revisionsFor(projectId), hasLength(2));
    });

    test('somebody else publishing a release is not a change here', () async {
      // `latest` and `status` move whenever anyone in the ecosystem ships.
      // Recording that as a revision of *this* project would file the rest of
      // pub.dev's activity under its history.
      final repo = InMemoryProjectRepository();

      await repo.saveReport(report([node('http', latest: '1.0.0')]));
      await repo.saveReport(
        report(
          [node('http', latest: '2.0.0', status: DepStatus.outdated)],
          at: DateTime.utc(2026, 2, 1),
        ),
      );

      expect(await repo.revisionsFor(projectId), hasLength(1));
    });

    test('a relicensing on an unchanged version is a change', () async {
      final repo = InMemoryProjectRepository();

      await repo.saveReport(
        report([node('http', license: const PackageLicense(spdxId: 'MIT'))]),
      );
      await repo.saveReport(
        report(
          [node('http', license: const PackageLicense(spdxId: 'AGPL-3.0'))],
          at: DateTime.utc(2026, 2, 1),
        ),
      );

      expect(await repo.revisionsFor(projectId), hasLength(2));
    });

    test('the repository gaining a manifest is a change', () async {
      final repo = InMemoryProjectRepository();

      await repo.saveReport(report([node('http')], manifests: ['repository root']));
      await repo.saveReport(
        report(
          [node('http')],
          manifests: ['repository root', 'tools/differ'],
          at: DateTime.utc(2026, 2, 1),
        ),
      );

      expect(await repo.revisionsFor(projectId), hasLength(2));
    });

    test('a scan that covered less of the repository is a change', () async {
      final repo = InMemoryProjectRepository();

      await repo.saveReport(report([node('http')]));
      await repo.saveReport(
        report(
          [node('http')],
          coverageNote: 'Could not list this repository.',
          at: DateTime.utc(2026, 2, 1),
        ),
      );

      expect(await repo.revisionsFor(projectId), hasLength(2));
    });

    test('node order is not a change', () async {
      final repo = InMemoryProjectRepository();

      await repo.saveReport(report([node('http'), node('yaml')]));
      await repo.saveReport(
        report([node('yaml'), node('http')], at: DateTime.utc(2026, 2, 1)),
      );

      expect(await repo.revisionsFor(projectId), hasLength(1));
    });

    test('when the report was generated is not a change', () {
      expect(
        reportDigest(report([node('http')], at: DateTime.utc(2026, 1, 1))),
        reportDigest(report([node('http')], at: DateTime.utc(2027, 6, 30))),
      );
    });
  });

  // The other half of the digest's job, and for a long time an accident: it
  // decided whether a revision was written *and*, by short-circuiting, whether
  // the stored packages were written at all. The second is not its decision.
  group('refreshing the stored body', () {
    test('a re-scan refreshes what the digest leaves out', () async {
      // The assertion that matters is the pair. Either half alone passes while
      // the feature is broken in the other direction: keep only the first and a
      // store that wrote a revision every scan would pass; keep only the
      // second and so would the frozen body this replaced.
      final repo = InMemoryProjectRepository();

      await repo.saveReport(report([node('http', latest: '1.0.0')]));
      final saved = await repo.saveReport(
        report(
          [node('http', latest: '2.0.0', status: DepStatus.outdated)],
          at: DateTime.utc(2026, 2, 1),
        ),
      );

      expect(saved.isNewRevision, isFalse);
      expect(await repo.revisionsFor(projectId), hasLength(1));

      final stored = await repo.reportFor(projectId);
      expect(stored!.nodes.single.latest, '2.0.0');
      expect(stored.nodes.single.status, DepStatus.outdated);
    });

    test('the revision counts follow the refreshed body', () async {
      // `status` is outside the digest, so a package falling behind matches on
      // digest and still changes what the history list prints.
      final repo = InMemoryProjectRepository();

      await repo.saveReport(report([node('http', latest: '1.0.0')]));
      final seen = (await repo.saveReport(
        report(
          [node('http', latest: '2.0.0', status: DepStatus.outdated)],
          at: DateTime.utc(2026, 2, 1),
        ),
      )).revision;

      expect(seen.outdated, 1);
      expect((await repo.revisionsFor(projectId)).single.outdated, 1);
    });

    test('an out-of-order scan does not overwrite the body', () async {
      // The same rule that stops `lastSeenAt` moving backwards. A scan that
      // finished late was measured earlier, so its `latest` is the older
      // reading and writing it would undo what the newer scan learned.
      final repo = InMemoryProjectRepository();

      await repo.saveReport(
        report([node('http', latest: '2.0.0')], at: DateTime.utc(2026, 6, 1)),
      );
      await repo.saveReport(
        report([node('http', latest: '1.0.0')], at: DateTime.utc(2026, 3, 1)),
      );

      final stored = await repo.reportFor(projectId);
      expect(stored!.nodes.single.latest, '2.0.0');
    });

    test('the revision window is not disturbed by the refresh', () async {
      // The body tracks forward; when this state *began* does not.
      final repo = InMemoryProjectRepository();

      await repo.saveReport(report([node('http', latest: '1.0.0')]));
      await repo.saveReport(
        report([node('http', latest: '2.0.0')], at: DateTime.utc(2026, 2, 1)),
      );

      final revision = (await repo.revisionsFor(projectId)).single;
      expect(revision.firstSeenAt, DateTime.utc(2026, 1, 1));
      expect(revision.lastSeenAt, DateTime.utc(2026, 2, 1));

      // And the body still dates itself to the revision rather than to the
      // scan that refreshed it — `lastSeenAt` above is what says how fresh the
      // measurements are.
      expect((await repo.reportFor(projectId))!.generatedAt,
          DateTime.utc(2026, 1, 1));
    });
  });

  group('reading the history', () {
    test('reportFor is the newest revision', () async {
      final repo = InMemoryProjectRepository();

      await repo.saveReport(report([node('http')]));
      await repo.saveReport(
        report([node('http', version: '2.0.0')], at: DateTime.utc(2026, 2, 1)),
      );

      final latest = await repo.reportFor(projectId);
      expect(latest!.nodes.single.installed, '2.0.0');
    });

    test('a revert reads back as the state reverted to', () async {
      // A -> B -> A is three states over time and two of them are the same
      // packages. Collapsing the second A into the first would leave the newest
      // revision saying B, so `reportFor` would answer with what the project
      // used to depend on.
      final repo = InMemoryProjectRepository();

      await repo.saveReport(report([node('http')]));
      await repo.saveReport(
        report([node('http', version: '2.0.0')], at: DateTime.utc(2026, 2, 1)),
      );
      await repo.saveReport(report([node('http')], at: DateTime.utc(2026, 3, 1)));

      expect(await repo.revisionsFor(projectId), hasLength(3));
      final latest = await repo.reportFor(projectId);
      expect(latest!.nodes.single.installed, '1.0.0');
    });

    test('a scan that finishes late does not become the newest', () async {
      // Verified against Postgres, which orders this history by
      // `first_seen_at desc` and so would not promote the late arrival either.
      // The two stores have to agree about what `reportFor` returns.
      final repo = InMemoryProjectRepository();

      await repo.saveReport(
        report([node('http', version: '2.0.0')], at: DateTime.utc(2026, 6, 1)),
      );
      await repo.saveReport(
        report([node('http', version: '1.0.0')], at: DateTime.utc(2026, 3, 1)),
      );

      expect(await repo.revisionsFor(projectId), hasLength(2));
      final latest = await repo.reportFor(projectId);
      expect(latest!.nodes.single.installed, '2.0.0');
    });

    test('a revision is read back in full by id', () async {
      final repo = InMemoryProjectRepository();

      final first = (await repo.saveReport(report([node('http')]))).revision;
      await repo.saveReport(
        report([node('http', version: '2.0.0')], at: DateTime.utc(2026, 2, 1)),
      );

      final stored = await repo.reportAt(projectId, first.id);
      expect(stored!.nodes.single.installed, '1.0.0');
    });

    test('another project cannot read this one by revision id', () async {
      final repo = InMemoryProjectRepository();
      final revision = (await repo.saveReport(report([node('http')]))).revision;

      expect(await repo.reportAt('other-project', revision.id), isNull);
    });

    test('revisions carry the counts a list needs', () async {
      final repo = InMemoryProjectRepository();

      final revision = (await repo.saveReport(
        report([
          node('http', status: DepStatus.vulnerable, advisories: const [
            DepAdvisory(id: 'GHSA-1111-1111-1111'),
          ]),
          node('yaml', status: DepStatus.outdated),
          node('meta'),
        ]),
      )).revision;

      expect(revision.total, 3);
      expect(revision.vulnerable, 1);
      expect(revision.outdated, 1);
    });

    test('history is newest first and bounded by the caller', () async {
      final repo = InMemoryProjectRepository();

      for (var i = 0; i < 5; i++) {
        await repo.saveReport(
          report(
            [node('http', version: '1.$i.0')],
            at: DateTime.utc(2026, 1, i + 1),
          ),
        );
      }

      final history = await repo.revisionsFor(projectId, limit: 2);
      expect(history, hasLength(2));
      expect(history.first.firstSeenAt, DateTime.utc(2026, 1, 5));
      expect(history.last.firstSeenAt, DateTime.utc(2026, 1, 4));
    });

    test('a project keeps at most maxRevisionsPerProject', () async {
      final repo = InMemoryProjectRepository();

      for (var i = 0; i < maxRevisionsPerProject + 10; i++) {
        await repo.saveReport(
          report(
            [node('http', version: '1.0.$i')],
            at: DateTime.utc(2026).add(Duration(days: i)),
          ),
        );
      }

      final history = await repo.revisionsFor(
        projectId,
        limit: maxRevisionsPerProject + 10,
      );
      expect(history, hasLength(maxRevisionsPerProject));
      // The oldest went, not the newest.
      expect(
        history.first.firstSeenAt,
        DateTime.utc(2026).add(const Duration(days: maxRevisionsPerProject + 9)),
      );
    });
  });

  group('commit ids', () {
    test('a revision records the commit it was scanned at', () async {
      final repo = InMemoryProjectRepository();

      final revision =
          (await repo.saveReport(report([node('http')]), commitSha: 'abc123')).revision;

      expect(revision.commitSha, 'abc123');
    });

    test('learning the commit later fills the gap', () async {
      // Not a change to the state: the same dependencies, now with the
      // repository revision recorded.
      final repo = InMemoryProjectRepository();

      await repo.saveReport(report([node('http')]));
      final seen = (await repo.saveReport(
        report([node('http')], at: DateTime.utc(2026, 2, 1)),
        commitSha: 'abc123',
      )).revision;

      expect(await repo.revisionsFor(projectId), hasLength(1));
      expect(seen.commitSha, 'abc123');
    });

    test('a recorded commit is not overwritten by a later sighting', () async {
      // The first sighting is where this state began, so that is the commit
      // that introduced it.
      final repo = InMemoryProjectRepository();

      await repo.saveReport(report([node('http')]), commitSha: 'first');
      final seen = (await repo.saveReport(
        report([node('http')], at: DateTime.utc(2026, 2, 1)),
        commitSha: 'second',
      )).revision;

      expect(seen.commitSha, 'first');
    });
  });

  test('lastSeenAt never moves backwards', () async {
    // Scans can finish out of order. A report generated before the one already
    // recorded says nothing newer about the state.
    final repo = InMemoryProjectRepository();

    await repo.saveReport(report([node('http')], at: DateTime.utc(2026, 6, 1)));
    final seen = (await repo.saveReport(
      report([node('http')], at: DateTime.utc(2026, 3, 1)),
    )).revision;

    expect(seen.lastSeenAt, DateTime.utc(2026, 6, 1));
  });

  test('deleting a project takes its history with it', () async {
    final repo = InMemoryProjectRepository();
    const owner = '22222222-2222-2222-2222-222222222222';

    await repo.add(
      const Project(
        id: projectId,
        gitUrl: 'https://example.com/acme.git',
        name: 'acme',
        ownerId: owner,
      ),
    );
    await repo.saveReport(report([node('http')]));

    expect(await repo.delete(projectId, ownerId: owner), isTrue);
    expect(await repo.revisionsFor(projectId), isEmpty);
    expect(await repo.reportFor(projectId), isNull);
  });
}
