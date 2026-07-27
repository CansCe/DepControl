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
  Future<List<Project>> allForOwner(String ownerId);

  /// The project with [id], but only if [ownerId] owns it; null otherwise.
  Future<Project?> byId(String id, {required String ownerId});

  Future<void> saveReport(DepReport report);

  /// The stored report for [projectId]. Callers must have already established
  /// ownership via [byId].
  Future<DepReport?> reportFor(String projectId);
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
  Future<List<Project>> allForOwner(String ownerId) async {
    final owned =
        _projects.values.where((p) => p.ownerId == ownerId).toList()
          ..sort((a, b) => (b.addedAt ?? DateTime(0))
              .compareTo(a.addedAt ?? DateTime(0)));
    return owned;
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
