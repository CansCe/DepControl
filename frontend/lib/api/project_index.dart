import 'package:flutter/foundation.dart';
import 'package:shared/shared.dart';

import 'api_client.dart';

/// The registry, held once for whoever is drawing the sidebar.
///
/// The console shell puts the tracked projects down the left-hand edge of
/// *every* screen, which is a list the report screen and the settings screen
/// have no other reason to know. Without something like this each of them would
/// fetch it on mount, and moving between two projects would spend two round
/// trips redrawing a list that had not changed.
///
/// Deliberately a cache and not a source of truth. The registry screen still
/// owns its own fetch — it needs the archived set, error states and a spinner,
/// none of which belong in a sidebar — and simply [adopt]s the result on the
/// way past. Everything else reads whatever is here and asks for a load only if
/// nothing is.
class ProjectIndex extends ChangeNotifier {
  ProjectIndex();

  /// The app-wide instance. Screens take an injectable one in tests so a case
  /// does not inherit the list another case left behind.
  static final ProjectIndex instance = ProjectIndex();

  List<Project> _projects = const [];
  bool _loading = false;

  /// Active projects, in the order the server returned them.
  List<Project> get projects => _projects;

  /// True between asking and answering, so a cold sidebar can say so rather
  /// than claiming the registry is empty.
  bool get isLoading => _loading;

  /// True once a load has finished or a list has been adopted — which is what
  /// separates "no projects" from "not asked yet".
  bool get isLoaded => _loaded;
  bool _loaded = false;

  /// Takes a list somebody else already fetched.
  ///
  /// Only the active set: the sidebar lists what you are working on, and an
  /// archived project appearing there would undo the one thing archiving does.
  void adopt(List<Project> projects) {
    _loaded = true;
    if (listEquals(_projects, projects)) return;
    _projects = List.unmodifiable(projects);
    notifyListeners();
  }

  /// Loads once. Safe to call from every `initState` that wants a sidebar.
  Future<void> ensureLoaded(ApiClient api) async {
    if (_loaded || _loading) return;
    await refresh(api);
  }

  Future<void> refresh(ApiClient api) async {
    if (_loading) return;
    _loading = true;
    notifyListeners();
    try {
      final projects = await api.listProjects();
      _loaded = true;
      _projects = List.unmodifiable(projects);
    } on Object {
      // Swallowed on purpose. This is chrome: a sidebar that cannot load is a
      // sidebar with nothing in it, and the screen beside it is already going
      // to say what went wrong in the place the reader is looking.
      _loaded = true;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Drops a project the user just deleted, so the sidebar does not go on
  /// offering a link to a report the server no longer has.
  void forget(String projectId) {
    final next = [..._projects]..removeWhere((p) => p.id == projectId);
    if (next.length == _projects.length) return;
    _projects = List.unmodifiable(next);
    notifyListeners();
  }

  /// Test seam — the singleton outlives a `testWidgets` case otherwise.
  @visibleForTesting
  void reset() {
    _projects = const [];
    _loaded = false;
    _loading = false;
  }
}
