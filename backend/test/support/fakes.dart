import 'package:backend/src/services/git_fetcher.dart';
import 'package:backend/src/services/pubspec_analyzer.dart';
import 'package:shared/shared.dart';

const samplePubspecYaml = '''
name: demo
environment:
  sdk: ^3.6.0
dependencies:
  http: ^1.2.0
''';

/// A [GitFetcher] that returns canned pubspec content instead of hitting the
/// network. Pass [onFetch] to simulate a failure or vary the response.
class FakeGitFetcher implements GitFetcher {
  FakeGitFetcher({
    this.onFetch,
    this.extraManifests = const [],
    this.importedPackages,
  });

  /// What the root manifest's source imports, or null for a scan that only read
  /// manifests.
  final Set<String>? importedPackages;

  /// Called in place of the real fetch. Receives the git URL and ref.
  final FetchedPubspecs Function(String gitUrl, String ref)? onFetch;

  /// Manifests discovery should find besides the root, for tests that exercise
  /// a repository holding more than one package.
  final List<RepositoryManifest> extraManifests;

  /// Every (gitUrl, ref) this fake was asked for, in order.
  final calls = <({String gitUrl, String ref})>[];

  @override
  Future<FetchedPubspecs> fetch(String gitUrl, {String ref = 'HEAD'}) async {
    calls.add((gitUrl: gitUrl, ref: ref));
    if (onFetch != null) return onFetch!(gitUrl, ref);
    return const FetchedPubspecs(pubspecYaml: samplePubspecYaml);
  }

  @override
  Future<FetchedRepository> fetchAll(
    String gitUrl, {
    String ref = 'HEAD',
  }) async =>
      FetchedRepository(
        manifests: [
          RepositoryManifest(
            directory: '',
            files: await fetch(gitUrl, ref: ref),
            importedPackages: importedPackages,
          ),
          ...extraManifests,
        ],
      );

  @override
  void close() {}
}

/// A [PubspecAnalyzer] that returns a fixed report without calling pub.dev.
class FakeAnalyzer implements PubspecAnalyzer {
  FakeAnalyzer({this.nodes = defaultNodes});

  static const defaultNodes = [
    DepNode(
      name: 'http',
      kind: DepKind.direct,
      installed: '1.2.0',
      constraint: '^1.0.0',
      latest: '1.3.0',
      status: DepStatus.outdated,
    ),
  ];

  final List<DepNode> nodes;

  @override
  Future<DepReport> analyze(
    String projectId,
    FetchedPubspecs files, {
    Set<String>? imported,
  }) async =>
      DepReport(
        projectId: projectId,
        generatedAt: DateTime.utc(2026, 1, 1),
        nodes: nodes,
      );

  @override
  Future<DepReport> analyzeRepository(
    String projectId,
    FetchedRepository repository,
  ) async {
    final report = await analyze(projectId, repository.primary.files);
    return DepReport(
      projectId: report.projectId,
      generatedAt: report.generatedAt,
      nodes: report.nodes,
      manifests: repository.manifests.length > 1
          ? repository.manifests.map((m) => m.label).toList()
          : const [],
      coverageNote: repository.discoveryNote,
    );
  }
}
