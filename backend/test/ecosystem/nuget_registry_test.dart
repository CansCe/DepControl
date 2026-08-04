import 'dart:convert';

import 'package:backend/src/ecosystem/nuget/nuget_registry.dart';
import 'package:backend/src/ecosystem/osv_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

/// One registration leaf, as nuget.org inlines it in a page.
Map<String, Object?> leaf(
  String version, {
  String? license,
  Map<String, String> dependencies = const {},
  bool listed = true,
}) =>
    {
      'listed': listed,
      'catalogEntry': {
        'version': version,
        if (license != null) 'licenseExpression': license,
        'dependencyGroups': [
          {
            'targetFramework': 'net8.0',
            'dependencies': [
              for (final entry in dependencies.entries)
                {'id': entry.key, 'range': entry.value},
            ],
          },
        ],
      },
    };

void main() {
  /// A registry serving [bodies] by request path, recording what was asked for.
  ({NuGetRegistry registry, List<String> paths, List<String> methods}) serving(
    Map<String, Object> bodies, {
    Map<String, String> headers = const {},
  }) {
    final paths = <String>[];
    final methods = <String>[];
    final client = MockClient((request) async {
      paths.add(request.url.path);
      methods.add(request.method);
      final body = bodies[request.url.path];
      if (body == null) return http.Response('{}', 404);
      if (body is String) {
        return http.Response(body, 200, headers: headers);
      }
      return http.Response(
        jsonEncode(body),
        200,
        headers: const {'content-type': 'application/json'},
      );
    });

    return (
      registry: NuGetRegistry(
        client: client,
        baseUrl: 'https://nuget.test',
        osv: OsvClient(client: client, baseUrl: 'https://osv.test'),
      ),
      paths: paths,
      methods: methods,
    );
  }

  String index(String id) =>
      '/v3/registration5-gz-semver2/$id/index.json';

  group('versions', () {
    test('are read from the inlined registration pages', () async {
      final s = serving({
        index('serilog'): {
          'items': [
            {
              'items': [leaf('2.0.0'), leaf('3.1.1')],
            },
          ],
        },
      });

      final versions = await s.registry.versions('Serilog');

      expect(versions.map((v) => v.version.toString()), ['2.0.0', '3.1.1']);
    });

    test('a four-part version is normalised as it is read', () async {
      // Left alone it parses as nothing, and a package nothing can parse is a
      // package nothing can report on.
      final s = serving({
        index('nhibernate'): {
          'items': [
            {
              'items': [leaf('5.2.7.4000')],
            },
          ],
        },
      });

      final versions = await s.registry.versions('NHibernate');

      expect(versions.single.version.toString(), '5.2.7+4000');
    });

    test('the id is lowercased for the URL and the casing is the caller"s',
        () async {
      final s = serving({
        index('newtonsoft.json'): {
          'items': [
            {
              'items': [leaf('13.0.3')],
            },
          ],
        },
      });

      await s.registry.versions('Newtonsoft.Json');

      expect(s.paths.single, index('newtonsoft.json'));
    });
  });

  group('latest', () {
    test('is the highest stable release', () async {
      final s = serving({
        index('serilog'): {
          'items': [
            {
              'items': [leaf('3.1.1'), leaf('4.0.0-dev.1')],
            },
          ],
        },
      });

      expect((await s.registry.info('Serilog')).latest, '3.1.1');
    });

    test('falls back to a pre-release for a package that has only those',
        () async {
      final s = serving({
        index('early'): {
          'items': [
            {
              'items': [leaf('0.1.0-alpha.1')],
            },
          ],
        },
      });

      expect((await s.registry.info('Early')).latest, '0.1.0-alpha.1');
    });

    test('an unlisted release is not what anyone is behind', () async {
      final s = serving({
        index('serilog'): {
          'items': [
            {
              'items': [leaf('3.1.1'), leaf('3.2.0', listed: false)],
            },
          ],
        },
      });

      expect((await s.registry.info('Serilog')).latest, '3.1.1');
    });
  });

  group('dependencies', () {
    test('are merged across target frameworks', () async {
      final s = serving({
        index('acme'): {
          'items': [
            {
              'items': [
                {
                  'catalogEntry': {
                    'version': '1.0.0',
                    'dependencyGroups': [
                      {
                        'targetFramework': 'net8.0',
                        'dependencies': [
                          {'id': 'Serilog', 'range': '[3.0,)'},
                        ],
                      },
                      {
                        'targetFramework': 'net48',
                        'dependencies': [
                          {'id': 'Newtonsoft.Json', 'range': '[13.0,)'},
                        ],
                      },
                    ],
                  },
                },
              ],
            },
          ],
        },
      });

      expect(
        await s.registry.dependencyNames('Acme', '1.0.0'),
        ['Serilog', 'Newtonsoft.Json'],
      );
    });

    test('carry the range so resolution can read it', () async {
      final s = serving({
        index('acme'): {
          'items': [
            {
              'items': [
                leaf('1.0.0', dependencies: {'Serilog': '[3.0,4.0)'}),
              ],
            },
          ],
        },
      });

      final version = (await s.registry.versions('Acme')).single;
      expect(version.dependencies['Serilog'], '[3.0,4.0)');
    });
  });

  group('licences', () {
    test('the SPDX expression of the installed version wins', () async {
      final s = serving({
        index('serilog'): {
          'items': [
            {
              'items': [
                leaf('2.0.0', license: 'Apache-2.0'),
                leaf('3.1.1', license: 'MIT'),
              ],
            },
          ],
        },
      });

      final license = await s.registry.licenseFor('Serilog', '2.0.0', '3.1.1');

      expect(license.spdxId, 'Apache-2.0');
      expect(license.source, LicenseSource.installedVersion);
    });

    test('falls back to the latest release, and says which it read', () async {
      final s = serving({
        index('serilog'): {
          'items': [
            {
              'items': [leaf('3.1.1', license: 'MIT')],
            },
          ],
        },
      });

      final license = await s.registry.licenseFor('Serilog', '1.0.0', '3.1.1');

      expect(license.spdxId, 'MIT');
      expect(license.source, LicenseSource.latestRelease);
    });

    test('a licenseUrl is a link, not a licence', () async {
      // Turning a repository URL into an SPDX id would invent the one field a
      // compliance report exists to be sure of.
      final s = serving({
        index('old'): {
          'items': [
            {
              'items': [
                {
                  'catalogEntry': {
                    'version': '1.0.0',
                    'licenseUrl':
                        'https://github.com/acme/old/blob/master/LICENSE',
                  },
                },
              ],
            },
          ],
        },
      });

      final license = await s.registry.licenseFor('Old', '1.0.0', '1.0.0');
      expect(license, PackageLicense.undetermined);
    });
  });

  group('size', () {
    test('is a HEAD of the package, in NuGet"s own spelling of the version',
        () async {
      final s = serving(
        {
          '/v3-flatcontainer/nhibernate/5.2.7.4000/nhibernate.5.2.7.4000.nupkg':
              '',
        },
        headers: const {'content-length': '4096'},
      );

      final size = await s.registry.sizeOf('NHibernate', '5.2.7+4000');

      expect(size!.bytes, 4096);
      expect(size.basis, SizeBasis.archive);
      expect(s.methods.single, 'HEAD');
    });

    test('a package the registry will not serve is unmeasured, not zero',
        () async {
      final s = serving(const {});
      expect(await s.registry.sizeOf('Missing', '1.0.0'), isNull);
    });
  });

  group('names that are not packages', () {
    test('are refused before a request is made', () async {
      final s = serving(const {});

      expect(s.registry.isValidPackageName('Newtonsoft.Json'), isTrue);
      expect(s.registry.isValidPackageName('Acme_Core-1'), isTrue);
      expect(s.registry.isValidPackageName('../../admin'), isFalse);
      expect(s.registry.isValidPackageName('a..b'), isFalse);
      expect(s.registry.isValidPackageName('.hidden'), isFalse);
      expect(s.registry.isValidPackageName('has space'), isFalse);
      expect(s.registry.isValidPackageName(''), isFalse);
      expect(s.registry.isValidPackageName('a' * 101), isFalse);

      await s.registry.info('../../admin');
      expect(s.paths, isEmpty);
    });
  });

  test('a linked page pointing off nuget.org is not followed', () async {
    // The index is a document fetched from the internet. It must not be able to
    // aim this server at an address of its choosing.
    final s = serving({
      index('acme'): {
        'items': [
          {'@id': 'https://elsewhere.test/page.json'},
        ],
      },
    });

    await s.registry.versions('Acme');

    expect(s.paths, [index('acme')]);
  });

  test('one document answers versions, licences and latest between them',
      () async {
    final s = serving({
      index('serilog'): {
        'items': [
          {
            'items': [leaf('3.1.1', license: 'MIT')],
          },
        ],
      },
    });

    await s.registry.info('Serilog');
    await s.registry.versions('Serilog');
    await s.registry.dependencyNames('Serilog', '3.1.1');
    await s.registry.licenseFor('Serilog', '3.1.1', '3.1.1');

    // One registration fetch, plus the OSV query `info` makes.
    expect(s.paths.where((p) => p.startsWith('/v3/')), hasLength(1));
  });
}
