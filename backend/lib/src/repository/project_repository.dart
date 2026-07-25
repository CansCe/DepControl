import 'package:shared/shared.dart';

/// Persistence boundary. The scaffold uses an in-memory implementation;
/// Phase 3 swaps in [PostgresProjectRepository] behind the same interface.
abstract class ProjectRepository {
  Future<Project> add(Project project);
  Future<List<Project>> all();
  Future<Project?> byId(String id);
  Future<void> saveReport(DepReport report);
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
  Future<List<Project>> all() async => _projects.values.toList();

  @override
  Future<Project?> byId(String id) async => _projects[id];

  @override
  Future<void> saveReport(DepReport report) async {
    _reports[report.projectId] = report;
  }

  @override
  Future<DepReport?> reportFor(String projectId) async => _reports[projectId];
}
