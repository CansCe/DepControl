import 'package:backend/src/repository/project_repository.dart';
import 'package:backend/src/repository/scan_job_store.dart';
import 'package:backend/src/services/scan_progress_store.dart';
import 'package:backend/src/services/scan_runner.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import '../support/fakes.dart';

const _alice = 'a0000000-0000-0000-0000-00000000000a';

/// Short enough that a heartbeat a few milliseconds old counts as abandoned.
///
/// Not `Duration.zero`: staleness is `now - heartbeat > staleAfter`, and a
/// claim made in the same millisecond as the check gives exactly zero, which is
/// not greater than zero. The test would then pass or fail on clock resolution.
const _instantly = Duration(milliseconds: 1);

ScanJob _job({
  String id = 'scan-1',
  ScanJobKind kind = ScanJobKind.add,
  String gitUrl = 'https://github.com/acme/widget.git',
  String? projectId,
  DateTime? createdAt,
}) {
  final now = createdAt ?? DateTime.now().toUtc();
  return ScanJob(
    id: id,
    ownerId: _alice,
    kind: kind,
    gitUrl: gitUrl,
    projectId: projectId,
    createdAt: now,
    progress: ScanProgress(
      phase: ScanPhase.queued,
      startedAt: now,
      phaseStartedAt: now,
    ),
  );
}

void main() {
  late InMemoryProjectRepository repository;
  late InMemoryScanJobStore jobs;
  late FakeGitFetcher fetcher;

  ScanRunner runnerFor({
    FakeGitFetcher? gitFetcher,
    Duration staleAfter = const Duration(minutes: 2),
    int maxAttempts = 3,
  }) =>
      ScanRunner(
        jobs: jobs,
        repository: repository,
        gitFetcher: gitFetcher ?? fetcher,
        analyzer: FakeAnalyzer(),
        progress: ScanProgressStore(),
        staleAfter: staleAfter,
        maxAttempts: maxAttempts,
      );

  setUp(() {
    repository = InMemoryProjectRepository();
    jobs = InMemoryScanJobStore();
    fetcher = FakeGitFetcher();
  });

  group('ScanRunner', () {
    // The feature, stated as a test: nothing here goes through a request, and
    // no connection is open to anybody. A scan that needs one is a scan that
    // dies when the page closes.
    test('runs a scan with nobody connected', () async {
      await jobs.enqueue(_job());

      await runnerFor().drain();

      final projects = await repository.allForOwner(_alice);
      expect(projects, hasLength(1));
      expect(projects.single.name, 'widget');
      expect(await repository.reportFor(projects.single.id), isNotNull);

      final job = await jobs.byId('scan-1', ownerId: _alice);
      expect(job!.state, ScanJobState.done);
      expect(job.projectId, projects.single.id);
    });

    test('drains everything queued, oldest first', () async {
      final base = DateTime.utc(2026, 8, 4, 10);
      await jobs.enqueue(_job(
        id: 'scan-2',
        gitUrl: 'https://github.com/acme/second.git',
        createdAt: base.add(const Duration(minutes: 1)),
      ));
      await jobs.enqueue(_job(
        id: 'scan-1',
        gitUrl: 'https://github.com/acme/first.git',
        createdAt: base,
      ));

      await runnerFor().drain();

      expect(
        fetcher.calls.map((c) => c.gitUrl),
        [
          'https://github.com/acme/first.git',
          'https://github.com/acme/second.git',
        ],
      );
    });

    // The claim has to be atomic, and this is the cheap half of proving it: two
    // runners against one store must not both take the same job. The Postgres
    // half is `for update skip locked` and needs a database, so it lives in the
    // db-tagged integration test.
    test('two runners never take the same job', () async {
      for (var i = 0; i < 5; i++) {
        await jobs.enqueue(_job(
          id: 'scan-$i',
          gitUrl: 'https://github.com/acme/repo$i.git',
        ));
      }

      final one = runnerFor();
      final two = runnerFor();
      await Future.wait([one.drain(), two.drain()]);

      final urls = fetcher.calls.map((c) => c.gitUrl).toList();
      expect(urls, hasLength(5));
      expect(urls.toSet(), hasLength(5), reason: 'a job was run twice');
    });

    test('a job whose worker went quiet is picked up again', () async {
      await jobs.enqueue(_job());
      // Claimed by a machine that then died: state says running, and nothing
      // has heart-beaten since.
      await jobs.claimNext(staleAfter: _instantly);
      expect((await jobs.byId('scan-1', ownerId: _alice))!.state,
          ScanJobState.running);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      await runnerFor(staleAfter: _instantly).drain();

      expect(await repository.allForOwner(_alice), hasLength(1));
      expect((await jobs.byId('scan-1', ownerId: _alice))!.state,
          ScanJobState.done);
    });

    test('a job that keeps killing its worker is failed, not retried forever',
        () async {
      await jobs.enqueue(_job());
      // Three claims with no completion — a scan that takes the machine down
      // with it every time.
      for (var i = 0; i < 3; i++) {
        await jobs.claimNext(staleAfter: _instantly);
        // Long enough for the claim just made to read as abandoned, so the
        // next one round the loop is a genuine re-claim rather than a no-op.
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect((await jobs.byId('scan-1', ownerId: _alice))!.attempts, 3);

      await runnerFor(staleAfter: _instantly).drain();

      final job = await jobs.byId('scan-1', ownerId: _alice);
      expect(job!.state, ScanJobState.failed);
      expect(job.error, contains('abandoned'));
      // And it did not run a fourth time.
      expect(fetcher.calls, isEmpty);
    });

    test('a refresh whose project vanished fails rather than throwing',
        () async {
      await jobs.enqueue(
        _job(kind: ScanJobKind.refresh, projectId: 'p-gone'),
      );

      await runnerFor().drain();

      final job = await jobs.byId('scan-1', ownerId: _alice);
      expect(job!.state, ScanJobState.failed);
      expect(job.error, contains('deleted'));
    });

    test('nothing queued is not an error', () async {
      await runnerFor().drain();

      expect(await jobs.pendingCount(), 0);
      expect(fetcher.calls, isEmpty);
    });

    test('a second drain waits for the one already running', () async {
      await jobs.enqueue(_job());
      final runner = runnerFor();

      // What a route's `wake()` and the startup pass do to each other. The
      // second caller must get something worth awaiting, not an immediately
      // completed future and a queue still full.
      final first = runner.drain();
      final second = runner.drain();
      await Future.wait([first, second]);

      expect(await jobs.pendingCount(), 0);
      expect(fetcher.calls, hasLength(1));
    });
  });
}
