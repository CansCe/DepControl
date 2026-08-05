import 'package:backend/src/ecosystem/ecosystems.dart';
import 'package:backend/src/services/git_fetcher.dart';
import 'package:backend/src/services/dependency_analyzer.dart';
import 'package:backend/src/services/scan_progress_store.dart';
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
  final ManifestFiles Function(String gitUrl, String ref)? onFetch;

  /// Manifests discovery should find besides the root, for tests that exercise
  /// a repository holding more than one package.
  final List<RepositoryManifest> extraManifests;

  /// Every (gitUrl, ref) this fake was asked for, in order.
  final calls = <({String gitUrl, String ref})>[];

  @override
  Future<ManifestFiles> fetch(
    String gitUrl, {
    String ref = 'HEAD',
    ManifestNaming? naming,
  }) async {
    calls.add((gitUrl: gitUrl, ref: ref));
    if (onFetch != null) return onFetch!(gitUrl, ref);
    return const ManifestFiles(manifest: samplePubspecYaml);
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

/// A [DependencyAnalyzer] that returns a fixed report without calling pub.dev.
class FakeAnalyzer implements DependencyAnalyzer {
  FakeAnalyzer({this.nodes = defaultNodes});

  /// Advances on every report, because a real analyzer stamps `DateTime.now()`
  /// and successive scans are therefore ordered. A fixed timestamp makes every
  /// revision a tie, which is a situation production never reaches and which
  /// tests should not be quietly exercising instead.
  static var _tick = 0;

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
    ManifestFiles files, {
    String ecosystem = DepNode.defaultEcosystem,
    Set<String>? imported,
    ScanProgressSink progress = ScanProgressSink.none,
  }) async =>
      DepReport(
        projectId: projectId,
        generatedAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: _tick++)),
        nodes: nodes,
      );

  @override
  Future<DepReport> analyzeAll(
    String projectId,
    List<AnalyzableManifest> manifests, {
    String? coverageNote,
    ScanProgressSink progress = ScanProgressSink.none,
  }) async =>
      DepReport(
        projectId: projectId,
        generatedAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: _tick++)),
        nodes: nodes,
        coverageNote: coverageNote,
      );

  /// Re-reads nothing, and says so by handing the report straight back.
  ///
  /// A fake that produced *different* nodes here would make the local sweep look
  /// like it had found a change on every pass, which is the one behaviour the
  /// digest exists to prevent and the one a test must not accidentally assert.
  @override
  Future<DepReport> refreshMetadata(
    DepReport report, {
    ScanProgressSink progress = ScanProgressSink.none,
  }) async =>
      report;

  @override
  Future<DepReport> analyzeParsed(
    String projectId,
    ParsedManifest parsed, {
    String ecosystem = DepNode.defaultEcosystem,
    Set<String>? imported,
    ScanProgressSink progress = ScanProgressSink.none,
  }) async =>
      DepReport(
        projectId: projectId,
        generatedAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: _tick++)),
        nodes: nodes,
      );

  @override
  Future<DepReport> analyzeRepository(
    String projectId,
    FetchedRepository repository, {
    ScanProgressSink progress = ScanProgressSink.none,
  }) async {
    // Reported so route tests can assert what a client watching would have
    // seen, without a real analysis behind it.
    progress
      ..manifestsTotal(repository.manifests.length)
      ..phase(ScanPhase.analyzing)
      ..manifestStarted(nodes.length);
    for (var i = 0; i < nodes.length; i++) {
      progress.packageDone();
    }
    final report = await analyze(projectId, repository.primary.files);
    return DepReport(
      projectId: report.projectId,
      generatedAt: report.generatedAt,
      nodes: report.nodes,
      manifests: repository.manifests.length > 1
          ? [for (final m in repository.manifests) repository.labelOf(m)]
          : const [],
      coverageNote: repository.discoveryNote,
    );
  }
}
