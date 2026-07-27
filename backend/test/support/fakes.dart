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
  FakeGitFetcher({this.onFetch});

  /// Called in place of the real fetch. Receives the git URL and ref.
  final FetchedPubspecs Function(String gitUrl, String ref)? onFetch;

  /// Every (gitUrl, ref) this fake was asked for, in order.
  final calls = <({String gitUrl, String ref})>[];

  @override
  Future<FetchedPubspecs> fetch(String gitUrl, {String ref = 'HEAD'}) async {
    calls.add((gitUrl: gitUrl, ref: ref));
    if (onFetch != null) return onFetch!(gitUrl, ref);
    return const FetchedPubspecs(pubspecYaml: samplePubspecYaml);
  }

  @override
  Future<FetchedPubspecs> fetchViaGitArchive(String gitUrl, String ref) =>
      fetch(gitUrl, ref: ref);

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
  Future<DepReport> analyze(String projectId, FetchedPubspecs files) async =>
      DepReport(
        projectId: projectId,
        generatedAt: DateTime.utc(2026, 1, 1),
        nodes: nodes,
      );
}
