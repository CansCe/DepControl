import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/routing/app_route.dart';
import 'package:frontend/routing/app_router.dart';

void main() {
  group('parsing a URL', () {
    test('reads the three routes', () {
      expect(AppRoute.parse('/'), const AppRoute.registry());
      expect(AppRoute.parse('/settings'), const AppRoute.settings());
      expect(AppRoute.parse('/projects/abc'), const AppRoute.report('abc'));
    });

    test('round-trips through the address bar', () {
      for (final route in const [
        AppRoute.registry(),
        AppRoute.settings(),
        AppRoute.report('7f3c-91'),
      ]) {
        expect(AppRoute.parse(route.location), route);
      }
    });

    test('an id with URL-significant characters survives the trip', () {
      const route = AppRoute.report('a b/c?d');
      expect(route.location, '/projects/a%20b%2Fc%3Fd');
      expect(AppRoute.parse(route.location), route);
    });

    test('anything unrecognised is the registry, never an error', () {
      // A link that picked up a trailing character should land somewhere, and
      // a 404 page for a three-route app would mostly be shown to people whose
      // link was very nearly right.
      expect(AppRoute.parse('/nonsense'), const AppRoute.registry());
      expect(AppRoute.parse(''), const AppRoute.registry());
      expect(AppRoute.parse(null), const AppRoute.registry());
      // A project id is required — `/projects` alone names no project.
      expect(AppRoute.parse('/projects'), const AppRoute.registry());
      expect(AppRoute.parse('/projects/'), const AppRoute.registry());
    });

    test('trailing segments do not change which route it is', () {
      expect(AppRoute.parse('/projects/abc/anything'),
          const AppRoute.report('abc'));
      expect(AppRoute.parse('/settings/deep'), const AppRoute.settings());
    });
  });

  group('the parser', () {
    test('restores what it parsed', () async {
      const parser = AppRouteParser();
      final route = await parser.parseRouteInformation(
        RouteInformation(uri: Uri.parse('/projects/p1')),
      );

      expect(route, const AppRoute.report('p1'));
      expect(parser.restoreRouteInformation(route).uri.path, '/projects/p1');
    });
  });

  group('the stack', () {
    // The client is only handed on to screens; nothing here builds one, so it
    // is never called.
    AppRouterDelegate delegate() => AppRouterDelegate(api: ApiClient());

    test('starts on the registry', () {
      expect(delegate().stack, [const AppRoute.registry()]);
    });

    test('a deep link keeps the registry underneath', () async {
      // So that back goes somewhere sensible on a cold load, rather than out of
      // the app.
      final d = delegate();
      await d.setNewRoutePath(const AppRoute.report('p1'));

      expect(d.stack, [
        const AppRoute.registry(),
        const AppRoute.report('p1'),
      ]);
      expect(d.currentConfiguration, const AppRoute.report('p1'));
    });

    test('a deep link to the registry does not stack it twice', () async {
      final d = delegate();
      await d.setNewRoutePath(const AppRoute.registry());

      expect(d.stack, [const AppRoute.registry()]);
    });

    test('going home leaves one screen, not two', () {
      final d = delegate()
        ..go(const AppRoute.report('p1'))
        ..go(const AppRoute.registry());

      expect(d.stack, [const AppRoute.registry()]);
    });

    test('popping returns to what was underneath', () {
      final d = delegate()..go(const AppRoute.settings());

      expect(d.pop(), isTrue);
      expect(d.currentConfiguration, const AppRoute.registry());
    });

    test('the registry cannot be popped off the bottom', () {
      final d = delegate();

      expect(d.pop(), isFalse);
      expect(d.stack, [const AppRoute.registry()]);
    });

    test('navigating to where you already are changes nothing', () {
      final d = delegate()..go(const AppRoute.report('p1'));
      final before = d.stack;

      d.go(const AppRoute.report('p1'));

      expect(d.stack, before);
    });

    test('two different reports are two entries', () {
      final d = delegate()
        ..go(const AppRoute.report('p1'))
        ..go(const AppRoute.report('p2'));

      expect(d.stack.length, 3);
      expect(d.currentConfiguration, const AppRoute.report('p2'));
    });

    test('notifies so the address bar follows', () {
      final d = delegate();
      var notified = 0;
      d.addListener(() => notified++);

      d.go(const AppRoute.settings());
      expect(notified, 1);

      // No move, no notification — otherwise the browser gets a history entry
      // for having stayed still.
      d.go(const AppRoute.settings());
      expect(notified, 1);
    });
  });
}
