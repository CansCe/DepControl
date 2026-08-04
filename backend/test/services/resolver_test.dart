import 'dart:convert';

import 'package:backend/src/ecosystem/ecosystems.dart';
import 'package:backend/src/services/pub_api_client.dart';
import 'package:backend/src/services/resolver.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

/// A fake pub.dev: package name -> {version -> {dependency -> constraint}}.
typedef Registry = Map<String, Map<String, Map<String, String>>>;

Resolver resolverFor(Registry registry) {
  final client = MockClient((request) async {
    final name = request.url.pathSegments.last;
    final package = registry[name];
    if (package == null) return http.Response('{}', 404);

    return http.Response(
      jsonEncode({
        'name': name,
        'latest': {'version': package.keys.last},
        'versions': [
          for (final entry in package.entries)
            {
              'version': entry.key,
              'pubspec': {'dependencies': entry.value},
            },
        ],
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });

  return Resolver(
    const DartEcosystem(),
    DartRegistry(PubApiClient(client: client), osv: OsvClient(client: client)),
  );
}

const _pubspec = '''
name: demo
environment:
  sdk: ^3.6.0
dependencies:
  http: ^1.0.0
dev_dependencies:
  test: ^1.20.0
''';

ManifestFiles files({String? lock}) =>
    ManifestFiles(manifest: _pubspec, lock: lock);

void main() {
  group('simulating a bump', () {
    test('reports the new version of the changed package', () async {
      final resolver = resolverFor({
        'http': {'1.0.0': {}, '1.5.0': {}, '2.0.0': {}, '2.1.0': {}},
        'test': {'1.25.0': {}},
      });

      final result = await resolver.simulate(
        files(
          lock: 'packages:\n'
              '  http:\n'
              '    dependency: "direct main"\n'
              '    version: "1.5.0"\n',
        ),
        const ResolutionRequest(package: 'http', targetConstraint: '^2.0.0'),
      );

      expect(result.success, isTrue);
      final change = result.changes.firstWhere((c) => c.package == 'http');
      expect(change.from, '1.5.0');
      expect(change.to, '2.1.0');
    });

    test('surfaces packages pulled in by the change', () async {
      final resolver = resolverFor({
        'http': {
          '1.0.0': {},
          '2.0.0': {'brand_new': '^1.0.0'},
        },
        'brand_new': {'1.0.0': {}},
        'test': {'1.25.0': {}},
      });

      final result = await resolver.simulate(
        files(),
        const ResolutionRequest(package: 'http', targetConstraint: '^2.0.0'),
      );

      expect(result.success, isTrue);
      final added = result.changes.firstWhere((c) => c.package == 'brand_new');
      expect(added.from, isNull, reason: 'newly added');
      expect(added.to, '1.0.0');
    });

    test('adds a package the project does not depend on yet', () async {
      final resolver = resolverFor({
        'http': {'1.0.0': {}},
        'test': {'1.25.0': {}},
        'newcomer': {'3.0.0': {}},
      });

      final result = await resolver.simulate(
        files(),
        const ResolutionRequest(
          package: 'newcomer',
          targetConstraint: '^3.0.0',
        ),
      );

      expect(result.success, isTrue);
      final added = result.changes.firstWhere((c) => c.package == 'newcomer');
      expect(added.from, isNull);
      expect(added.to, '3.0.0');
    });

    test('leaves untouched packages out of the change list', () async {
      final resolver = resolverFor({
        'http': {'1.0.0': {}, '1.5.0': {}},
        'test': {'1.25.0': {}},
      });

      final result = await resolver.simulate(
        files(
          lock: 'packages:\n'
              '  http:\n'
              '    dependency: "direct main"\n'
              '    version: "1.5.0"\n'
              '  test:\n'
              '    dependency: "direct dev"\n'
              '    version: "1.25.0"\n',
        ),
        const ResolutionRequest(package: 'http', targetConstraint: '^1.0.0'),
      );

      expect(result.success, isTrue);
      expect(result.changes.map((c) => c.package), isNot(contains('test')));
    });
  });

  group('reporting failure', () {
    test('explains a constraint nothing satisfies', () async {
      final resolver = resolverFor({
        'http': {'1.0.0': {}, '2.0.0': {}},
        'test': {'1.25.0': {}},
      });

      final result = await resolver.simulate(
        files(),
        const ResolutionRequest(package: 'http', targetConstraint: '^9.0.0'),
      );

      expect(result.success, isFalse);
      expect(result.conflict, contains('http'));
      expect(result.conflict, contains('no published version'));
    });

    test('names the other dependent when two requirements collide', () async {
      final resolver = resolverFor({
        // Pinning http to 2.x forces shared 2.x, but test still needs 1.x.
        'http': {
          '1.0.0': {'shared': '^1.0.0'},
          '2.0.0': {'shared': '^2.0.0'},
        },
        'test': {
          '1.20.0': {'shared': '^1.0.0'},
          '1.25.0': {'shared': '^1.0.0'},
        },
        'shared': {'1.0.0': {}, '2.0.0': {}},
      });

      final result = await resolver.simulate(
        files(),
        const ResolutionRequest(package: 'http', targetConstraint: '^2.0.0'),
      );

      expect(result.success, isFalse);
      expect(result.conflict, contains('shared'));
      // The message should say who is pulling in the incompatible ranges.
      expect(result.conflict, anyOf(contains('http'), contains('test')));
    });

    test('rejects a malformed constraint without calling pub.dev', () async {
      final resolver = resolverFor({});

      final result = await resolver.simulate(
        files(),
        const ResolutionRequest(
          package: 'http',
          targetConstraint: 'not-a-constraint',
        ),
      );

      expect(result.success, isFalse);
      expect(result.conflict, contains('not a valid version constraint'));
      expect(result.changes, isEmpty);
    });

    test('reports an unparseable pubspec instead of throwing', () async {
      final resolver = resolverFor({});

      final result = await resolver.simulate(
        const ManifestFiles(manifest: 'this: is: not: a: pubspec'),
        const ResolutionRequest(package: 'http', targetConstraint: '^1.0.0'),
      );

      expect(result.success, isFalse);
      expect(result.conflict, isNotNull);
    });
  });

  group('output', () {
    test('includes a human-readable summary of the simulation', () async {
      final resolver = resolverFor({
        'http': {'1.0.0': {}, '2.0.0': {}},
        'test': {'1.25.0': {}},
      });

      final result = await resolver.simulate(
        files(),
        const ResolutionRequest(package: 'http', targetConstraint: '^2.0.0'),
      );

      expect(result.rawOutput, contains('http'));
      expect(result.rawOutput, contains('^2.0.0'));
      expect(result.request.package, 'http');
    });
  });
}
