import 'dart:convert';

import 'package:backend/src/services/constraint_resolver.dart';
import 'package:backend/src/services/pub_api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// A fake pub.dev: package name -> {version -> {dependency -> constraint}}.
typedef Registry = Map<String, Map<String, Map<String, String>>>;

ConstraintResolver resolverFor(Registry registry, {int maxPackages = 200}) {
  final client = MockClient((request) async {
    final segments = request.url.pathSegments; // api/packages/<name>
    final name = segments.last;
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

  return ConstraintResolver(
    PubApiClient(client: client),
    maxPackages: maxPackages,
  );
}

void main() {
  group('picking a version', () {
    test('takes the highest version the constraint allows', () async {
      final resolver = resolverFor({
        'http': {'1.0.0': {}, '1.2.0': {}, '1.3.0': {}, '2.0.0': {}},
      });

      final resolved = await resolver.resolve({'http': '^1.0.0'});

      // 2.0.0 is outside ^1.0.0, so 1.3.0 wins.
      expect(resolved['http']!.version.toString(), '1.3.0');
      expect(resolved['http']!.isDirect, isTrue);
    });

    test('prefers a stable release over a newer prerelease', () async {
      final resolver = resolverFor({
        'http': {'1.2.0': {}, '1.3.0': {}, '1.4.0-beta.1': {}},
      });

      final resolved = await resolver.resolve({'http': '>=1.0.0 <2.0.0'});

      expect(resolved['http']!.version.toString(), '1.3.0');
    });

    test('uses a prerelease when nothing else satisfies the constraint',
        () async {
      final resolver = resolverFor({
        'http': {'1.0.0': {}, '2.0.0-beta.1': {}},
      });

      final resolved = await resolver.resolve({'http': '^2.0.0-beta.1'});

      expect(resolved['http']!.version.toString(), '2.0.0-beta.1');
    });

    test('omits a package whose constraint cannot be satisfied', () async {
      final resolver = resolverFor({
        'http': {'1.0.0': {}},
      });

      final resolved = await resolver.resolve({'http': '^9.0.0'});

      expect(resolved, isEmpty);
    });

    test('omits a package pub.dev does not serve', () async {
      final resolver = resolverFor({});
      final resolved = await resolver.resolve({'nonexistent': '^1.0.0'});
      expect(resolved, isEmpty);
    });
  });

  group('transitive dependencies', () {
    test('pulls in what the chosen versions require', () async {
      final resolver = resolverFor({
        'a': {
          '1.0.0': {'b': '^1.0.0'},
        },
        'b': {
          '1.0.0': {'c': '^1.0.0'},
          '1.1.0': {'c': '^1.0.0'},
        },
        'c': {'1.0.0': {}, '1.5.0': {}},
      });

      final resolved = await resolver.resolve({'a': '^1.0.0'});

      expect(resolved.keys, containsAll(['a', 'b', 'c']));
      expect(resolved['b']!.version.toString(), '1.1.0');
      expect(resolved['c']!.version.toString(), '1.5.0');
    });

    test('marks pulled-in packages as not direct', () async {
      final resolver = resolverFor({
        'a': {
          '1.0.0': {'b': '^1.0.0'},
        },
        'b': {'1.0.0': {}},
      });

      final resolved = await resolver.resolve({'a': '^1.0.0'});

      expect(resolved['a']!.isDirect, isTrue);
      expect(resolved['b']!.isDirect, isFalse);
      expect(resolved['a']!.dependencies, ['b']);
    });

    test('dev dependencies are resolved and marked direct', () async {
      final resolver = resolverFor({
        'test': {'1.25.0': {}},
      });

      final resolved =
          await resolver.resolve({}, dev: {'test': '^1.20.0'});

      expect(resolved['test']!.version.toString(), '1.25.0');
      expect(resolved['test']!.isDirect, isTrue);
    });
  });

  group('conflicting requirements', () {
    // Two dependents want different ranges of the same package; the resolver
    // must satisfy both rather than taking whichever it saw last.
    test('intersects constraints from multiple dependents', () async {
      final resolver = resolverFor({
        'a': {
          '1.0.0': {'shared': '^1.0.0'},
        },
        'b': {
          '1.0.0': {'shared': '<1.5.0'},
        },
        'shared': {'1.0.0': {}, '1.4.0': {}, '1.9.0': {}},
      });

      final resolved = await resolver.resolve({
        'a': '^1.0.0',
        'b': '^1.0.0',
      });

      // ^1.0.0 alone would give 1.9.0, but b caps it below 1.5.0.
      expect(resolved['shared']!.version.toString(), '1.4.0');
    });

    test('drops a package when the intersection is empty', () async {
      final resolver = resolverFor({
        'a': {
          '1.0.0': {'shared': '^2.0.0'},
        },
        'b': {
          '1.0.0': {'shared': '^1.0.0'},
        },
        'shared': {'1.0.0': {}, '2.0.0': {}},
      });

      final resolved = await resolver.resolve({
        'a': '^1.0.0',
        'b': '^1.0.0',
      });

      // No version satisfies both ^1.0.0 and ^2.0.0. Pub would backtrack onto
      // older versions of a or b; this resolver reports the conflict instead.
      expect(resolved.containsKey('shared'), isFalse);
      expect(resolved.keys, containsAll(['a', 'b']));
    });
  });

  group('safety', () {
    test('ignores git, path and sdk constraints', () async {
      final resolver = resolverFor({
        'http': {'1.0.0': {}},
      });

      final resolved = await resolver.resolve({
        'http': '^1.0.0',
        'flutter': 'any-sdk-thing {sdk: flutter}',
      });

      expect(resolved.keys, ['http']);
    });

    test('stops traversing once maxPackages is reached', () async {
      // A chain long enough to exceed the cap.
      final registry = <String, Map<String, Map<String, String>>>{};
      for (var i = 0; i < 20; i++) {
        registry['p$i'] = {
          '1.0.0': i < 19 ? {'p${i + 1}': '^1.0.0'} : <String, String>{},
        };
      }

      final resolver = resolverFor(registry, maxPackages: 5);
      final resolved = await resolver.resolve({'p0': '^1.0.0'});

      expect(resolved.length, lessThanOrEqualTo(6));
    });

    test('a cyclic dependency graph terminates', () async {
      final resolver = resolverFor({
        'a': {
          '1.0.0': {'b': '^1.0.0'},
        },
        'b': {
          '1.0.0': {'a': '^1.0.0'},
        },
      });

      final resolved = await resolver.resolve({'a': '^1.0.0'});

      expect(resolved.keys, containsAll(['a', 'b']));
    });
  });
}
