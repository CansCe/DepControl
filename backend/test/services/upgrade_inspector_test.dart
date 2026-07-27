import 'dart:convert';

import 'package:backend/src/services/pub_api_client.dart';
import 'package:backend/src/services/upgrade_inspector.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

/// version -> (sdk constraint, dependencies)
typedef Versions = Map<String, ({String? sdk, Map<String, String> deps})>;

UpgradeInspector inspectorFor(Versions versions) {
  final client = MockClient((request) async {
    final name = request.url.pathSegments.last;
    return http.Response(
      jsonEncode({
        'name': name,
        'latest': {'version': versions.keys.last},
        'versions': [
          for (final entry in versions.entries)
            {
              'version': entry.key,
              'pubspec': {
                if (entry.value.sdk != null)
                  'environment': {'sdk': entry.value.sdk},
                'dependencies': entry.value.deps,
              },
            },
        ],
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });

  return UpgradeInspector(PubApiClient(client: client));
}

({String? sdk, Map<String, String> deps}) v({
  String? sdk,
  Map<String, String> deps = const {},
}) =>
    (sdk: sdk, deps: deps);

void main() {
  group('breaking boundaries', () {
    test('names each major version the jump passes', () async {
      final inspector = inspectorFor({
        '1.9.0': v(),
        '2.0.0': v(),
        '2.5.0': v(),
        '3.0.0': v(),
        '3.1.0': v(),
      });

      final impact = await inspector.inspect('demo', from: '1.9.0');

      expect(impact!.to, '3.1.0');
      expect(impact.majorVersionsCrossed, ['2.0.0', '3.0.0']);
      expect(impact.releasesBetween, 4);
    });

    test('a minor jump crosses nothing', () async {
      final inspector = inspectorFor({'1.0.0': v(), '1.4.0': v()});

      final impact = await inspector.inspect('demo', from: '1.0.0');

      expect(impact!.majorVersionsCrossed, isEmpty);
      expect(impact.hasFindings, isFalse);
    });

    // Below 1.0.0 the minor component is the breaking one.
    test('treats a pre-1.0 minor bump as a boundary', () async {
      final inspector = inspectorFor({
        '0.13.0': v(),
        '0.14.0': v(),
        '0.15.0': v(),
      });

      final impact = await inspector.inspect('demo', from: '0.13.0');

      expect(impact!.majorVersionsCrossed, ['0.14.0', '0.15.0']);
    });

    test('ignores prereleases when picking the target', () async {
      final inspector = inspectorFor({
        '1.0.0': v(),
        '2.0.0': v(),
        '3.0.0-beta.1': v(),
      });

      final impact = await inspector.inspect('demo', from: '1.0.0');

      expect(impact!.to, '2.0.0');
    });
  });

  group('sdk requirements', () {
    test('flags a version needing a newer SDK than the project allows',
        () async {
      final inspector = inspectorFor({
        '1.0.0': v(sdk: '^3.0.0'),
        '2.0.0': v(sdk: '^3.8.0'),
      });

      final impact = await inspector.inspect(
        'demo',
        from: '1.0.0',
        projectSdk: '^3.6.0',
      );

      expect(impact!.sdkTooNew, isTrue);
      expect(impact.sdkAfter, '^3.8.0');
      expect(impact.projectSdk, '^3.6.0');
    });

    test('does not flag a version the project SDK already satisfies',
        () async {
      final inspector = inspectorFor({
        '1.0.0': v(sdk: '^3.0.0'),
        '2.0.0': v(sdk: '^3.4.0'),
      });

      final impact = await inspector.inspect(
        'demo',
        from: '1.0.0',
        projectSdk: '^3.6.0',
      );

      expect(impact!.sdkTooNew, isFalse);
    });

    test('skips the check when the project SDK is unknown', () async {
      final inspector = inspectorFor({
        '1.0.0': v(sdk: '^3.0.0'),
        '2.0.0': v(sdk: '^3.9.0'),
      });

      final impact = await inspector.inspect('demo', from: '1.0.0');

      expect(impact!.sdkTooNew, isFalse);
      expect(impact.projectSdk, isNull);
    });
  });

  group('dependency changes', () {
    test('reports additions, removals and tightened constraints', () async {
      final inspector = inspectorFor({
        '1.0.0': v(deps: {'collection': '^1.0.0', 'meta': '^1.0.0'}),
        '2.0.0': v(deps: {'collection': '^2.0.0', 'path': '^1.9.0'}),
      });

      final impact = await inspector.inspect('demo', from: '1.0.0');
      final changes = {for (final c in impact!.dependencyChanges) c.package: c};

      expect(changes['collection']!.kind, DependencyDeltaKind.changed);
      expect(changes['collection']!.before, '^1.0.0');
      expect(changes['collection']!.after, '^2.0.0');

      expect(changes['path']!.kind, DependencyDeltaKind.added);
      expect(changes['meta']!.kind, DependencyDeltaKind.removed);
    });

    test('an unchanged dependency is not reported', () async {
      final inspector = inspectorFor({
        '1.0.0': v(deps: {'collection': '^1.0.0'}),
        '1.1.0': v(deps: {'collection': '^1.0.0'}),
      });

      final impact = await inspector.inspect('demo', from: '1.0.0');

      expect(impact!.dependencyChanges, isEmpty);
    });
  });

  group('nothing to report', () {
    test('already on the newest version', () async {
      final inspector = inspectorFor({'1.0.0': v(), '2.0.0': v()});
      expect(await inspector.inspect('demo', from: '2.0.0'), isNull);
    });

    test('an unresolved installed version', () async {
      final inspector = inspectorFor({'1.0.0': v()});
      expect(
        await inspector.inspect('demo', from: '(unresolved)'),
        isNull,
      );
    });

    test('a package pub.dev does not serve', () async {
      final inspector = UpgradeInspector(
        PubApiClient(client: MockClient((_) async => http.Response('{}', 404))),
      );
      expect(await inspector.inspect('ghost', from: '1.0.0'), isNull);
    });
  });

  group('serialisation', () {
    test('round-trips through json', () async {
      final inspector = inspectorFor({
        '1.0.0': v(sdk: '^3.0.0', deps: {'meta': '^1.0.0'}),
        '2.0.0': v(sdk: '^3.8.0', deps: {'meta': '^2.0.0'}),
      });

      final impact = await inspector.inspect(
        'demo',
        from: '1.0.0',
        projectSdk: '^3.6.0',
      );
      final restored = UpgradeImpact.fromJson(impact!.toJson());

      expect(restored.package, 'demo');
      expect(restored.to, '2.0.0');
      expect(restored.majorVersionsCrossed, ['2.0.0']);
      expect(restored.sdkTooNew, isTrue);
      expect(restored.dependencyChanges.single.package, 'meta');
      expect(restored.changelogUrl, contains('pub.dev'));
    });
  });
}
