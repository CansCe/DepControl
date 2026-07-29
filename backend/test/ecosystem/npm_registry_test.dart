import 'dart:convert';

import 'package:backend/src/ecosystem/npm/npm_registry.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  /// A registry serving [bodies] by request path, and recording what was asked
  /// for. OSV is pointed at the same mock, which answers `{}` unless a test
  /// says otherwise.
  ({NpmRegistry registry, List<String> paths}) serving(
    Map<String, Object> bodies,
  ) {
    final paths = <String>[];
    final client = MockClient((request) async {
      paths.add(request.url.path);
      final body = bodies[request.url.path];
      if (body == null) return http.Response('{}', 404);
      return http.Response(
        jsonEncode(body),
        200,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    });

    return (
      registry: NpmRegistry(client: client, baseUrl: 'https://registry.test'),
      paths: paths,
    );
  }

  group('engines', () {
    test('the ordinary object form', () async {
      final s = serving({
        '/express': {
          'dist-tags': {'latest': '4.18.2'},
          'versions': {
            '4.18.2': {
              'version': '4.18.2',
              'engines': {'node': '>= 0.10.0'},
            },
          },
        },
      });

      final versions = await s.registry.versions('express');
      expect(versions.single.sdkConstraint, '>= 0.10.0');
    });

    test('the legacy array form', () async {
      // npm has long accepted `["node >=0.6.0"]`, and packages old enough to
      // still carry it are exactly the ones a dependency report digs up. A
      // blind cast to a map threw on them — and because this runs while
      // building the version list, one such release took the whole list down,
      // leaving the package unresolvable rather than merely missing an engine
      // constraint. Found against the real registry, on `lodash`.
      final s = serving({
        '/lodash': {
          'dist-tags': {'latest': '4.17.21'},
          'versions': {
            '0.1.0': {
              'version': '0.1.0',
              'engines': ['node >=0.6.0'],
            },
            '4.17.21': {'version': '4.17.21'},
          },
        },
      });

      final versions = await s.registry.versions('lodash');
      expect(versions, hasLength(2));
      expect(
        versions.firstWhere((v) => v.version.toString() == '0.1.0').sdkConstraint,
        '>=0.6.0',
      );
    });

    test('a shape nobody anticipated is not fatal', () async {
      final s = serving({
        '/thing': {
          'versions': {
            '1.0.0': {'version': '1.0.0', 'engines': 'node >=4'},
          },
        },
      });

      final versions = await s.registry.versions('thing');
      expect(versions.single.sdkConstraint, isNull);
    });
  });

  test('dist-tags of the wrong shape does not throw', () async {
    final s = serving({
      '/thing': {'dist-tags': <String>[], 'versions': <String, Object>{}},
    });

    expect((await s.registry.info('thing')).latest, isNull);
  });

  group('scoped names', () {
    test('the slash is encoded, so the scope is not a path segment', () async {
      // `@types/node` unencoded requests the `node` document under a `@types`
      // prefix, which is a different thing entirely.
      final s = serving({
        '/@types%2Fnode': {
          'dist-tags': {'latest': '20.1.0'},
          'versions': <String, Object>{},
        },
      });

      expect((await s.registry.info('@types/node')).latest, '20.1.0');
      expect(s.paths, contains('/@types%2Fnode'));
    });
  });

  group('package names', () {
    test('accepts what npm accepts', () {
      final s = serving(const {});
      expect(s.registry.isValidPackageName('lodash'), isTrue);
      expect(s.registry.isValidPackageName('@types/node'), isTrue);
      expect(s.registry.isValidPackageName('some.package_name-1'), isTrue);
    });

    test('refuses what would not be a request worth making', () {
      final s = serving(const {});
      expect(s.registry.isValidPackageName('../../-/all'), isFalse);
      expect(s.registry.isValidPackageName('UPPERCASE'), isFalse);
      expect(s.registry.isValidPackageName('.hidden'), isFalse);
      expect(s.registry.isValidPackageName('a' * 215), isFalse);
      expect(s.registry.isValidPackageName(''), isFalse);
    });

    test('an invalid name issues no request at all', () async {
      final s = serving(const {});
      await s.registry.info('../../-/all');
      expect(s.paths, isEmpty);
    });
  });

  group('licences', () {
    test('the string form, read from the installed version', () async {
      final s = serving({
        '/lodash/4.17.20': {'license': 'MIT'},
      });

      final license = await s.registry.licenseFor('lodash', '4.17.20', '4.17.21');
      expect(license.spdxId, 'MIT');
      expect(license.category, LicenseCategory.permissive);
      expect(license.source, LicenseSource.installedVersion);
      expect(license.readFromVersion, '4.17.20');
    });

    test('falls back to the latest release, and says which it read', () async {
      // A version the registry no longer serves a document for.
      final s = serving({
        '/thing/2.0.0': {'license': 'Apache-2.0'},
      });

      final license = await s.registry.licenseFor('thing', '1.0.0', '2.0.0');
      expect(license.spdxId, 'Apache-2.0');
      expect(license.source, LicenseSource.latestRelease);
      expect(license.readFromVersion, '2.0.0');
    });

    test('the deprecated object and array forms', () async {
      final object = serving({
        '/a/1.0.0': {
          'license': {'type': 'ISC', 'url': 'https://example.com'},
        },
      });
      expect((await object.registry.licenseFor('a', '1.0.0', null)).spdxId, 'ISC');

      final array = serving({
        '/b/1.0.0': {
          'licenses': [
            {'type': 'BSD-3-Clause'},
          ],
        },
      });
      expect(
        (await array.registry.licenseFor('b', '1.0.0', null)).spdxId,
        'BSD-3-Clause',
      );
    });

    test('an SPDX expression keeps its text and goes to review', () async {
      // No single-id table can classify `(MIT OR Apache-2.0)`, and filing an
      // unrecognised licence under "probably fine" is the one error that gets
      // a package shipped.
      final s = serving({
        '/c/1.0.0': {'license': '(MIT OR Apache-2.0)'},
      });

      final license = await s.registry.licenseFor('c', '1.0.0', null);
      expect(license.spdxId, '(MIT OR Apache-2.0)');
      expect(license.category, LicenseCategory.unknown);
    });

    test('nothing published reads as undetermined, not as permissive', () async {
      final s = serving({
        '/d/1.0.0': <String, Object>{},
      });

      final license = await s.registry.licenseFor('d', '1.0.0', null);
      expect(license.spdxId, isNull);
      expect(license, same(PackageLicense.undetermined));
    });
  });

  group('dependencies of a published version', () {
    test('optional ones count and peers do not', () async {
      final s = serving({
        '/thing': {
          'versions': {
            '1.0.0': {
              'version': '1.0.0',
              'dependencies': {'lodash': '^4.0.0'},
              'optionalDependencies': {'fsevents': '^2.0.0'},
              'peerDependencies': {'react': '^18.0.0'},
            },
          },
        },
      });

      final version = (await s.registry.versions('thing')).single;
      expect(version.dependencies.keys, containsAll(['lodash', 'fsevents']));
      expect(version.dependencies.containsKey('react'), isFalse);
    });

    test('a specifier that is not a range is dropped', () async {
      // The registry publishes no versions to resolve a git URL against.
      final s = serving({
        '/thing': {
          'versions': {
            '1.0.0': {
              'version': '1.0.0',
              'dependencies': {
                'lodash': '^4.0.0',
                'forked': 'git+https://github.com/acme/forked.git',
              },
            },
          },
        },
      });

      final version = (await s.registry.versions('thing')).single;
      expect(version.dependencies.keys, ['lodash']);
    });
  });

  test('one packument serves info, versions and dependencyNames', () async {
    // Three questions, one request. Each of them needs the same document and
    // a scan asks all three of every package it finds.
    final s = serving({
      '/thing': {
        'dist-tags': {'latest': '1.0.0'},
        'versions': {
          '1.0.0': {
            'version': '1.0.0',
            'dependencies': {'lodash': '^4.0.0'},
          },
        },
      },
    });

    await s.registry.info('thing');
    await s.registry.versions('thing');
    await s.registry.dependencyNames('thing', '1.0.0');

    expect(s.paths.where((p) => p == '/thing'), hasLength(1));
  });
}
