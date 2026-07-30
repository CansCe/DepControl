import 'dart:convert';

import 'package:backend/src/notifications/notification_message.dart';
import 'package:backend/src/notifications/notifier.dart';
import 'package:backend/src/repository/notification_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  const owner = 'a0000000-0000-0000-0000-00000000000a';

  const project = Project(
    id: 'p1',
    gitUrl: 'https://github.com/acme/demo.git',
    name: 'demo',
    ownerId: owner,
  );

  NotificationTarget target({
    String id = 't1',
    String? projectId,
    AdvisorySeverity minSeverity = AdvisorySeverity.high,
    bool onNewAdvisory = true,
    bool onBreakingChange = true,
    NotificationChannel channel = NotificationChannel.slack,
    String url = 'https://hooks.slack.com/services/T/B/XXXX',
  }) =>
      NotificationTarget(
        id: id,
        ownerId: owner,
        projectId: projectId,
        channel: channel,
        url: url,
        minSeverity: minSeverity,
        onNewAdvisory: onNewAdvisory,
        onBreakingChange: onBreakingChange,
        createdAt: DateTime.utc(2026, 1, 1),
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

  ReportDiff diffOf(List<DepNode> before, List<DepNode> after) =>
      ReportDiff.between(
        DepReport(
          projectId: 'p1',
          generatedAt: DateTime.utc(2026, 1, 1),
          nodes: before,
        ),
        DepReport(
          projectId: 'p1',
          generatedAt: DateTime.utc(2026, 2, 1),
          nodes: after,
        ),
      );

  const criticalAdvisory = DepAdvisory(
    id: 'GHSA-critical',
    severity: AdvisorySeverity.critical,
    fixedIn: '1.0.1',
  );
  const lowAdvisory =
      DepAdvisory(id: 'GHSA-low', severity: AdvisorySeverity.low);
  const unratedAdvisory = DepAdvisory(id: 'GHSA-unrated');

  final newCritical = diffOf(
    [node('http')],
    [node('http', advisories: [criticalAdvisory])],
  );
  final newLow = diffOf(
    [node('http')],
    [node('http', advisories: [lowAdvisory])],
  );
  final breaking = diffOf(
    [node('http', version: '1.0.0')],
    [node('http', version: '2.0.0')],
  );
  final routine = diffOf(
    [node('http', version: '1.0.0')],
    [node('http', version: '1.0.1')],
  );

  group('when a target fires', () {
    test('a new advisory at or above the threshold', () {
      expect(
        NotificationRules.shouldNotify(
          target(minSeverity: AdvisorySeverity.high),
          newCritical,
        ),
        isTrue,
      );
    });

    test('and not one below it', () {
      expect(
        NotificationRules.shouldNotify(
          target(minSeverity: AdvisorySeverity.high),
          newLow,
        ),
        isFalse,
      );
    });

    test('an unrated advisory clears every threshold', () {
      // Nobody has assessed it. "We do not know how bad this is" is not a
      // reason to stay quiet — the same rule that stops it reading as low.
      final unrated = diffOf(
        [node('http')],
        [node('http', advisories: [unratedAdvisory])],
      );

      expect(
        NotificationRules.shouldNotify(
          target(minSeverity: AdvisorySeverity.critical),
          unrated,
        ),
        isTrue,
      );
    });

    test('a breaking move, when that rule is on', () {
      expect(
        NotificationRules.shouldNotify(target(), breaking),
        isTrue,
      );
      expect(
        NotificationRules.shouldNotify(
          target(onBreakingChange: false),
          breaking,
        ),
        isFalse,
      );
    });

    test('a routine bump fires nothing', () {
      expect(NotificationRules.shouldNotify(target(), routine), isFalse);
    });

    test('an empty diff fires nothing', () {
      expect(
        NotificationRules.shouldNotify(target(), diffOf([node('a')], [node('a')])),
        isFalse,
      );
    });

    test('advisories can be off while breaking changes stay on', () {
      final t = target(onNewAdvisory: false);
      expect(NotificationRules.shouldNotify(t, newCritical), isFalse);
      expect(NotificationRules.shouldNotify(t, breaking), isTrue);
    });
  });

  group('the reason says what triggered it', () {
    test('naming the band', () {
      expect(
        NotificationRules.reason(target(), newCritical),
        contains('critical'),
      );
    });

    test('and the breaking changes, counted', () {
      final two = diffOf(
        [node('a', version: '1.0.0'), node('b', version: '1.0.0')],
        [node('a', version: '2.0.0'), node('b', version: '3.0.0')],
      );
      expect(NotificationRules.reason(target(), two), '2 breaking changes');
    });

    test('both, when both fired', () {
      final both = diffOf(
        [node('a'), node('b', version: '1.0.0')],
        [
          node('a', advisories: [criticalAdvisory]),
          node('b', version: '2.0.0'),
        ],
      );
      final reason = NotificationRules.reason(target(), both);
      expect(reason, contains('critical'));
      expect(reason, contains('breaking'));
    });
  });

  group('delivery', () {
    late InMemoryNotificationStore store;
    late List<http.Request> sent;

    Notifier notifierThatAnswers(int status, {String body = 'ok'}) {
      sent = [];
      return Notifier(
        store: store,
        appBaseUrl: 'https://depcontrol.test',
        client: MockClient((request) async {
          sent.add(request);
          return http.Response(body, status);
        }),
      );
    }

    setUp(() => store = InMemoryNotificationStore());

    test('posts to the target and records success', () async {
      await store.save(target());
      final notifier = notifierThatAnswers(200);

      final outcome = await notifier.announce(
        project: project,
        diff: newCritical,
        revisionId: 'r1',
      );

      expect(outcome.sent, 1);
      expect(sent.single.url.host, 'hooks.slack.com');
      expect(store.outcomeOf('t1', 'r1')!.succeeded, isTrue);
    });

    test('the same change is never announced twice', () async {
      // The guarantee that makes a re-run safe: a sweep that fires twice, or a
      // machine that died mid-send, must not produce a second alert.
      await store.save(target());
      final notifier = notifierThatAnswers(200);

      final first = await notifier.announce(
        project: project,
        diff: newCritical,
        revisionId: 'r1',
      );
      final second = await notifier.announce(
        project: project,
        diff: newCritical,
        revisionId: 'r1',
      );

      expect(first.sent, 1);
      expect(second.sent, 0);
      expect(second.alreadySent, 1);
      expect(sent, hasLength(1));
    });

    test('a different revision is a different announcement', () async {
      await store.save(target());
      final notifier = notifierThatAnswers(200);

      await notifier.announce(
        project: project,
        diff: newCritical,
        revisionId: 'r1',
      );
      final second = await notifier.announce(
        project: project,
        diff: newCritical,
        revisionId: 'r2',
      );

      expect(second.sent, 1);
      expect(sent, hasLength(2));
    });

    test('a failed send stays claimed and is not retried', () async {
      // Retrying an alert on a schedule is how a broken webhook becomes a
      // loop. The change is still in the history; the next real change will be
      // announced.
      await store.save(target());
      final notifier = notifierThatAnswers(500, body: 'boom');

      final first = await notifier.announce(
        project: project,
        diff: newCritical,
        revisionId: 'r1',
      );
      final second = await notifier.announce(
        project: project,
        diff: newCritical,
        revisionId: 'r1',
      );

      expect(first.failed, 1);
      expect(second.alreadySent, 1);
      expect(sent, hasLength(1));

      final outcome = store.outcomeOf('t1', 'r1')!;
      expect(outcome.succeeded, isFalse);
      expect(outcome.detail, contains('500'));
    });

    test('a target whose bar is not cleared is never claimed', () async {
      // So the same change can still be announced if the bar is later lowered.
      await store.save(target(minSeverity: AdvisorySeverity.critical));
      final notifier = notifierThatAnswers(200);

      final outcome = await notifier.announce(
        project: project,
        diff: newLow,
        revisionId: 'r1',
      );

      expect(outcome.skipped, 1);
      expect(sent, isEmpty);
      expect(
        await store.claimDelivery(targetId: 't1', revisionId: 'r1'),
        isTrue,
      );
    });

    test('a target scoped to another project is not told', () async {
      await store.save(target(projectId: 'someone-elses-project'));
      final notifier = notifierThatAnswers(200);

      final outcome = await notifier.announce(
        project: project,
        diff: newCritical,
        revisionId: 'r1',
      );

      expect(outcome.considered, 0);
      expect(sent, isEmpty);
    });

    test('a stored URL that is no longer deliverable fails, not throws',
        () async {
      // The allowlist can narrow, and a row can be edited by something other
      // than this application. An outbound request is not taken on trust from
      // storage.
      await store.save(target(url: 'https://attacker.test/hook'));
      final notifier = notifierThatAnswers(200);

      final outcome = await notifier.announce(
        project: project,
        diff: newCritical,
        revisionId: 'r1',
      );

      expect(outcome.failed, 1);
      expect(sent, isEmpty);
      expect(store.outcomeOf('t1', 'r1')!.detail, contains('not deliverable'));
    });

    test('each target is decided on its own', () async {
      await store.save(target(id: 't1', minSeverity: AdvisorySeverity.critical));
      await store.save(target(id: 't2', minSeverity: AdvisorySeverity.low));
      final notifier = notifierThatAnswers(200);

      final outcome = await notifier.announce(
        project: project,
        diff: newLow,
        revisionId: 'r1',
      );

      expect(outcome.sent, 1);
      expect(outcome.skipped, 1);
    });
  });

  group('the message', () {
    test('Slack gets text as well as blocks', () async {
      // A blocks-only message shows up in a phone notification as "This
      // content can't be displayed".
      final message = NotificationMessage.of(
        project: project,
        diff: newCritical,
        reason: 'a critical advisory',
      );

      final payload = message.payloadFor(NotificationChannel.slack);
      expect(payload['text'], contains('demo'));
      expect(payload['blocks'], isA<List<Object?>>());
    });

    test('Teams gets a MessageCard', () {
      final payload = NotificationMessage.of(
        project: project,
        diff: newCritical,
        reason: 'a critical advisory',
      ).payloadFor(NotificationChannel.teams);

      expect(payload['@type'], 'MessageCard');
      expect(payload['title'], contains('demo'));
    });

    test('names the package, the band and the fix', () {
      final body = NotificationMessage.of(
        project: project,
        diff: newCritical,
        reason: 'a critical advisory',
      ).body;

      expect(body, contains('http'));
      expect(body, contains('critical'));
      expect(body, contains('GHSA-critical'));
      expect(body, contains('fixed in 1.0.1'));
    });

    test('says when there is no published fix rather than staying silent', () {
      final diff = diffOf(
        [node('http')],
        [
          node('http', advisories: const [
            DepAdvisory(id: 'GHSA-nofix', severity: AdvisorySeverity.high),
          ]),
        ],
      );

      expect(
        NotificationMessage.of(
          project: project,
          diff: diff,
          reason: 'a high advisory',
        ).body,
        contains('no fix listed'),
      );
    });

    test('a long list is truncated and says it was', () {
      // A list that stops without saying so reads as a complete one.
      final before = [for (var i = 0; i < 30; i++) node('pkg$i')];
      final after = [
        for (var i = 0; i < 30; i++)
          node('pkg$i', advisories: [criticalAdvisory]),
      ];

      final body = NotificationMessage.of(
        project: project,
        diff: diffOf(before, after),
        reason: 'a critical advisory',
        maxLines: 5,
      ).body;

      expect(body, contains('and 25 more'));
    });

    test('a link is included only when the deployment gave one', () {
      final withLink = NotificationMessage.of(
        project: project,
        diff: newCritical,
        reason: 'x',
        link: 'https://depcontrol.test/projects/p1',
      ).payloadFor(NotificationChannel.teams);
      expect(withLink['potentialAction'], isNotNull);

      final without = NotificationMessage.of(
        project: project,
        diff: newCritical,
        reason: 'x',
      ).payloadFor(NotificationChannel.teams);
      expect(without.containsKey('potentialAction'), isFalse);
    });

    test('package names are qualified only when the diff spans ecosystems', () {
      final oneEcosystem = NotificationMessage.of(
        project: project,
        diff: newCritical,
        reason: 'x',
      ).body;
      expect(oneEcosystem, isNot(contains('(dart)')));

      final both = diffOf(
        [],
        [
          DepNode(
            name: 'http',
            kind: DepKind.direct,
            installed: '1.0.0',
            advisories: const [criticalAdvisory],
          ),
          const DepNode(
            name: 'http',
            ecosystem: 'npm',
            kind: DepKind.direct,
            installed: '0.0.1',
            advisories: [criticalAdvisory],
          ),
        ],
      );

      expect(
        NotificationMessage.of(project: project, diff: both, reason: 'x').body,
        contains('(npm)'),
      );
    });

    test('the payload is valid JSON', () {
      // It goes out as an encoded body; a value that cannot encode would fail
      // at the socket rather than here.
      expect(
        () => jsonEncode(
          NotificationMessage.of(
            project: project,
            diff: newCritical,
            reason: 'x',
            link: 'https://depcontrol.test/projects/p1',
          ).payloadFor(NotificationChannel.slack),
        ),
        returnsNormally,
      );
    });
  });
}
