import 'package:shared/shared.dart';

import '../notifications/notifier.dart';
import '../repository/project_repository.dart';
import 'dependency_analyzer.dart';
import 'git_fetcher.dart';
import 'logger.dart';

/// What one project's re-scan came to.
class RescanResult {
  const RescanResult({
    required this.project,
    this.changed = false,
    this.revisionId,
    this.diff,
    this.notifications,
    this.error,
  });

  final Project project;

  /// Whether this scan found a state the project had not been in.
  final bool changed;

  /// The revision the report landed in — new when [changed], the existing one
  /// otherwise.
  final String? revisionId;

  /// What moved, when anything did and there was a previous revision to
  /// compare against.
  final ReportDiff? diff;

  final NotificationOutcome? notifications;

  /// Why this project could not be scanned, or null.
  ///
  /// One project failing is not the run failing: a repository can be deleted,
  /// renamed, or made private at any time, and a scheduled sweep that stops at
  /// the first of those stops working the first time anybody tidies up.
  final String? error;

  bool get failed => error != null;
}

/// Re-scans tracked projects, records what changed, and announces it.
///
/// The scheduled half of the registry. Adding a project answers "what does this
/// depend on today"; this answers "what changed since", which is the question
/// that has to be asked repeatedly and by something other than a person.
///
/// Deliberately a service rather than a timer. This deployment scales to zero
/// between requests, so an in-process schedule would fire only while somebody
/// happened to be using the app — which is precisely when they do not need to
/// be told. It is driven by `tool/rescan.dart` from an external scheduler
/// instead, the same way the API-diff backlog is drained.
class RescanService {
  RescanService({
    required ProjectRepository repository,
    required GitFetcher gitFetcher,
    required DependencyAnalyzer analyzer,
    required Notifier notifier,
  })  : _repository = repository,
        _gitFetcher = gitFetcher,
        _analyzer = analyzer,
        _notifier = notifier;

  final ProjectRepository _repository;
  final GitFetcher _gitFetcher;
  final DependencyAnalyzer _analyzer;
  final Notifier _notifier;

  static final _log = log.tagged('rescan');

  /// Re-scans every active project belonging to [ownerId].
  ///
  /// Archived projects are skipped, and not as an optimisation: an archived
  /// project is frozen, its re-analysis endpoint refuses with 409, and a
  /// background sweep that quietly re-fetched it would be doing the one thing
  /// archiving exists to stop.
  Future<List<RescanResult>> rescanOwner(
    String ownerId, {
    int? limit,
  }) async {
    final projects = await _repository.allForOwner(ownerId);
    final active = projects.where((p) => !p.isArchived).toList();
    final chosen = limit == null ? active : active.take(limit).toList();

    final results = <RescanResult>[];
    for (final project in chosen) {
      results.add(await rescan(project));
    }
    return results;
  }

  /// Re-scans one project.
  Future<RescanResult> rescan(Project project) async {
    if (project.isArchived) {
      return RescanResult(
        project: project,
        error: 'archived; a frozen snapshot is not re-fetched',
      );
    }

    // What the project looked like before this scan, read before anything is
    // written — once the new report is saved, the previous revision is no
    // longer the newest and there is nothing to diff against.
    final previous = await _repository.reportFor(project.id);

    final DepReport report;
    try {
      final repository =
          await _gitFetcher.fetchAll(project.gitUrl, ref: project.ref);
      report = await _analyzer.analyzeRepository(project.id, repository);
    } catch (e) {
      // Anything the fetch or the analysis can throw: a ref that is gone, a
      // repository that went private, a manifest that stopped parsing.
      _log.warn('Could not scan ${project.name}: $e');
      return RescanResult(project: project, error: '$e');
    }

    final saved = await _repository.saveReport(report);

    // The store says whether it wrote a revision. Not inferred from the
    // timestamps: two scans landing in the same instant look identical that
    // way, and the sweep would announce "nothing changed" as a change.
    if (!saved.isNewRevision) {
      return RescanResult(
        project: project,
        revisionId: saved.revision.id,
      );
    }

    if (previous == null) {
      // The first report a project has ever had. Everything in it is
      // technically new, and announcing a hundred packages as a hundred
      // additions is not news — it is the project.
      return RescanResult(
        project: project,
        changed: true,
        revisionId: saved.revision.id,
      );
    }

    final diff = ReportDiff.between(previous, report);
    final outcome = await _notifier.announce(
      project: project,
      diff: diff,
      revisionId: saved.revision.id,
    );

    return RescanResult(
      project: project,
      changed: true,
      revisionId: saved.revision.id,
      diff: diff,
      notifications: outcome,
    );
  }
}
