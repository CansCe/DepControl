import 'package:shared/shared.dart';

import 'report_digest.dart';

/// Persistence boundary. The scaffold uses an in-memory implementation;
/// [PostgresProjectRepository] backs it with Supabase Postgres.
///
/// Every read is scoped by `ownerId` (the Supabase user's JWT `sub`) rather
/// than filtered by the caller, so a route cannot accidentally expose another
/// user's project. Lookups for a project owned by someone else return null,
/// which routes surface as 404 — a 403 would confirm the id exists.
abstract class ProjectRepository {
  Future<Project> add(Project project);

  /// Projects belonging to [ownerId], newest first.
  ///
  /// Archived projects are left out unless [includeArchived] — archiving is
  /// how someone says "not now", and the registry should honour that by
  /// default rather than making them filter every time.
  Future<List<Project>> allForOwner(
    String ownerId, {
    bool includeArchived = false,
  });

  /// The project with [id], but only if [ownerId] owns it; null otherwise.
  Future<Project?> byId(String id, {required String ownerId});

  /// Records [report] and returns the revision it belongs to.
  ///
  /// Appends a revision when the report says something different from the
  /// project's newest one, and otherwise marks that one seen again. Which of
  /// the two happened is decided by [reportDigest], not by whether a scan ran:
  /// a daily re-scan of a project nobody is touching finds the same thing every
  /// day, and writing that down each time would bury the changes.
  ///
  /// [commitSha] is the repository revision scanned, where the caller knows it.
  /// Passing it for a state already recorded fills the gap on the existing
  /// revision rather than creating a new one — learning the commit id of a
  /// state is not a change to that state.
  Future<ReportRevision> saveReport(DepReport report, {String? commitSha});

  /// The newest stored report for [projectId]. Callers must have already
  /// established ownership via [byId].
  Future<DepReport?> reportFor(String projectId);

  /// The project's revisions, newest first.
  ///
  /// Metadata only — a history is read as a list, and twenty revisions of a
  /// 400-package project is a great deal of JSON to send so a screen can print
  /// three numbers per row. Use [reportAt] for one revision's packages.
  Future<List<ReportRevision>> revisionsFor(
    String projectId, {
    int limit = 50,
  });

  /// The report stored as revision [revisionId], or null when that revision is
  /// not [projectId]'s.
  ///
  /// Takes both ids rather than the revision alone so a caller that has
  /// established ownership of the project has established it for the read; a
  /// revision id from another project is a 404 for the same reason a project id
  /// from another owner is.
  Future<DepReport?> reportAt(String projectId, String revisionId);

  /// Archives or restores [id], returning the updated project, or null when
  /// [ownerId] does not own it.
  Future<Project?> setArchived(
    String id, {
    required String ownerId,
    required bool archived,
  });

  /// Deletes [id] and its report, returning whether anything was deleted.
  ///
  /// Returns false rather than throwing for a project owned by someone else,
  /// so a caller cannot tell the two apart — the same reason [byId] returns
  /// null instead of a 403.
  Future<bool> delete(String id, {required String ownerId});
}

/// How many revisions a project keeps.
///
/// A project scanned daily changes far less often than it is scanned, so this
/// is a great many changes rather than a few weeks — but it is bounded, because
/// each revision holds a full node list and nothing prunes itself.
const maxRevisionsPerProject = 100;

class InMemoryProjectRepository implements ProjectRepository {
  final _projects = <String, Project>{};

  /// projectId -> revisions, newest first.
  final _revisions = <String, List<_StoredRevision>>{};

  var _nextRevision = 0;

  @override
  Future<Project> add(Project project) async {
    _projects[project.id] = project;
    return project;
  }

  @override
  Future<List<Project>> allForOwner(
    String ownerId, {
    bool includeArchived = false,
  }) async {
    final owned = _projects.values
        .where((p) => p.ownerId == ownerId)
        .where((p) => includeArchived || !p.isArchived)
        .toList()
      ..sort((a, b) =>
          (b.addedAt ?? DateTime(0)).compareTo(a.addedAt ?? DateTime(0)));
    return owned;
  }

  @override
  Future<Project?> setArchived(
    String id, {
    required String ownerId,
    required bool archived,
  }) async {
    final project = _projects[id];
    if (project == null || project.ownerId != ownerId) return null;

    final updated = archived
        ? project.copyWith(archivedAt: DateTime.now().toUtc())
        : project.copyWith(clearArchivedAt: true);
    _projects[id] = updated;
    return updated;
  }

  @override
  Future<bool> delete(String id, {required String ownerId}) async {
    final project = _projects[id];
    if (project == null || project.ownerId != ownerId) return false;
    _projects.remove(id);
    // Postgres does this through the foreign key's ON DELETE CASCADE.
    _revisions.remove(id);
    return true;
  }

  @override
  Future<Project?> byId(String id, {required String ownerId}) async {
    final project = _projects[id];
    if (project == null || project.ownerId != ownerId) return null;
    return project;
  }

  @override
  Future<ReportRevision> saveReport(
    DepReport report, {
    String? commitSha,
  }) async {
    final digest = reportDigest(report);
    final history = _revisions.putIfAbsent(report.projectId, () => []);

    // Only the newest revision, never the whole history. A project that goes
    // A -> B -> A has been in three states over time, and folding the second A
    // into the first would stretch that row's window across the period when B
    // held. Consecutive identical scans are noise; a revert is not.
    final newest = history.firstOrNull;

    if (newest != null && newest.summary.digest == digest) {
      final seen = ReportRevision(
        id: newest.summary.id,
        projectId: newest.summary.projectId,
        firstSeenAt: newest.summary.firstSeenAt,
        // Never moves backwards: scans can finish out of order, and a report
        // generated before the one already recorded says nothing newer.
        lastSeenAt: report.generatedAt.isAfter(newest.summary.lastSeenAt)
            ? report.generatedAt
            : newest.summary.lastSeenAt,
        digest: digest,
        // A commit id learned later fills the gap; one already recorded is not
        // overwritten, since the first sighting is where this state began.
        commitSha: newest.summary.commitSha ?? commitSha,
        total: newest.summary.total,
        outdated: newest.summary.outdated,
        vulnerable: newest.summary.vulnerable,
      );
      history[0] = _StoredRevision(summary: seen, report: newest.report);
      return seen;
    }

    final revision = ReportRevision(
      id: 'rev-${_nextRevision++}',
      projectId: report.projectId,
      firstSeenAt: report.generatedAt,
      lastSeenAt: report.generatedAt,
      digest: digest,
      commitSha: commitSha,
      total: report.total,
      outdated: report.outdated,
      vulnerable: report.vulnerable,
    );

    history.insert(0, _StoredRevision(summary: revision, report: report));
    if (history.length > maxRevisionsPerProject) {
      history.removeRange(maxRevisionsPerProject, history.length);
    }
    return revision;
  }

  @override
  Future<DepReport?> reportFor(String projectId) async =>
      _revisions[projectId]?.firstOrNull?.report;

  @override
  Future<List<ReportRevision>> revisionsFor(
    String projectId, {
    int limit = 50,
  }) async {
    final history = _revisions[projectId] ?? const <_StoredRevision>[];
    return [for (final entry in history.take(limit)) entry.summary];
  }

  @override
  Future<DepReport?> reportAt(String projectId, String revisionId) async =>
      (_revisions[projectId] ?? const <_StoredRevision>[])
          .where((r) => r.summary.id == revisionId)
          .firstOrNull
          ?.report;
}

/// A revision and the report it holds, kept together so the in-memory store
/// mirrors the single Postgres row rather than two collections that can drift.
class _StoredRevision {
  const _StoredRevision({required this.summary, required this.report});

  final ReportRevision summary;
  final DepReport report;
}
