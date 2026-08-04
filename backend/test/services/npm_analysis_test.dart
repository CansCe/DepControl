import 'dart:convert';

import 'package:backend/src/ecosystem/ecosystems.dart';
import 'package:backend/src/services/dependency_analyzer.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

/// An npm repository analysed end to end: `package.json` and
/// `package-lock.json` in, a [DepReport] out.
///
/// The pieces have their own tests. What this pins down is that they compose —
/// that the ecosystem seam actually carries a second ecosystem through
/// discovery, parsing, resolution, advisories and licences without the analyzer
/// knowing which one it is serving.
void main() {
  const packageJson = '''
{
  "name": "acme-app",
  "version": "1.0.0",
  "dependencies": { "lodash": "^4.17.0", "minimist": "^1.2.5" },
  "devDependencies": { "jest": "^29.0.0" }
}
''';

  const packageLock = '''
{
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "acme-app", "version": "1.0.0" },
    "node_modules/lodash": { "version": "4.17.21" },
    "node_modules/minimist": { "version": "1.2.5" },
    "node_modules/jest": { "version": "29.0.0" }
  }
}
''';

  /// The advisory OSV publishes for minimist 1.2.5, trimmed to the fields that
  /// matter here and in the shape OSV actually serves.
  const minimistAdvisory = {
    'id': 'GHSA-xvch-5gv4-984h',
    'aliases': ['CVE-2021-44906'],
    'summary': 'Prototype Pollution in minimist',
    'severity': [
      {
        'type': 'CVSS_V3',
        'score': 'CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H',
      },
    ],
    'affected': [
      {
        'ranges': [
          {
            'type': 'ECOSYSTEM',
            'events': [
              {'introduced': '0'},
              {'fixed': '1.2.6'},
            ],
          },
        ],
      },
    ],
  };

  DependencyAnalyzer analyzerFor({bool withAdvisory = true}) {
    final client = MockClient((request) async {
      final path = request.url.path;

      // OSV, which npm advisories come from.
      if (path == '/v1/query') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final name = (body['package'] as Map)['name'];
        final vulns =
            withAdvisory && name == 'minimist' ? [minimistAdvisory] : const [];
        return http.Response(jsonEncode({'vulns': vulns}), 200);
      }

      // A single version document, which is where the licence lives.
      final versionDoc = <String, Object>{
        '/lodash/4.17.21': {'license': 'MIT'},
        '/minimist/1.2.5': {'license': 'MIT'},
        '/jest/29.0.0': {'license': 'MIT'},
      }[path];
      if (versionDoc != null) {
        return http.Response(jsonEncode(versionDoc), 200);
      }

      // The packument.
      final packument = <String, Object>{
        '/lodash': {
          'dist-tags': {'latest': '4.17.21'},
          'versions': {
            '4.17.21': {'version': '4.17.21'},
          },
        },
        '/minimist': {
          'dist-tags': {'latest': '1.2.8'},
          'versions': {
            '1.2.5': {'version': '1.2.5'},
            '1.2.8': {'version': '1.2.8'},
          },
        },
        '/jest': {
          'dist-tags': {'latest': '29.0.0'},
          'versions': {
            '29.0.0': {'version': '29.0.0'},
          },
        },
      }[path];
      if (packument != null) {
        return http.Response(jsonEncode(packument), 200);
      }

      return http.Response('{}', 404);
    });

    return DependencyAnalyzer(
      Ecosystems(
        const [NpmEcosystem()],
        registries: {
          'npm': NpmRegistry(
            client: client,
            baseUrl: 'https://registry.test',
            osv: OsvClient(client: client, baseUrl: 'https://osv.test'),
          ),
        },
      ),
    );
  }

  Future<DepReport> analyze({bool withAdvisory = true}) =>
      analyzerFor(withAdvisory: withAdvisory).analyze(
        'p1',
        const ManifestFiles(manifest: packageJson, lock: packageLock),
        ecosystem: 'npm',
      );

  test('every node is attributed to npm', () async {
    final report = await analyze();

    expect(report.nodes, hasLength(3));
    expect(report.nodes.every((n) => n.ecosystem == 'npm'), isTrue);
    // The key carries it, so an npm `lodash` and a pub.dev one of the same
    // version would be two entries rather than one merged claim.
    expect(
      report.nodes.map((n) => n.key),
      containsAll(['npm:lodash@4.17.21', 'npm:minimist@1.2.5']),
    );
  });

  test('versions come from the lockfile, not from the constraint', () async {
    final report = await analyze();
    final lodash = report.nodes.firstWhere((n) => n.name == 'lodash');

    expect(lodash.installed, '4.17.21');
    expect(lodash.source, DepSource.lockfile);
    expect(lodash.constraint, '^4.17.0');
    expect(lodash.kind, DepKind.direct);
  });

  test('a dev dependency is marked as one', () async {
    final report = await analyze();
    expect(
      report.nodes.firstWhere((n) => n.name == 'jest').kind,
      DepKind.dev,
    );
  });

  test('an OSV advisory is matched, scored and given its fix', () async {
    final report = await analyze();
    final minimist = report.nodes.firstWhere((n) => n.name == 'minimist');

    expect(minimist.status, DepStatus.vulnerable);
    final advisory = minimist.advisories.single;
    expect(advisory.id, 'GHSA-xvch-5gv4-984h');
    expect(advisory.aliases, ['CVE-2021-44906']);
    // Scored from the published CVSS vector, the same as a pub.dev advisory —
    // the scoring never learns which ecosystem it is serving.
    expect(advisory.severity, AdvisorySeverity.critical);
    expect(advisory.cvssScore, 9.8);
    expect(advisory.fixedIn, '1.2.6');
  });

  test('a package with no advisory is not reported vulnerable', () async {
    final report = await analyze();
    final lodash = report.nodes.firstWhere((n) => n.name == 'lodash');

    expect(lodash.advisories, isEmpty);
    expect(lodash.status, DepStatus.upToDate);
  });

  test('being outdated is judged against the registry latest', () async {
    final report = await analyze(withAdvisory: false);
    final minimist = report.nodes.firstWhere((n) => n.name == 'minimist');

    expect(minimist.latest, '1.2.8');
    expect(minimist.status, DepStatus.outdated);
  });

  test('licences are read and classified', () async {
    final report = await analyze();
    final lodash = report.nodes.firstWhere((n) => n.name == 'lodash');

    expect(lodash.license?.spdxId, 'MIT');
    expect(lodash.license?.category, LicenseCategory.permissive);
    expect(lodash.license?.source, LicenseSource.installedVersion);
  });

  test('a report merges two ecosystems without confusing them', () async {
    // The case that made the ecosystem part of a node's identity: both
    // registries publish a package called `lodash`, and they are unrelated.
    final npmReport = await analyze();
    final dartNode = const DepNode(
      name: 'lodash',
      kind: DepKind.direct,
      installed: '4.17.21',
    );

    final merged = DepReport(
      projectId: 'p1',
      generatedAt: DateTime.utc(2026, 1, 1),
      nodes: [...npmReport.nodes, dartNode],
    );

    final lodashes = merged.nodes.where((n) => n.name == 'lodash');
    expect(lodashes, hasLength(2));
    expect(lodashes.map((n) => n.key).toSet(), hasLength(2));
  });
}
