import 'package:backend/src/notifications/notifier.dart';
import 'package:backend/src/repository/notification_store.dart';
import 'package:backend/src/repository/project_repository.dart';
import 'package:backend/src/services/rescan_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import '../support/fakes.dart';

/// The scheduled sweep, end to end against fakes: scan, store, compare,
/// announce.
void main() {
  const owner = 'a0000000-0000-0000-0000-00000000000a';

  late InMemoryProjectRepository repository;
  late InMemoryNotificationStore notifications;
  late List<http.Request> sent;

  Project project({bool archived = false}) => Project(
        id: 'p1',
        gitUrl: 'https://github.com/acme/demo.git',
        name: 'demo',
        ownerId: owner,
        addedAt: DateTime.utc(2026, 1, 1),
        archivedAt: archived ? DateTime.utc(2026, 1, 2) : null,
      );

  DepNode node(
    String name, {
    String version = '1.0.0',
    List<DepAdvisory> advisories = const [],
  }) =>
      DepNode(
        name: name,
        kind: DepKind.direct,
        installed: version,
        advisories: advisories,
      );

  /// A service whose analyzer returns [nodes] for whatever it is handed.
  RescanService serviceReturning(List<DepNode> nodes) {
    final notifier = Notifier(
      store: notifications,
      client: MockClient((request) async {
        sent.add(request);
        return http.Response('ok', 200);
      }),
    );

    return RescanService(
      repository: repository,
      gitFetcher: FakeGitFetcher(),
      analyzer: FakeAnalyzer(nodes: nodes),
      notifier: notifier,
    );
  }

  setUp(() async {
    repository = InMemoryProjectRepository();
    notifications = InMemoryNotificationStore();
    sent = [];
    await repository.add(project());
    await notifications.save(
      NotificationTarget(
        id: 't1',
        ownerId: owner,
        channel: NotificationChannel.slack,
        url: 'https://hooks.slack.com/services/T/B/XXXX',
        minSeverity: AdvisorySeverity.low,
        createdAt: DateTime.utc(2026, 1, 1),
      ),
    );
  });

  test('the first scan stores a report and announces nothing', () async {
    // Everything in a first report is technically new. Announcing a hundred
    // packages as a hundred additions is not news — it is the project.
    final result = await serviceReturning([node('http')]).rescan(project());

    expect(result.changed, isTrue);
    expect(result.diff, isNull);
    expect(sent, isEmpty);
    expect(await repository.revisionsFor('p1'), hasLength(1));
  });

  test('a scan that finds nothing new writes no revision and sends nothing',
      () async {
    await serviceReturning([node('http')]).rescan(project());
    sent.clear();

    final result = await serviceReturning([node('http')]).rescan(project());

    expect(result.changed, isFalse);
    expect(await repository.revisionsFor('p1'), hasLength(1));
    expect(sent, isEmpty);
  });

  test('a new advisory is stored as a revision and announced', () async {
    await serviceReturning([node('http')]).rescan(project());

    final result = await serviceReturning([
      node('http', advisories: const [
        DepAdvisory(id: 'GHSA-x', severity: AdvisorySeverity.critical),
      ]),
    ]).rescan(project());

    expect(result.changed, isTrue);
    expect(result.diff!.hasNewVulnerabilities, isTrue);
    expect(result.notifications!.sent, 1);
    expect(sent, hasLength(1));
    expect(await repository.revisionsFor('p1'), hasLength(2));
  });

  test('running the sweep twice does not announce the change twice', () async {
    // The property that makes a schedule safe to re-run, and safe to fire
    // twice by mistake.
    await serviceReturning([node('http')]).rescan(project());

    final vulnerable = [
      node('http', advisories: const [
        DepAdvisory(id: 'GHSA-x', severity: AdvisorySeverity.critical),
      ]),
    ];

    await serviceReturning(vulnerable).rescan(project());
    final again = await serviceReturning(vulnerable).rescan(project());

    // The second sweep found the same state, so there was nothing even to
    // compare — and had it compared, the delivery claim would have stopped it.
    expect(again.changed, isFalse);
    expect(sent, hasLength(1));
  });

  test('an archived project is not re-fetched', () async {
    // Archiving exists to stop exactly this. Re-analysis refuses with 409 in
    // the request path, and a background sweep must not go around it.
    final result = await serviceReturning([node('http')])
        .rescan(project(archived: true));

    expect(result.failed, isTrue);
    expect(result.error, contains('archived'));
    expect(await repository.revisionsFor('p1'), isEmpty);
  });

  test('a project that cannot be fetched fails alone', () async {
    // A repository can be deleted, renamed or made private at any time, and a
    // sweep that stops at the first of those stops working the first time
    // anybody tidies up.
    final notifier = Notifier(
      store: notifications,
      client: MockClient((_) async => http.Response('ok', 200)),
    );
    final service = RescanService(
      repository: repository,
      gitFetcher: FakeGitFetcher(
        onFetch: (_, __) => throw StateError('No pubspec.yaml found'),
      ),
      analyzer: FakeAnalyzer(),
      notifier: notifier,
    );

    final result = await service.rescan(project());

    expect(result.failed, isTrue);
    expect(result.error, contains('No pubspec.yaml'));
    expect(result.changed, isFalse);
  });

  test('sweeping an owner skips their archived projects', () async {
    await repository.add(
      Project(
        id: 'p2',
        gitUrl: 'https://github.com/acme/old.git',
        name: 'old',
        ownerId: owner,
        addedAt: DateTime.utc(2026, 1, 1),
        archivedAt: DateTime.utc(2026, 2, 1),
      ),
    );

    final results = await serviceReturning([node('http')]).rescanOwner(owner);

    expect(results.map((r) => r.project.id), ['p1']);
  });

  test('a breaking bump is announced even with no advisory', () async {
    await serviceReturning([node('http', version: '1.0.0')]).rescan(project());

    final result =
        await serviceReturning([node('http', version: '2.0.0')]).rescan(project());

    expect(result.diff!.breakingMoves, hasLength(1));
    expect(result.notifications!.sent, 1);
  });

  test('a routine bump is stored but not announced', () async {
    await serviceReturning([node('http', version: '1.0.0')]).rescan(project());
    sent.clear();

    final result =
        await serviceReturning([node('http', version: '1.0.1')]).rescan(project());

    expect(result.changed, isTrue);
    expect(await repository.revisionsFor('p1'), hasLength(2));
    expect(result.notifications!.sent, 0);
    expect(sent, isEmpty);
  });
}
