import 'package:shared/shared.dart';

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

  Future<void> saveReport(DepReport report);

  /// The stored report for [projectId]. Callers must have already established
  /// ownership via [byId].
  Future<DepReport?> reportFor(String projectId);

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

class InMemoryProjectRepository implements ProjectRepository {
  final _projects = <String, Project>{};
  final _reports = <String, DepReport>{};

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
    _reports.remove(id);
    return true;
  }

  @override
  Future<Project?> byId(String id, {required String ownerId}) async {
    final project = _projects[id];
    if (project == null || project.ownerId != ownerId) return null;
    return project;
  }

  @override
  Future<void> saveReport(DepReport report) async {
    _reports[report.projectId] = report;
  }

  @override
  Future<DepReport?> reportFor(String projectId) async => _reports[projectId];
}
