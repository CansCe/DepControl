import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import '../api/api_client.dart';
import '../main.dart';
import '../screens/report_screen.dart';
import '../screens/settings_screen.dart';
import 'app_route.dart';

/// Turns the browser's address bar into an [AppRoute] and back.
///
/// The `RouteInformation` half of Navigator 2.0, which is the only part of it
/// that has to exist for a URL to mean anything.
class AppRouteParser extends RouteInformationParser<AppRoute> {
  const AppRouteParser();

  @override
  Future<AppRoute> parseRouteInformation(
    RouteInformation routeInformation,
  ) async =>
      AppRoute.parse(routeInformation.uri.toString());

  @override
  RouteInformation restoreRouteInformation(AppRoute configuration) =>
      RouteInformation(uri: Uri.parse(configuration.location));
}

/// The app's navigation state: a stack of [AppRoute]s the browser can see.
///
/// Replaces `Navigator.push` with something the address bar participates in.
/// The old arrangement put every screen behind `home:`, which on the web meant
/// three things that all read as bugs: a report could not be linked to, a
/// refresh threw you back to the registry with no way to say where you had
/// been, and the browser's back button either did nothing or left the app.
///
/// The stack is kept rather than only the top route, so that arriving at
/// `/projects/<id>` from a bookmark and *navigating* there from the registry
/// end up in the same place — with the registry underneath either way, which is
/// what makes back go somewhere sensible on a cold load.
class AppRouterDelegate extends RouterDelegate<AppRoute>
    with ChangeNotifier, PopNavigatorRouterDelegateMixin<AppRoute> {
  AppRouterDelegate({required this.api});

  final ApiClient api;

  @override
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  /// Bottom to top. Never empty: the registry is always underneath.
  final List<AppRoute> _stack = [const AppRoute.registry()];

  List<AppRoute> get stack => List.unmodifiable(_stack);

  @override
  AppRoute get currentConfiguration => _stack.last;

  /// Projects already loaded, by id, so navigating from a row does not re-fetch
  /// what the row already had. A deep link finds nothing here and loads.
  final _known = <String, Project>{};

  /// Remembers [project] so a push to its report renders immediately.
  void remember(Project project) => _known[project.id] = project;

  void go(AppRoute route) {
    if (_stack.last == route) return;
    // The registry is the floor rather than another entry: going home from a
    // report should leave one screen, not two.
    if (route is RegistryRoute) {
      _stack
        ..clear()
        ..add(route);
    } else {
      _stack.add(route);
    }
    notifyListeners();
  }

  /// Swaps the top route rather than stacking on it.
  ///
  /// What tab switching and project switching both want. Pushing instead would
  /// make the back button walk every tab somebody glanced at, and four clicks
  /// around a report would take four presses to leave.
  void replaceTop(AppRoute route) {
    if (_stack.last == route) return;
    _stack[_stack.length - 1] = route;
    notifyListeners();
  }

  /// Opens [project]'s report, replacing any report already open.
  ///
  /// Replacing rather than pushing because the rail makes projects *siblings*:
  /// clicking three projects in a row is browsing, not descending, and back
  /// should return to wherever the browsing started.
  void openReport(Project project) {
    remember(project);
    final route = AppRoute.report(project.id);
    if (_stack.last is ReportRoute) {
      replaceTop(route);
    } else {
      go(route);
    }
  }

  /// Shows a different panel of the report already open.
  void showTab(ReportTab tab) {
    if (_stack.last case final ReportRoute open) {
      replaceTop(AppRoute.report(open.projectId, tab: tab));
    }
  }

  bool pop() {
    if (_stack.length <= 1) return false;
    _stack.removeLast();
    notifyListeners();
    return true;
  }

  /// Where a fresh URL comes in — a bookmark, a pasted link, the back button
  /// landing on a route this session never pushed.
  @override
  Future<void> setNewRoutePath(AppRoute route) async {
    _stack
      ..clear()
      ..add(const AppRoute.registry());
    if (route is! RegistryRoute) _stack.add(route);
    notifyListeners();
  }

  @override
  Widget build(BuildContext context) {
    return Navigator(
      key: navigatorKey,
      pages: [
        for (final route in _stack) _pageFor(route),
      ],
      onDidRemovePage: (page) {
        // Flutter has already taken this page off; the stack has to agree, and
        // must not pop something else because the two drifted.
        final route = (page.key as ValueKey<String>?)?.value;
        if (route == null) return;
        _stack.removeWhere((r) => r.location == route);
        if (_stack.isEmpty) _stack.add(const AppRoute.registry());
        notifyListeners();
      },
    );
  }

  Page<void> _pageFor(AppRoute route) => switch (route) {
        RegistryRoute() => MaterialPage(
            key: ValueKey(route.location),
            child: RegistryScreen(api: api),
          ),
        SettingsRoute() => MaterialPage(
            key: ValueKey(route.location),
            child: const SettingsScreen(),
          ),
        ReportRoute(:final projectId, :final tab) => MaterialPage(
            // Keyed by the project, *not* by the location — the location
            // carries the tab, and keying on it would tear the page down and
            // re-fetch the report every time somebody looked at another panel.
            key: ValueKey('/projects/$projectId'),
            // Known when a row was tapped; unknown on a deep link, which is the
            // only case that costs a round trip.
            child: switch (_known[projectId]) {
              final project? =>
                ReportScreen(project: project, api: api, tab: tab),
              null => ReportLoader(projectId: projectId, api: api, tab: tab),
            },
          ),
      };
}

/// Fetches a project that was arrived at by URL rather than by tapping a row.
///
/// A deep link carries an id and nothing else, so there is a round trip before
/// there is a screen. That round trip is the only thing this exists for, and it
/// is deliberately not folded into [ReportScreen]: that screen is handed a
/// project everywhere else, and making its `project` nullable would push this
/// one case into every line that reads it.
class ReportLoader extends StatefulWidget {
  const ReportLoader({
    required this.projectId,
    required this.api,
    this.tab = ReportTab.packages,
    super.key,
  });

  final String projectId;
  final ApiClient api;
  final ReportTab tab;

  @override
  State<ReportLoader> createState() => _ReportLoaderState();
}

class _ReportLoaderState extends State<ReportLoader> {
  late Future<({Project project, DepReport? report})> _loading =
      widget.api.projectWithReport(widget.projectId);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<({Project project, DepReport? report})>(
      future: _loading,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (snap.hasError) {
          final error = snap.error;
          return Scaffold(
            appBar: AppBar(),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      // A project owned by somebody else answers 404 exactly as
                      // a made-up id does, and this says the same thing for
                      // both — the distinction is the point of the 404.
                      error is ApiException
                          ? error.message
                          : 'That project could not be opened.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => setState(() {
                        _loading =
                            widget.api.projectWithReport(widget.projectId);
                      }),
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        return ReportScreen(
          project: snap.data!.project,
          api: widget.api,
          tab: widget.tab,
        );
      },
    );
  }
}
