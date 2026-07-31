import 'package:flutter/material.dart';
import 'package:shared/shared.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../api/api_client.dart';
import '../auth/session_monitor.dart';
import '../platform/breakpoints.dart';
import '../routing/app_route.dart';
import '../routing/app_router.dart';
import '../scans/scan_queue.dart';
import '../theme.dart';
import 'app_header.dart';
import 'project_rail.dart';

/// The page furniture every route is drawn inside.
///
/// Wraps the **Navigator**, not each screen, and that placement is the whole
/// design. Put inside the pages instead, the rail would be rebuilt and its
/// project list re-fetched on every navigation — so switching projects would
/// flash the list it is meant to keep still, which is precisely the phone
/// behaviour this replaces. Above the Navigator it is built once, and only the
/// content area swaps.
///
/// One layout that adapts rather than two that drift. Above
/// [Layout.medium] the rail is on screen; below it the same widget is what the
/// drawer holds, so there is one project list and it cannot disagree with
/// itself.
class AppShell extends StatefulWidget {
  const AppShell({
    required this.child,
    required this.router,
    this.api,
    this.scans,
    super.key,
  });

  final Widget child;

  /// Handed in rather than looked up.
  ///
  /// `MaterialApp.builder` wraps the Router from *outside*, so
  /// `Router.of(context)` finds nothing here — the lookup that works inside a
  /// page returns null in the shell, and every click on the rail would go
  /// quietly nowhere. Passing it makes the dependency explicit and impossible
  /// to get wrong.
  final AppRouterDelegate router;

  /// Defaults to the app-wide instances; injectable for tests.
  final ApiClient? api;
  final ScanQueue? scans;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final ApiClient _api = widget.api ?? ApiClient();
  ScanQueue get _scans => widget.scans ?? ScanQueue.instance;

  final _drawerKey = GlobalKey<ScaffoldState>();

  List<Project> _projects = const [];
  String? _error;
  bool _loading = true;

  AppRouterDelegate get _router => widget.router;

  @override
  void initState() {
    super.initState();
    _load();
    _scans.addListener(_onScansChanged);
    _router.addListener(_onRouteChanged);
  }

  @override
  void dispose() {
    _router.removeListener(_onRouteChanged);
    _scans.removeListener(_onScansChanged);
    super.dispose();
  }

  void _onRouteChanged() {
    if (mounted) setState(() {});
  }

  /// A finished scan can add a project or change one's name, and the rail is
  /// the one place that shows every project at once.
  int _seenCompletions = 0;
  void _onScansChanged() {
    if (!mounted || _scans.completions == _seenCompletions) return;
    _seenCompletions = _scans.completions;
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      // Both views at once. The rail shows archived projects under their own
      // heading rather than behind a toggle: on a phone the toggle bought back
      // a whole screen, and here it would hide four rows in a column that has
      // room for thirty.
      final active = await _api.listProjects();
      final archived = await _api.listProjects(archived: true);
      if (!mounted) return;
      setState(() {
        _projects = [...active, ...archived];
        _error = null;
        _loading = false;
        _seenCompletions = _scans.completions;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e is ApiAuthException) {
        SessionMonitor.instance.reportExpired(e.message);
      }
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  String? get _email {
    try {
      return Supabase.instance.client.auth.currentUser?.email;
    } catch (_) {
      // No Supabase in this build — a test, or a widget preview.
      return null;
    }
  }

  /// The project whose report is open, if one is.
  String? get _selectedId => switch (_router.currentConfiguration) {
        ReportRoute(:final projectId) => projectId,
        _ => null,
      };

  void _select(Project project) {
    _drawerKey.currentState?.closeDrawer();
    _router.openReport(project);
  }

  void _add() {
    _drawerKey.currentState?.closeDrawer();
    _router.go(const AppRoute.registry());
  }

  @override
  Widget build(BuildContext context) {
    final wide = Layout.of(context).isWide;

    final rail = ProjectRail(
      projects: _projects,
      selectedId: _selectedId,
      onSelect: _select,
      onAdd: _add,
      error: _error,
      loading: _loading,
    );

    // Nothing here uses `Tooltip`, and that is a constraint of the placement
    // rather than an oversight. This sits *above* the app's Navigator — which
    // is what keeps the rail from rebuilding on every route change — and the
    // Navigator's Overlay is therefore below it rather than around it. A
    // tooltip has nowhere to float and throws "No Overlay widget found",
    // taking the page with it. Two icon buttons are not worth standing up a
    // second Overlay for; they get a pointer cursor and a label instead.
    return Scaffold(
      key: _drawerKey,
      backgroundColor: Palette.mist,
      drawer: wide ? null : Drawer(width: ProjectRail.width, child: rail),
      body: Column(
        children: [
          AppHeader(
            current: _router.currentConfiguration,
            onNavigate: _router.go,
            email: _email,
            // Only where the rail is not already on screen; a button that
            // reveals something visible is a button that does nothing.
            onMenu: wide ? null : () => _drawerKey.currentState?.openDrawer(),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (wide) ...[
                  rail,
                  const VerticalDivider(width: 0.5, thickness: 0.5),
                ],
                Expanded(child: widget.child),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
