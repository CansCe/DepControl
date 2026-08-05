import 'dart:convert';

import 'package:backend/src/ecosystem/ecosystems.dart';
import 'package:backend/src/services/bundle_ingest.dart';
import 'package:backend/src/services/dependency_analyzer.dart';
import 'package:backend/src/services/git_fetcher.dart';
import 'package:backend/src/services/pub_api_client.dart';
import 'package:collector/collector.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

import '../support/temp_repository.dart';

/// A pub.dev and OSV that answer for the two packages the fixture declares.
///
/// Both paths under test go through exactly this, which is the point: if the
/// bundle path asked the registry different questions, the reports would differ
/// for a reason that had nothing to do with how the repository was read.
DependencyAnalyzer _analyzer() {
  final client = MockClient((request) async {
    if (request.url.host == 'osv.test') {
      return http.Response('{"vulns":[]}', 200);
    }

    final versions = {
      'http': ['1.2.0', '1.2.2', '1.3.0'],
      'meta': ['1.15.0', '1.16.0'],
    }[request.url.pathSegments.last];

    if (versions == null) return http.Response('{}', 404);
    return http.Response(
      jsonEncode({
        'name': request.url.pathSegments.last,
        'latest': {'version': versions.last},
        'versions': [
          for (final version in versions)
            {
              'version': version,
              'pubspec': {'name': request.url.pathSegments.last},
            },
        ],
      }),
      200,
    );
  });

  return DependencyAnalyzer(
    Ecosystems(
      const [DartEcosystem()],
      registries: {
        'dart': DartRegistry(
          PubApiClient(client: client, baseUrl: 'https://pub.test'),
          osv: OsvClient(client: client, baseUrl: 'https://osv.test'),
        ),
      },
    ),
  );
}

const _pubspec = '''
name: payroll_app
environment:
  sdk: ^3.6.0
dependencies:
  http: ^1.2.0
''';

const _lock = '''
packages:
  http:
    dependency: "direct main"
    source: hosted
    version: "1.2.2"
  meta:
    dependency: transitive
    source: hosted
    version: "1.15.0"
''';

void main() {
  test('a bundle and a fetched repository give the same report', () async {
    // The proof that 1.5a's seam did not quietly change the analysis. One
    // repository, read two ways: once as files the server fetched, once as a
    // bundle the collector produced on the machine that holds it.
    final root = tempRepository({
      'pubspec.yaml': _pubspec,
      'pubspec.lock': _lock,
      'lib/main.dart': "import 'package:http/http.dart';\n",
    });

    final fromFiles = await _analyzer().analyzeRepository(
      'p1',
      FetchedRepository(
        manifests: [
          RepositoryManifest(
            directory: '',
            files: const ManifestFiles(manifest: _pubspec, lock: _lock),
            importedPackages: const {'http'},
          ),
        ],
      ),
    );

    final bundle = Collector(root: root, warn: (_) {}).collect();
    final fromBundle = await _analyzer().analyzeAll(
      'p1',
      BundleIngest.read(bundle),
      coverageNote: bundle.coverageNote,
    );

    expect(_shape(fromBundle), _shape(fromFiles));
  });

  test('a bundle produces the same digest, so it makes one revision', () async {
    // The consequence that matters operationally: uploading a bundle for a
    // repository the server had been fetching does not read as every package
    // having changed.
    final root = tempRepository({
      'pubspec.yaml': _pubspec,
      'pubspec.lock': _lock,
    });

    final bundle = Collector(root: root, warn: (_) {}).collect();
    final first = await _analyzer().analyzeAll('p1', BundleIngest.read(bundle));
    final second = await _analyzer().analyzeAll('p1', BundleIngest.read(bundle));

    expect(_shape(first), _shape(second));
  });

  group('BundleIngest.validate', () {
    final ecosystems = Ecosystems.standard();

    CollectedBundle bundleWith(List<CollectedManifest> manifests) =>
        CollectedBundle(generatedAt: DateTime.utc(2026), manifests: manifests);

    CollectedManifest manifest({int packages = 1, String ecosystem = 'dart'}) =>
        CollectedManifest(
          directory: 'p$packages',
          ecosystem: ecosystem,
          dependencies: [
            for (var i = 0; i < packages; i++)
              CollectedDependency(name: 'p$i', constraint: '^1.0.0'),
          ],
        );

    test('a bundle with no manifests is refused', () {
      expect(
        () => BundleIngest.validate(bundleWith(const []), ecosystems: ecosystems),
        throwsFormatException,
      );
    });

    test('more manifests than a fetched repository would get', () {
      // The bundle path must not be the way to ask for a report the git path
      // would have refused.
      expect(
        () => BundleIngest.validate(
          bundleWith([
            for (var i = 0; i <= BundleIngest.maxManifests; i++) manifest(),
          ]),
          ecosystems: ecosystems,
        ),
        throwsFormatException,
      );
    });

    test('more packages than the analyzer will look up', () {
      expect(
        () => BundleIngest.validate(
          bundleWith([manifest(packages: BundleIngest.maxPackages + 1)]),
          ecosystems: ecosystems,
        ),
        throwsFormatException,
      );
    });

    test('an ecosystem this server does not scan', () {
      expect(
        () => BundleIngest.validate(
          bundleWith([manifest(ecosystem: 'cargo')]),
          ecosystems: ecosystems,
        ),
        throwsFormatException,
      );
    });

    test('a bundle from a newer collector than this server reads', () {
      expect(
        () => BundleIngest.validate(
          CollectedBundle(
            schema: CollectedBundle.currentSchema + 1,
            generatedAt: DateTime.utc(2026),
            manifests: [manifest()],
          ),
          ecosystems: ecosystems,
        ),
        throwsFormatException,
      );
    });

    test('an ordinary bundle passes', () {
      expect(
        () => BundleIngest.validate(
          bundleWith([manifest()]),
          ecosystems: ecosystems,
        ),
        returnsNormally,
      );
    });
  });

  group('manifest labels', () {
    test('a redacted bundle is labelled positionally, and says so', () {
      // Redaction applied with the label missing is the half-implemented failure
      // worth catching: the report would render an opaque id where a name goes
      // and claim to be naming something.
      final root = tempRepository({
        'pubspec.yaml': _pubspec,
        'services/payroll/pubspec.yaml': 'name: payroll\n',
      });

      final bundle =
          Collector(root: root, redactPaths: true, warn: (_) {}).collect();
      final labels = [for (final m in BundleIngest.read(bundle)) m.label];

      expect(labels, ['manifest 1 of 2', 'manifest 2 of 2']);
      expect(labels.any((l) => l.contains('payroll')), isFalse);
    });

    test('an unredacted bundle names manifests as the archive path does', () {
      // Matching `_fetchFromArchive`, which carries the file name for every
      // ecosystem — not `RepositoryManifest`'s doc comment, which says it is
      // dropped where the name is fixed. The archive path is what nearly every
      // report was actually built by, and `report.manifests` is inside
      // `reportDigest`: a bundle that labelled the same repository differently
      // would file a revision saying its manifests changed when only the way it
      // was read did.
      final root = tempRepository({
        'pubspec.yaml': _pubspec,
        'services/payroll/pubspec.yaml': 'name: payroll\n',
      });

      final bundle = Collector(root: root, warn: (_) {}).collect();
      final labels = [for (final m in BundleIngest.read(bundle)) m.label];

      expect(labels, ['pubspec.yaml', 'services/payroll/pubspec.yaml']);
    });

    test('two ecosystems in one directory are told apart', () {
      final root = tempRepository({
        'pubspec.yaml': _pubspec,
        'package.json': '{"name":"web","dependencies":{}}',
      });

      final bundle = Collector(root: root, warn: (_) {}).collect();
      final labels = [for (final m in BundleIngest.read(bundle)) m.label];

      // Distinct file names already tell these apart, so no `(dart)` /`(npm)`
      // qualifier is needed — the qualifier exists for the case where two
      // manifests would otherwise print the same label.
      expect(labels, ['pubspec.yaml', 'package.json']);
    });

    test('same-named manifests in one directory are qualified', () {
      // Reachable when a bundle states no file name — an older collector, or a
      // hand-written one. Both would be "the root" and a merged report naming
      // one origin for two dependency trees is unreadable.
      final bundle = CollectedBundle(
        generatedAt: DateTime.utc(2026),
        manifests: const [
          CollectedManifest(directory: '', ecosystem: 'dart'),
          CollectedManifest(directory: '', ecosystem: 'npm'),
        ],
      );

      expect(
        [for (final m in BundleIngest.read(bundle)) m.label],
        ['repository root (dart)', 'repository root (npm)'],
      );
    });
  });
}

/// What a report says, minus when it was generated.
///
/// `generatedAt` is `DateTime.now()` by construction and differs between two
/// runs of anything, so comparing it would fail for a reason that has nothing to
/// do with what the two paths read.
Map<String, Object?> _shape(DepReport report) => {
      'manifests': report.manifests,
      'coverage': report.coverageNote,
      'nodes': [
        for (final node in report.nodes)
          {
            'key': node.key,
            'kind': node.kind.name,
            'constraint': node.constraint,
            'latest': node.latest,
            'status': node.status.name,
            'source': node.source.name,
            'imported': node.imported,
            'dependencies': node.dependencies,
          },
      ],
    };
