import 'dart:convert';

import 'package:backend/src/services/git_fetcher.dart';
import 'package:backend/src/services/pub_api_client.dart';
import 'package:backend/src/services/pubspec_analyzer.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

const _pubspecYaml = '''
name: demo
environment:
  sdk: ^3.6.0
dependencies:
  http: ^1.2.0
dev_dependencies:
  test: ^1.25.0
''';

const _pubspecLock = '''
packages:
  http:
    dependency: "direct main"
    version: "1.2.0"
  test:
    dependency: "direct dev"
    version: "1.25.0"
''';

/// Stubs the pub.dev endpoints the analyzer touches, so the tests never hit the
/// network. `latest` is keyed by package name.
///
/// [versionTags] is keyed `package@version` and [latestTags] by package name,
/// mirroring pub.dev's two score endpoints: analysis is published per version
/// and dropped for old ones, so a package can have tags for its latest release
/// and none for the version a project actually has installed.
PubApiClient _stubPub(
  Map<String, String> latest, {
  Map<String, List<Map<String, dynamic>>> advisories = const {},
  Map<String, List<String>> published = const {},
  Map<String, List<String>> versionTags = const {},
  Map<String, List<String>> latestTags = const {},
}) {
  final client = MockClient((request) async {
    final path = request.url.path;

    if (path.endsWith('/advisories')) {
      final name = path.split('/')[path.split('/').length - 2];
      return _ok({'advisories': advisories[name] ?? <dynamic>[]});
    }
    // Checked before the `/versions/` branch: the per-version score endpoint
    // matches both.
    if (path.endsWith('/score')) {
      final segments = path.split('/');
      final name = segments[segments.indexOf('packages') + 1];
      final tags = path.contains('/versions/')
          ? versionTags['$name@${segments[segments.length - 2]}']
          : latestTags[name];
      return _ok({'tags': tags ?? <String>[]});
    }
    if (path.contains('/versions/')) {
      return _ok({
        'pubspec': {'dependencies': <String, dynamic>{}},
      });
    }
    final name = path.split('/').last;
    final version = latest[name];
    if (version == null) return http.Response('{}', 404);
    return _ok({
      'latest': {'version': version},
      'versions': [
        for (final v in published[name] ?? const <String>[])
          {'version': v, 'pubspec': <String, dynamic>{}},
      ],
    });
  });
  return PubApiClient(client: client);
}

http.Response _ok(Map<String, dynamic> body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );

void main() {
  group('PubspecAnalyzer', () {
    test('flags an outdated dependency when a lockfile is present', () async {
      final analyzer = _stubAnalyzer({'http': '1.3.0', 'test': '1.25.0'});
      final report = await analyzer.analyze(
        'p1',
        const FetchedPubspecs(
          pubspecYaml: _pubspecYaml,
          pubspecLock: _pubspecLock,
        ),
      );

      final http = report.nodes.firstWhere((n) => n.name == 'http');
      expect(http.installed, '1.2.0');
      expect(http.latest, '1.3.0');
      expect(http.status, DepStatus.outdated);
      expect(http.kind, DepKind.direct);

      final testDep = report.nodes.firstWhere((n) => n.name == 'test');
      expect(testDep.status, DepStatus.upToDate);
      expect(testDep.kind, DepKind.dev);

      expect(report.outdated, 1);
    });

    // Regression: Version.parse throws on non-semver input, and `installed` is
    // the sentinel "(unresolved)" when a repo doesn't commit its lockfile.
    // Parsing it directly threw a FormatException, so POST /projects returned
    // 500 for every such repo.
    test('handles a project with no pubspec.lock without throwing', () async {
      final analyzer = _stubAnalyzer({'http': '1.3.0', 'test': '1.25.0'});

      final report = await analyzer.analyze(
        'p2',
        const FetchedPubspecs(pubspecYaml: _pubspecYaml),
      );

      expect(report.nodes, hasLength(2));
      for (final node in report.nodes) {
        expect(node.installed, '(unresolved)');
        // Version is unknowable without a lock, so status must be unknown
        // rather than a bogus comparison.
        expect(node.status, DepStatus.unknown);
        expect(node.dependencies, isEmpty);
      }
      expect(report.outdated, 0);
      expect(report.vulnerable, 0);
    });

    // Regression: advisories were attached to a package wholesale, so any
    // package with any historical CVE was reported vulnerable forever, no
    // matter which version was installed.
    group('advisories', () {
      // "http before 0.13.3", as pub.dev publishes it: an explicit affected
      // version list plus the equivalent range.
      final httpAdvisory = {
        'id': 'GHSA-4rgh-jx4f-qfcq',
        'aliases': ['CVE-2020-35669'],
        'summary': 'http before 0.13.3 vulnerable to header injection',
        'severity': [
          {
            'type': 'CVSS_V3',
            'score': 'CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:C/C:L/I:L/A:N',
          },
        ],
        'database_specific': {'severity': 'MODERATE'},
        'affected': [
          {
            'package': {'name': 'http'},
            'versions': ['0.13.0', '0.13.1', '0.13.2'],
            'ranges': [
              {
                'type': 'ECOSYSTEM',
                'events': [
                  {'introduced': '0'},
                  {'fixed': '0.13.3'},
                ],
              },
            ],
          },
        ],
      };

      Future<DepNode> analyzeWith(String installed) async {
        final analyzer = _stubAnalyzer(
          {'http': '1.3.0', 'test': '1.25.0'},
          advisories: {
            'http': [httpAdvisory],
          },
        );
        final report = await analyzer.analyze(
          'p',
          FetchedPubspecs(
            pubspecYaml: _pubspecYaml,
            pubspecLock: 'packages:\n'
                '  http:\n'
                '    dependency: "direct main"\n'
                '    version: "$installed"\n',
          ),
        );
        return report.nodes.firstWhere((n) => n.name == 'http');
      }

      test('flags a version the advisory actually affects', () async {
        final node = await analyzeWith('0.13.0');
        expect(node.status, DepStatus.vulnerable);
        expect(node.advisories.single.id, 'GHSA-4rgh-jx4f-qfcq');
      });

      test('carries the detail needed to act on it', () async {
        final advisory = (await analyzeWith('0.13.0')).advisories.single;

        expect(advisory.aliases, ['CVE-2020-35669']);
        expect(advisory.summary, contains('header injection'));
        // The whole point: which version to move to.
        expect(advisory.fixedIn, '0.13.3');
      });

      test('scores severity from the published CVSS vector', () async {
        final advisory = (await analyzeWith('0.13.0')).advisories.single;

        expect(advisory.cvssScore, 6.1);
        expect(advisory.severity, AdvisorySeverity.medium);
        expect(advisory.cvssVector, startsWith('CVSS:3.1/'));
      });

      // Not every advisory publishes a vector, but GitHub always bands them.
      test('falls back to the database band when there is no vector', () async {
        final analyzer = _stubAnalyzer(
          {'http': '1.3.0', 'test': '1.25.0'},
          advisories: {
            'http': [
              {
                'id': 'GHSA-no-vector',
                'database_specific': {'severity': 'CRITICAL'},
                'affected': [
                  {
                    'package': {'name': 'http'},
                    'versions': ['0.13.0'],
                  },
                ],
              },
            ],
          },
        );

        final report = await analyzer.analyze(
          'p',
          const FetchedPubspecs(
            pubspecYaml: _pubspecYaml,
            pubspecLock: 'packages:\n'
                '  http:\n'
                '    dependency: "direct main"\n'
                '    version: "0.13.0"\n',
          ),
        );

        final advisory =
            report.nodes.firstWhere((n) => n.name == 'http').advisories.single;
        expect(advisory.severity, AdvisorySeverity.critical);
        expect(advisory.cvssScore, isNull);
      });

      // "We could not tell" must not read as "it is mild".
      test('reports unknown severity when the advisory bands it neither way',
          () async {
        final analyzer = _stubAnalyzer(
          {'http': '1.3.0', 'test': '1.25.0'},
          advisories: {
            'http': [
              {
                'id': 'GHSA-unscored',
                'affected': [
                  {
                    'package': {'name': 'http'},
                    'versions': ['0.13.0'],
                  },
                ],
              },
            ],
          },
        );

        final report = await analyzer.analyze(
          'p',
          const FetchedPubspecs(
            pubspecYaml: _pubspecYaml,
            pubspecLock: 'packages:\n'
                '  http:\n'
                '    dependency: "direct main"\n'
                '    version: "0.13.0"\n',
          ),
        );

        final advisory =
            report.nodes.firstWhere((n) => n.name == 'http').advisories.single;
        expect(advisory.severity, AdvisorySeverity.unknown);
      });

      test('does not flag a version fixed years ago', () async {
        final node = await analyzeWith('1.2.0');
        expect(node.advisories, isEmpty);
        expect(node.status, DepStatus.outdated);
      });

      test('does not flag the exact fixed version', () async {
        final node = await analyzeWith('0.13.3');
        expect(node.advisories, isEmpty);
        expect(node.status, DepStatus.outdated);
      });

      // pub.dev also publishes advisories that enumerate affected versions
      // without describing a range, so there is no `fixed` event to read. The
      // release history answers it instead.
      test('falls back to the release history for the fixing version',
          () async {
        final analyzer = _stubAnalyzer(
          {'http': '1.3.0', 'test': '1.25.0'},
          advisories: {
            'http': [
              {
                'id': 'GHSA-listed-only',
                'affected': [
                  {
                    'package': {'name': 'http'},
                    'versions': ['0.13.0', '0.13.1', '0.13.2'],
                  },
                ],
              },
            ],
          },
          published: {
            'http': ['0.13.0', '0.13.1', '0.13.2', '0.13.3', '1.0.0'],
          },
        );

        final report = await analyzer.analyze(
          'p',
          const FetchedPubspecs(
            pubspecYaml: _pubspecYaml,
            pubspecLock: 'packages:\n'
                '  http:\n'
                '    dependency: "direct main"\n'
                '    version: "0.13.0"\n',
          ),
        );

        final node = report.nodes.firstWhere((n) => n.name == 'http');
        // The lowest release above 0.13.0 that the advisory does not list.
        expect(node.advisories.single.fixedIn, '0.13.3');
      });

      // An open range means no fix has been published. Reporting the next
      // release as the fix would send someone to a version that is still
      // vulnerable.
      test('reports no fixing version when the advisory names none', () async {
        final analyzer = _stubAnalyzer(
          {'http': '1.3.0', 'test': '1.25.0'},
          advisories: {
            'http': [
              {
                'id': 'GHSA-unfixed',
                'affected': [
                  {
                    'package': {'name': 'http'},
                    'ranges': [
                      {
                        'type': 'ECOSYSTEM',
                        'events': [
                          {'introduced': '0'},
                        ],
                      },
                    ],
                  },
                ],
              },
            ],
          },
          published: {
            'http': ['0.13.0', '1.0.0']
          },
        );

        final report = await analyzer.analyze(
          'p',
          const FetchedPubspecs(
            pubspecYaml: _pubspecYaml,
            pubspecLock: 'packages:\n'
                '  http:\n'
                '    dependency: "direct main"\n'
                '    version: "0.13.0"\n',
          ),
        );

        final node = report.nodes.firstWhere((n) => n.name == 'http');
        expect(node.status, DepStatus.vulnerable);
        expect(node.advisories.single.fixedIn, isNull);
      });

      test('claims no advisories when the version is unknown', () async {
        final analyzer = _stubAnalyzer(
          {'http': '1.3.0', 'test': '1.25.0'},
          advisories: {
            'http': [httpAdvisory],
          },
        );
        // No lockfile, so nothing can be judged as affected.
        final report = await analyzer.analyze(
          'p',
          const FetchedPubspecs(pubspecYaml: _pubspecYaml),
        );
        final node = report.nodes.firstWhere((n) => n.name == 'http');
        expect(node.advisories, isEmpty);
        expect(node.status, DepStatus.unknown);
      });
    });

    group('licenses', () {
      Future<DepNode> analyzeWith({
        Map<String, List<String>> versionTags = const {},
        Map<String, List<String>> latestTags = const {},
      }) async {
        final analyzer = _stubAnalyzer(
          {'http': '1.3.0', 'test': '1.25.0'},
          versionTags: versionTags,
          latestTags: latestTags,
        );
        final report = await analyzer.analyze(
          'p',
          const FetchedPubspecs(
            pubspecYaml: _pubspecYaml,
            pubspecLock: _pubspecLock,
          ),
        );
        return report.nodes.firstWhere((n) => n.name == 'http');
      }

      test('reads the installed version\'s own analysis', () async {
        final node = await analyzeWith(
          versionTags: {
            'http@1.2.0': [
              'license:bsd-3-clause',
              'license:fsf-libre',
              'license:osi-approved',
              'sdk:dart',
            ],
          },
        );

        final license = node.license!;
        expect(license.spdxId, 'BSD-3-Clause');
        expect(license.category, LicenseCategory.permissive);
        expect(license.source, LicenseSource.installedVersion);
        expect(license.readFromVersion, '1.2.0');
        expect(license.osiApproved, isTrue);
        expect(license.fsfLibre, isTrue);
        // Read from the version in use, so there is nothing to qualify.
        expect(license.caveat, isNull);
      });

      // pub.dev keeps one analysis per version and drops the old ones, so a
      // project pinned to an old release has none. Falling back to the latest
      // release is right nearly always — and a relicensing is exactly what this
      // feature exists to catch, so the fallback is stated rather than hidden.
      test('falls back to the latest release, and says so', () async {
        final node = await analyzeWith(latestTags: {
          'http': ['license:mit', 'license:osi-approved'],
        });

        final license = node.license!;
        expect(license.spdxId, 'MIT');
        expect(license.source, LicenseSource.latestRelease);
        expect(license.readFromVersion, '1.3.0');
        expect(license.caveat, contains('1.3.0'));
        expect(license.isForInstalledVersion, isFalse);
      });

      // Regression: a version whose analysis pub.dev has dropped does not
      // answer with nothing. It answers with the tags that need no analysis —
      // `publisher:dart.dev`, `is:obsolete` — and no `license:` tag. Treating a
      // non-empty response as an answer meant the fallback never ran, and every
      // pinned dependency in a real project came back with no license at all.
      test('falls back when the version answers with tags but no license',
          () async {
        final node = await analyzeWith(
          versionTags: {
            'http@1.2.0': ['publisher:dart.dev', 'is:obsolete'],
          },
          latestTags: {
            'http': ['license:bsd-3-clause', 'license:osi-approved'],
          },
        );

        expect(node.license!.spdxId, 'BSD-3-Clause');
        expect(node.license!.source, LicenseSource.latestRelease);
      });

      test('prefers the installed version over the latest release', () async {
        final node = await analyzeWith(
          versionTags: {
            'http@1.2.0': ['license:gpl-3.0-only'],
          },
          latestTags: {
            'http': ['license:mit'],
          },
        );

        expect(node.license!.spdxId, 'GPL-3.0-only');
        expect(node.license!.category, LicenseCategory.strongCopyleft);
      });

      // pub.dev looked and could not identify one. That is a finding, and it
      // must not read the same as never having looked.
      test('records an unidentified license as a scanned result', () async {
        final node = await analyzeWith(
          versionTags: {
            'http@1.2.0': ['license:unknown'],
          },
        );

        expect(node.license, isNotNull);
        expect(node.license!.spdxId, isNull);
        expect(node.license!.category, LicenseCategory.unknown);
      });

      test('reports nothing published as undetermined, not as unlicensed',
          () async {
        final node = await analyzeWith();

        expect(node.license!.source, LicenseSource.undetermined);
        expect(node.license!.caveat, contains('publishes no license analysis'));
      });
    });

    // pub.dev serves packages under some of these names, and they are not the
    // same software: `flutter` there is a discontinued placeholder with a few
    // dozen downloads a month. Asking it about an SDK dependency returns that
    // package's license, version and advisories under the SDK's name.
    group('dependencies that do not come from pub.dev', () {
      const sdkPubspec = '''
name: demo
environment:
  sdk: ^3.6.0
dependencies:
  flutter:
    sdk: flutter
  shared:
    path: ../shared
  http: ^1.2.0
''';

      Future<DepReport> analyze({String? lock}) => _stubAnalyzer(
            {
              'http': '1.3.0',
              // What pub.dev would answer if it were asked.
              'flutter': '0.0.20',
              'shared': '9.9.9',
            },
            versionTags: {
              'flutter@0.0.0': ['license:bsd-3-clause'],
            },
            latestTags: {
              'flutter': ['license:bsd-3-clause'],
              'shared': ['license:mit'],
              'http': ['license:bsd-3-clause'],
            },
          ).analyze(
            'p',
            FetchedPubspecs(pubspecYaml: sdkPubspec, pubspecLock: lock),
          );

      test('are named as coming from somewhere else, not left unlicensed',
          () async {
        final report = await analyze();

        final flutter = report.nodes.firstWhere((n) => n.name == 'flutter');
        expect(flutter.license!.source, LicenseSource.notFromPubDev);
        expect(flutter.license!.origin, 'the SDK');
        expect(flutter.license!.caveat, contains('the SDK'));
        expect(flutter.license!.isPublished, isFalse);

        final shared = report.nodes.firstWhere((n) => n.name == 'shared');
        expect(shared.license!.origin, 'a path dependency');
      });

      // The bug this prevents: reporting a placeholder package's license,
      // latest version and advisories under the SDK's name.
      test('take nothing from the pub.dev package of the same name', () async {
        final report = await analyze();

        final flutter = report.nodes.firstWhere((n) => n.name == 'flutter');
        expect(flutter.license!.spdxId, isNull);
        expect(flutter.latest, isNull);
        expect(flutter.advisories, isEmpty);
        expect(flutter.status, DepStatus.unknown);
      });

      test('leaves the hosted dependencies alone', () async {
        final report = await analyze();

        final http = report.nodes.firstWhere((n) => n.name == 'http');
        expect(http.license!.spdxId, 'BSD-3-Clause');
        expect(http.latest, '1.3.0');
      });

      // Once resolution has happened the lockfile is the only place that still
      // records where a package came from.
      test('reads the origin from the lockfile when there is one', () async {
        final report = await analyze(
          lock: 'packages:\n'
              '  flutter:\n'
              '    dependency: "direct main"\n'
              '    description: flutter\n'
              '    source: sdk\n'
              '    version: "0.0.0"\n'
              '  http:\n'
              '    dependency: "direct main"\n'
              '    source: hosted\n'
              '    version: "1.2.0"\n',
        );

        final flutter = report.nodes.firstWhere((n) => n.name == 'flutter');
        expect(flutter.installed, '0.0.0');
        expect(flutter.license!.source, LicenseSource.notFromPubDev);
        expect(flutter.latest, isNull);

        final http = report.nodes.firstWhere((n) => n.name == 'http');
        expect(http.license!.spdxId, 'BSD-3-Clause');
      });
    });

    group('a repository holding several packages', () {
      /// A manifest declaring `analyzer` at [analyzerVersion].
      RepositoryManifest manifest(String directory, String analyzerVersion) =>
          RepositoryManifest(
            directory: directory,
            files: FetchedPubspecs(
              pubspecYaml: 'name: ${directory.isEmpty ? 'root' : directory}\n'
                  'environment:\n'
                  '  sdk: ^3.6.0\n'
                  'dependencies:\n'
                  '  analyzer: any\n',
              pubspecLock: 'packages:\n'
                  '  analyzer:\n'
                  '    dependency: "direct main"\n'
                  '    version: "$analyzerVersion"\n',
            ),
          );

      // The case the whole design turns on: a directory kept out of the pub
      // workspace resolves independently, so one repository holds two versions
      // of the same package. Collapsing them would mean assessing one version's
      // advisories against the other.
      test('keeps two versions of one package as two entries', () async {
        final analyzer = _stubAnalyzer({'analyzer': '12.1.0'});

        final report = await analyzer.analyzeRepository(
          'p',
          FetchedRepository(
            manifests: [
              manifest('', '12.1.0'),
              manifest('tools/api_differ', '7.7.1'),
            ],
          ),
        );

        final analyzers = report.nodes.where((n) => n.name == 'analyzer');
        expect(analyzers, hasLength(2));
        expect(
          analyzers.map((n) => n.installed),
          containsAll(['7.7.1', '12.1.0']),
        );
      });

      test('records which manifest each version came from', () async {
        final analyzer = _stubAnalyzer({'analyzer': '12.1.0'});

        final report = await analyzer.analyzeRepository(
          'p',
          FetchedRepository(
            manifests: [
              manifest('', '12.1.0'),
              manifest('tools/api_differ', '7.7.1'),
            ],
          ),
        );

        final old =
            report.nodes.firstWhere((n) => n.installed == '7.7.1');
        expect(old.manifests, ['tools/api_differ']);

        final current =
            report.nodes.firstWhere((n) => n.installed == '12.1.0');
        expect(current.manifests, ['repository root']);
      });

      test('merges a package resolved identically in both', () async {
        final analyzer = _stubAnalyzer({'analyzer': '12.1.0'});

        final report = await analyzer.analyzeRepository(
          'p',
          FetchedRepository(
            manifests: [
              manifest('', '12.1.0'),
              manifest('tools/api_differ', '12.1.0'),
            ],
          ),
        );

        final analyzers =
            report.nodes.where((n) => n.name == 'analyzer').toList();
        expect(analyzers, hasLength(1));
        // Counted once, but both origins are recorded.
        expect(analyzers.single.manifests, [
          'repository root',
          'tools/api_differ',
        ]);
      });

      test('lists the manifests it covered', () async {
        final analyzer = _stubAnalyzer({'analyzer': '12.1.0'});

        final report = await analyzer.analyzeRepository(
          'p',
          FetchedRepository(
            manifests: [manifest('', '12.1.0'), manifest('tools/x', '7.7.1')],
          ),
        );

        expect(report.manifests, ['repository root', 'tools/x']);
      });

      test('carries a partial-coverage note into the report', () async {
        final analyzer = _stubAnalyzer({'analyzer': '12.1.0'});

        final report = await analyzer.analyzeRepository(
          'p',
          FetchedRepository(
            manifests: [manifest('', '12.1.0')],
            discoveryNote: 'Could not list this repository.',
          ),
        );

        expect(report.coverageNote, 'Could not list this repository.');
      });

      // A single-package repository must not grow manifest noise it has no
      // use for.
      test('says nothing about manifests for a one-package repository',
          () async {
        final analyzer = _stubAnalyzer({'analyzer': '12.1.0'});

        final report = await analyzer.analyzeRepository(
          'p',
          FetchedRepository(manifests: [manifest('', '12.1.0')]),
        );

        expect(report.manifests, isEmpty);
        expect(report.nodes.single.manifests, isEmpty);
      });
    });

    group('what the source imports', () {
      const lockWithTransitive = '''
packages:
  http:
    dependency: "direct main"
    version: "1.2.0"
  test:
    dependency: "direct dev"
    version: "1.25.0"
  meta:
    dependency: transitive
    version: "1.16.0"
''';

      PubspecAnalyzer stub() => _stubAnalyzer({
            'http': '1.2.0',
            'test': '1.25.0',
            'meta': '1.16.0',
          });

      Future<DepReport> analyzeWith(Set<String>? imported) => stub().analyze(
            'p',
            const FetchedPubspecs(
              pubspecYaml: _pubspecYaml,
              pubspecLock: lockWithTransitive,
            ),
            imported: imported,
          );

      test('records a declared dependency the source uses', () async {
        final report = await analyzeWith({'http'});

        expect(report.nodes.firstWhere((n) => n.name == 'http').imported, true);
        expect(report.scannedImports, isTrue);
      });

      test('records a declared dependency nothing imports', () async {
        final report = await analyzeWith({'http'});

        final unused = report.unimportedDeclarations.map((n) => n.name);
        expect(unused, ['test']);
      });

      // The finding that costs someone a broken build later: it resolves today
      // only because http happens to bring meta along.
      test('flags a transitive package the source imports', () async {
        final report = await analyzeWith({'http', 'meta'});

        expect(report.undeclaredImports.map((n) => n.name), ['meta']);
        // And it is not also reported as an unused declaration.
        expect(report.unimportedDeclarations.map((n) => n.name), ['test']);
      });

      // Null is "nobody looked" and must not read as "nothing uses it", which
      // would accuse every dependency in the report at once.
      test('says nothing at all when no source was read', () async {
        final report = await analyzeWith(null);

        expect(report.nodes.every((n) => n.imported == null), isTrue);
        expect(report.scannedImports, isFalse);
        expect(report.unimportedDeclarations, isEmpty);
        expect(report.undeclaredImports, isEmpty);
      });

      test('one package importing it is enough for the repository', () async {
        final analyzer = stub();

        RepositoryManifest manifest(String directory, Set<String>? imported) =>
            RepositoryManifest(
              directory: directory,
              files: const FetchedPubspecs(
                pubspecYaml: _pubspecYaml,
                pubspecLock: _pubspecLock,
              ),
              importedPackages: imported,
            );

        final report = await analyzer.analyzeRepository(
          'p',
          FetchedRepository(
            manifests: [
              manifest('', const {}),
              manifest('tools/x', const {'http'}),
            ],
          ),
        );

        expect(report.nodes.firstWhere((n) => n.name == 'http').imported, true);
      });

      // A manifest whose source was never read contributes nothing rather than
      // a `false` that would outvote the manifest that did get scanned.
      test('an unscanned manifest does not vote', () async {
        final analyzer = stub();

        final report = await analyzer.analyzeRepository(
          'p',
          FetchedRepository(
            manifests: [
              RepositoryManifest(
                directory: '',
                files: const FetchedPubspecs(
                  pubspecYaml: _pubspecYaml,
                  pubspecLock: _pubspecLock,
                ),
                importedPackages: const {'http'},
              ),
              const RepositoryManifest(
                directory: 'tools/x',
                files: FetchedPubspecs(
                  pubspecYaml: _pubspecYaml,
                  pubspecLock: _pubspecLock,
                ),
              ),
            ],
          ),
        );

        expect(report.nodes.firstWhere((n) => n.name == 'http').imported, true);
      });
    });

    test('an unparseable locked version degrades to unknown', () async {
      final analyzer = _stubAnalyzer({'http': '1.3.0', 'test': '1.25.0'});

      final report = await analyzer.analyze(
        'p3',
        const FetchedPubspecs(
          pubspecYaml: _pubspecYaml,
          pubspecLock: '''
packages:
  http:
    dependency: "direct main"
    version: "not-a-version"
''',
        ),
      );

      final http = report.nodes.firstWhere((n) => n.name == 'http');
      expect(http.installed, 'not-a-version');
      expect(http.status, DepStatus.unknown);
    });
  });
}

PubspecAnalyzer _stubAnalyzer(
  Map<String, String> latest, {
  Map<String, List<Map<String, dynamic>>> advisories = const {},
  Map<String, List<String>> published = const {},
  Map<String, List<String>> versionTags = const {},
  Map<String, List<String>> latestTags = const {},
}) =>
    PubspecAnalyzer(
      _stubPub(
        latest,
        advisories: advisories,
        published: published,
        versionTags: versionTags,
        latestTags: latestTags,
      ),
    );
