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

/// Stubs the three pub.dev endpoints the analyzer touches, so the tests never
/// hit the network. `latest` is keyed by package name.
PubApiClient _stubPub(
  Map<String, String> latest, {
  Map<String, List<Map<String, dynamic>>> advisories = const {},
  Map<String, List<String>> published = const {},
}) {
  final client = MockClient((request) async {
    final path = request.url.path;

    if (path.endsWith('/advisories')) {
      final name = path.split('/')[path.split('/').length - 2];
      return _ok({'advisories': advisories[name] ?? <dynamic>[]});
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
}) =>
    PubspecAnalyzer(
      _stubPub(latest, advisories: advisories, published: published),
    );
