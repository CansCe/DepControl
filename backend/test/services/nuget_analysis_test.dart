import 'dart:convert';

import 'package:backend/src/ecosystem/ecosystems.dart';
import 'package:backend/src/services/dependency_analyzer.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

const _csproj = '''
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><TargetFramework>net48</TargetFramework></PropertyGroup>
  <ItemGroup>
    <PackageReference Include="NHibernate" />
    <PackageReference Include="StyleCop.Analyzers" PrivateAssets="all" />
  </ItemGroup>
</Project>
''';

const _props = '''
<Project>
  <ItemGroup>
    <PackageVersion Include="NHibernate" Version="5.2.7.4000" />
    <PackageVersion Include="StyleCop.Analyzers" Version="1.1.118" />
  </ItemGroup>
</Project>
''';

const _lock = '''
{
  "version": 1,
  "dependencies": {
    "net48": {
      "NHibernate": {"type": "Direct", "resolved": "5.2.7.4000"},
      "StyleCop.Analyzers": {"type": "Direct", "resolved": "1.1.118"}
    }
  }
}
''';

/// One registration leaf, as nuget.org inlines it in a page.
Map<String, Object?> _leaf(String version, {String? license}) => {
      'listed': true,
      'catalogEntry': {
        'version': version,
        if (license != null) 'licenseExpression': license,
      },
    };

void main() {
  DependencyAnalyzer analyzerFor({bool withAdvisory = true}) {
    final client = MockClient((request) async {
      if (request.url.host == 'osv.test') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final package = (body['package'] as Map)['name'];
        final ecosystem = (body['package'] as Map)['ecosystem'];
        if (!withAdvisory || package != 'NHibernate') {
          return http.Response('{"vulns":[]}', 200);
        }
        // Asserted here rather than in a separate test: querying OSV with the
        // wrong ecosystem name returns nothing at all, silently.
        expect(ecosystem, 'NuGet');
        return http.Response(
          jsonEncode({
            'vulns': [
              {
                'id': 'GHSA-test-nhib',
                'summary': 'Something in NHibernate',
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
                          {'introduced': '5.0.0'},
                          {'fixed': '5.3.0'},
                        ],
                      },
                    ],
                  },
                ],
              },
            ],
          }),
          200,
        );
      }

      final path = request.url.path;
      final registration = {
        '/v3/registration5-gz-semver2/nhibernate/index.json': {
          'items': [
            {
              'items': [
                _leaf('5.2.7.4000', license: 'LGPL-2.1-only'),
                _leaf('5.5.0', license: 'LGPL-2.1-only'),
              ],
            },
          ],
        },
        '/v3/registration5-gz-semver2/stylecop.analyzers/index.json': {
          'items': [
            {
              'items': [_leaf('1.1.118', license: 'MIT')],
            },
          ],
        },
      }[path];

      if (registration != null) {
        return http.Response(jsonEncode(registration), 200);
      }
      return http.Response('{}', 404);
    });

    return DependencyAnalyzer(
      Ecosystems(
        const [NuGetEcosystem()],
        registries: {
          'nuget': NuGetRegistry(
            client: client,
            baseUrl: 'https://nuget.test',
            osv: OsvClient(client: client, baseUrl: 'https://osv.test'),
          ),
        },
      ),
    );
  }

  Future<DepReport> analyze({bool withAdvisory = true}) =>
      analyzerFor(withAdvisory: withAdvisory).analyze(
        'p1',
        const ManifestFiles(
          manifest: _csproj,
          lock: _lock,
          companions: {'Directory.Packages.props': _props},
        ),
        ecosystem: 'nuget',
      );

  test('every node is attributed to NuGet', () async {
    final report = await analyze();

    expect(report.nodes, isNotEmpty);
    expect(report.nodes.every((n) => n.ecosystem == 'nuget'), isTrue);
  });

  test('a centrally managed project reports real versions', () async {
    // Without the companion props file every one of these is version-less, and
    // a version-less node cannot be compared, matched or scored.
    final report = await analyze();
    final nhibernate = report.nodes.firstWhere((n) => n.name == 'NHibernate');

    expect(nhibernate.installed, '5.2.7+4000');
    expect(nhibernate.constraint, '5.2.7.4000');
  });

  test('a four-part version is still compared against the latest', () async {
    final report = await analyze();
    final nhibernate = report.nodes.firstWhere((n) => n.name == 'NHibernate');

    expect(nhibernate.latest, '5.5.0');
    // Not asserted as `outdated` here: an advisory applies, and vulnerable
    // outranks it. The no-advisory case below is where the banding shows.
    expect(nhibernate.status, isNot(DepStatus.upToDate));
  });

  test('an advisory matches a four-part version', () async {
    // The failure this whole normalisation exists to prevent. Unnormalised,
    // `5.2.7.4000` parses as nothing, `Advisory.affects` is never consulted,
    // and the report says the project is clean.
    final report = await analyze();
    final nhibernate = report.nodes.firstWhere((n) => n.name == 'NHibernate');

    expect(nhibernate.status, DepStatus.vulnerable);
    expect(nhibernate.advisories.single.id, 'GHSA-test-nhib');
  });

  test('PrivateAssets="all" lands as a dev dependency', () async {
    final report = await analyze();
    final stylecop =
        report.nodes.firstWhere((n) => n.name == 'StyleCop.Analyzers');

    expect(stylecop.kind, DepKind.dev);
    expect(stylecop.license?.spdxId, 'MIT');
  });

  test('without an advisory the same package is merely outdated', () async {
    final report = await analyze(withAdvisory: false);
    final nhibernate = report.nodes.firstWhere((n) => n.name == 'NHibernate');

    expect(nhibernate.status, DepStatus.outdated);
    expect(nhibernate.advisories, isEmpty);
  });
}
