import 'repository/project_repository.dart';
import 'services/git_fetcher.dart';
import 'services/pub_api_client.dart';
import 'services/pubspec_analyzer.dart';
import 'services/resolver.dart';

/// Tiny process-wide service locator, provided into Dart Frog request context
/// by `routes/_middleware.dart`. Swap the repository here for Postgres in
/// Phase 3.
class Deps {
  Deps()
      : repository = InMemoryProjectRepository(),
        gitFetcher = GitFetcher(),
        pubApi = PubApiClient(),
        resolver = const Resolver() {
    analyzer = PubspecAnalyzer(pubApi);
  }

  final ProjectRepository repository;
  final GitFetcher gitFetcher;
  final PubApiClient pubApi;
  final Resolver resolver;
  late final PubspecAnalyzer analyzer;
}

/// Single shared instance for the scaffold (in-memory state must survive
/// across requests).
final deps = Deps();
