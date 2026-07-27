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
        expect(node.advisories, ['GHSA-4rgh-jx4f-qfcq']);
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
}) =>
    PubspecAnalyzer(_stubPub(latest, advisories: advisories));
