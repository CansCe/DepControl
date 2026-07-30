import 'dart:convert';
import 'dart:io';

import 'package:backend/src/auth/auth_user.dart';
import 'package:backend/src/deps.dart';
import 'package:backend/src/repository/notification_store.dart';
import 'package:backend/src/repository/project_repository.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import '../support/fakes.dart';

// Route handlers live outside lib/, so they're imported by path.
import '../../routes/notifications/index.dart' as notifications_route;
import '../../routes/notifications/[id].dart' as notification_route;

class _MockRequestContext extends Mock implements RequestContext {}

class _MockRequest extends Mock implements Request {}

void main() {
  late InMemoryProjectRepository repository;
  late InMemoryNotificationStore notifications;
  late Deps deps;

  const alice = AuthUser(
    id: 'a0000000-0000-0000-0000-00000000000a',
    role: 'authenticated',
    email: 'alice@example.com',
  );
  const bob = AuthUser(
    id: 'b0000000-0000-0000-0000-00000000000b',
    role: 'authenticated',
    email: 'bob@example.com',
  );

  const slackUrl = 'https://hooks.slack.com/services/T00/B00/abcdefghijkl';

  _MockRequestContext contextFor({
    required AuthUser user,
    HttpMethod method = HttpMethod.get,
    Object? body,
  }) {
    final request = _MockRequest();
    when(() => request.method).thenReturn(method);
    when(() => request.uri).thenReturn(Uri.parse('http://localhost/notifications'));
    when(request.json).thenAnswer(
      (_) async => body ?? (throw const FormatException('no body')),
    );

    final context = _MockRequestContext();
    when(() => context.request).thenReturn(request);
    when(context.read<Deps>).thenReturn(deps);
    when(context.read<AuthUser>).thenReturn(user);
    return context;
  }

  Future<Map<String, dynamic>> jsonOf(Response response) async =>
      jsonDecode(await response.body()) as Map<String, dynamic>;

  setUp(() async {
    repository = InMemoryProjectRepository();
    notifications = InMemoryNotificationStore();
    deps = Deps.forTesting(
      repository: repository,
      notifications: notifications,
      gitFetcher: FakeGitFetcher(),
      analyzer: FakeAnalyzer(),
    );

    await repository.add(
      Project(
        id: 'p-alice',
        gitUrl: 'https://github.com/acme/demo.git',
        name: 'demo',
        ownerId: alice.id,
        addedAt: DateTime.utc(2026, 1, 1),
      ),
    );
  });

  group('POST /notifications', () {
    test('creates a target and never echoes the URL back', () async {
      // The URL is a bearer credential: anything holding it can post to the
      // channel. A create that returns it hands it to every log and proxy in
      // between.
      final response = await notifications_route.onRequest(
        contextFor(
          user: alice,
          method: HttpMethod.post,
          body: {'channel': 'slack', 'url': slackUrl},
        ),
      );

      expect(response.statusCode, HttpStatus.created);
      final body = await jsonOf(response);
      expect(body['url'], isNot(contains('abcdefghijkl')));
      expect(body['url'], isNot(contains('T00')));
      expect(body['url'], contains('hooks.slack.com'));
      expect(body['channel'], 'slack');
    });

    test('refuses a URL this server will not deliver to', () async {
      final response = await notifications_route.onRequest(
        contextFor(
          user: alice,
          method: HttpMethod.post,
          body: {'channel': 'slack', 'url': 'https://attacker.test/hook'},
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect((await jsonOf(response))['error'], contains('hooks.slack.com'));
      expect(await notifications.targetsFor(alice.id), isEmpty);
    });

    test('refuses a target that could never fire', () async {
      final response = await notifications_route.onRequest(
        contextFor(
          user: alice,
          method: HttpMethod.post,
          body: {
            'channel': 'slack',
            'url': slackUrl,
            'onNewAdvisory': false,
            'onBreakingChange': false,
          },
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect((await jsonOf(response))['error'], contains('never fire'));
    });

    test('refuses an unknown channel and an unknown severity', () async {
      final badChannel = await notifications_route.onRequest(
        contextFor(
          user: alice,
          method: HttpMethod.post,
          body: {'channel': 'carrier-pigeon', 'url': slackUrl},
        ),
      );
      expect(badChannel.statusCode, HttpStatus.badRequest);

      final badSeverity = await notifications_route.onRequest(
        contextFor(
          user: alice,
          method: HttpMethod.post,
          body: {
            'channel': 'slack',
            'url': slackUrl,
            'minSeverity': 'apocalyptic',
          },
        ),
      );
      expect(badSeverity.statusCode, HttpStatus.badRequest);
    });

    test('a target may name a project, but only one the caller owns', () async {
      final mine = await notifications_route.onRequest(
        contextFor(
          user: alice,
          method: HttpMethod.post,
          body: {
            'channel': 'slack',
            'url': slackUrl,
            'projectId': 'p-alice',
          },
        ),
      );
      expect(mine.statusCode, HttpStatus.created);

      // Somebody else's project id is a 404, the same as everywhere else — it
      // would otherwise create a target that quietly never matches.
      final theirs = await notifications_route.onRequest(
        contextFor(
          user: bob,
          method: HttpMethod.post,
          body: {
            'channel': 'slack',
            'url': slackUrl,
            'projectId': 'p-alice',
          },
        ),
      );
      expect(theirs.statusCode, HttpStatus.notFound);
    });

    test('a body that is not an object is a bad request', () async {
      final response = await notifications_route.onRequest(
        contextFor(user: alice, method: HttpMethod.post),
      );
      expect(response.statusCode, HttpStatus.badRequest);
    });
  });

  group('GET /notifications', () {
    test('lists this owner\'s targets, redacted', () async {
      await notifications_route.onRequest(
        contextFor(
          user: alice,
          method: HttpMethod.post,
          body: {'channel': 'slack', 'url': slackUrl},
        ),
      );

      final body = await jsonOf(
        await notifications_route.onRequest(contextFor(user: alice)),
      );

      final targets = body['targets'] as List;
      expect(targets, hasLength(1));
      expect(targets.single['url'], isNot(contains('abcdefghijkl')));
    });

    test('does not list another owner\'s targets', () async {
      await notifications_route.onRequest(
        contextFor(
          user: alice,
          method: HttpMethod.post,
          body: {'channel': 'slack', 'url': slackUrl},
        ),
      );

      final body = await jsonOf(
        await notifications_route.onRequest(contextFor(user: bob)),
      );
      expect(body['targets'], isEmpty);
    });
  });

  group('DELETE /notifications/<id>', () {
    Future<String> createTarget(AuthUser user) async {
      final body = await jsonOf(
        await notifications_route.onRequest(
          contextFor(
            user: user,
            method: HttpMethod.post,
            body: {'channel': 'slack', 'url': slackUrl},
          ),
        ),
      );
      return body['id'] as String;
    }

    test('removes it', () async {
      final id = await createTarget(alice);

      final response = await notification_route.onRequest(
        contextFor(user: alice, method: HttpMethod.delete),
        id,
      );

      expect(response.statusCode, HttpStatus.noContent);
      expect(await notifications.targetsFor(alice.id), isEmpty);
    });

    test('another owner gets a 404, not a 403', () async {
      final id = await createTarget(alice);

      final response = await notification_route.onRequest(
        contextFor(user: bob, method: HttpMethod.delete),
        id,
      );

      expect(response.statusCode, HttpStatus.notFound);
      expect(await notifications.targetsFor(alice.id), hasLength(1));
    });

    test('rejects anything but DELETE', () async {
      final response = await notification_route.onRequest(
        contextFor(user: alice),
        'whatever',
      );
      expect(response.statusCode, HttpStatus.methodNotAllowed);
    });
  });
}
