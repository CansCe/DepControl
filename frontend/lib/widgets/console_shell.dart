import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import '../api/api_client.dart';
import '../api/project_index.dart';
import '../platform/breakpoints.dart';
import '../routing/app_route.dart';
import '../routing/app_router.dart';
import '../theme.dart';

/// Which sidebar entry is lit.
enum ConsoleNav { projects, archived, settings }

/// The frame the wide browser build draws every screen inside.
///
/// A fixed rail on the left and a fixed bar on top, with the screen in the
/// remaining column. That arrangement is the entire reason this exists: on a
/// desktop monitor the app is not a sequence of pages you walk back out of, it
/// is one surface with the registry permanently in view, and moving between two
/// projects should be one click from wherever you are rather than back-then-in.
///
/// Only the wide build. A phone has no room for a 240-pixel rail that is not
/// the content, and the compact layout keeps the stack-of-screens shape that
/// suits it — see [ConsoleFrame], which is what actually decides.
class ConsoleShell extends StatefulWidget {
  const ConsoleShell({
    required this.api,
    required this.active,
    required this.child,
    this.selectedProjectId,
    this.email,
    this.index,
    super.key,
  });

  final ApiClient api;

  /// Which entry is lit.
  final ConsoleNav active;

  /// The screen.
  final Widget child;

  /// Which tracked project is open, if any, so its row reads as the current
  /// one and not merely as another link.
  final String? selectedProjectId;

  /// The signed-in address, shown in the bar. Null where there is no session to
  /// ask — a widget test, mostly.
  final String? email;

  /// Where the sidebar's list comes from. Defaults to the app-wide index;
  /// injectable so a test does not inherit another case's registry.
  final ProjectIndex? index;

  @override
  State<ConsoleShell> createState() => _ConsoleShellState();
}

class _ConsoleShellState extends State<ConsoleShell> {
  ProjectIndex get _index => widget.index ?? ProjectIndex.instance;

  @override
  void initState() {
    super.initState();
    _index.addListener(_onIndexChanged);
    // Costs nothing when the registry screen has already handed its fetch over,
    // which is the common path — this covers arriving straight at a report from
    // a bookmark, where nothing else would have asked.
    _index.ensureLoaded(widget.api);
  }

  @override
  void dispose() {
    _index.removeListener(_onIndexChanged);
    super.dispose();
  }

  void _onIndexChanged() {
    if (mounted) setState(() {});
  }

  /// Navigates the way the rest of the app does.
  ///
  /// Through the delegate's own `go` rather than `setNewRoutePath`: the latter
  /// is the entry point for a URL arriving from outside and rebuilds the whole
  /// stack, so using it here would make every rail click behave like a cold
  /// load — including throwing away the report underneath.
  void _go(AppRoute route) {
    final delegate = Router.of(context).routerDelegate;
    if (delegate is AppRouterDelegate) {
      delegate.go(route);
    } else {
      delegate.setNewRoutePath(route);
    }
  }

  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);
    // Just over the console threshold the rail keeps its icons and drops its
    // words: 240 pixels of labels is a fifth of a 1150-pixel window, and the
    // content is what people came for.
    final collapsed = MediaQuery.sizeOf(context).width < 1280;

    return Scaffold(
      backgroundColor: surfaces.page,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Sidebar(
            collapsed: collapsed,
            active: widget.active,
            projects: _index.projects,
            loading: _index.isLoading && !_index.isLoaded,
            selectedProjectId: widget.selectedProjectId,
            onGo: _go,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TopBar(email: widget.email),
                Expanded(child: widget.child),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Picks the skin.
///
/// One place decides, so a screen says "wrap me in the console if this is a
/// console" rather than each of them re-deriving what a wide window means. The
/// compact build is handed straight through untouched — it is not a narrower
/// console, it is the layout this app already had.
class ConsoleFrame extends StatelessWidget {
  const ConsoleFrame({
    required this.api,
    required this.active,
    required this.console,
    required this.compact,
    this.selectedProjectId,
    this.email,
    this.index,
    super.key,
  });

  final ApiClient api;
  final ConsoleNav active;

  /// The body to put inside the rail and the bar.
  final Widget console;

  /// The whole screen, Scaffold and all, for a narrow window.
  final Widget compact;

  final String? selectedProjectId;
  final String? email;
  final ProjectIndex? index;

  /// Whether [context] is wide enough for the console.
  static bool isConsole(BuildContext context) => Layout.of(context).isConsole;

  @override
  Widget build(BuildContext context) {
    if (!isConsole(context)) return compact;
    return ConsoleShell(
      api: api,
      active: active,
      selectedProjectId: selectedProjectId,
      email: email,
      index: index,
      child: console,
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.collapsed,
    required this.active,
    required this.projects,
    required this.loading,
    required this.selectedProjectId,
    required this.onGo,
  });

  final bool collapsed;
  final ConsoleNav active;
  final List<Project> projects;
  final bool loading;
  final String? selectedProjectId;
  final void Function(AppRoute) onGo;

  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);
    final theme = Theme.of(context);

    return Container(
      width: collapsed ? 72 : 240,
      decoration: BoxDecoration(
        color: surfaces.isDark ? Console.sidebar : surfaces.card,
        border: Border(right: BorderSide(color: surfaces.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Brand(collapsed: collapsed),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                _NavItem(
                  icon: Icons.folder_outlined,
                  label: 'Projects',
                  collapsed: collapsed,
                  selected: active == ConsoleNav.projects,
                  onTap: () => onGo(const AppRoute.registry()),
                ),
                _NavItem(
                  icon: Icons.settings_outlined,
                  label: 'Settings',
                  collapsed: collapsed,
                  selected: active == ConsoleNav.settings,
                  onTap: () => onGo(const AppRoute.settings()),
                ),
                if (!collapsed) ...[
                  const SizedBox(height: 18),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      'TRACKED PROJECTS',
                      style: monoOf(
                        context,
                        theme.textTheme.labelSmall,
                        color: surfaces.muted,
                      ).copyWith(letterSpacing: 0.8, fontSize: 10),
                    ),
                  ),
                ] else
                  const SizedBox(height: 12),
                if (loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Center(
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                else
                  for (final project in projects)
                    _ProjectRow(
                      project: project,
                      collapsed: collapsed,
                      selected: project.id == selectedProjectId,
                      onTap: () => onGo(AppRoute.report(project.id)),
                    ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Divider(color: surfaces.hairline, height: 17),
                _NavItem(
                  icon: Icons.inventory_2_outlined,
                  label: 'Archived',
                  collapsed: collapsed,
                  selected: active == ConsoleNav.archived,
                  onTap: () => onGo(const AppRoute.registry(archived: true)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({required this.collapsed});

  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);
    final theme = Theme.of(context);

    if (collapsed) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(0, 22, 0, 22),
        child: Center(
          child: Text(
            'DC',
            style: displayOf(
              context,
              theme.textTheme.titleMedium,
              color: surfaces.accent,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'DepControl',
            style: displayOf(
              context,
              theme.textTheme.titleLarge,
              color: surfaces.accent,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'Dependency console',
            style: theme.textTheme.bodySmall?.copyWith(color: surfaces.muted),
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.collapsed,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool collapsed;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);
    final theme = Theme.of(context);
    final tint = selected ? surfaces.accent : surfaces.muted;

    final row = Row(
      mainAxisAlignment:
          collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: tint),
        if (!collapsed) ...[
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: tint,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected ? surfaces.wash(surfaces.accent) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: collapsed ? 8 : 16,
              vertical: 12,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected
                    ? surfaces.accent.withValues(alpha: 0.24)
                    : Colors.transparent,
              ),
            ),
            child: collapsed ? Tooltip(message: label, child: row) : row,
          ),
        ),
      ),
    );
  }
}

/// One tracked project in the rail.
class _ProjectRow extends StatelessWidget {
  const _ProjectRow({
    required this.project,
    required this.collapsed,
    required this.selected,
    required this.onTap,
  });

  final Project project;
  final bool collapsed;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);
    final theme = Theme.of(context);

    final dot = Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        color: selected ? surfaces.accent : surfaces.faint,
        shape: BoxShape.circle,
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected
            ? surfaces.text.withValues(alpha: 0.04)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Tooltip(
            message: collapsed ? project.name : '',
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: collapsed ? 8 : 16,
                vertical: 8,
              ),
              child: collapsed
                  ? Center(child: dot)
                  : Row(
                      children: [
                        dot,
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            project.name,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color:
                                  selected ? surfaces.text : surfaces.muted,
                              fontWeight:
                                  selected ? FontWeight.w600 : FontWeight.w400,
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The bar across the top of the content column.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.email});

  final String? email;

  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);
    final theme = Theme.of(context);

    return Container(
      height: 64,
      decoration: BoxDecoration(
        color: surfaces.isDark ? Console.abyss : surfaces.card,
        border: Border(bottom: BorderSide(color: surfaces.hairline)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Row(
        children: [
          const SizedBox(width: 280, child: _SearchField()),
          const Spacer(),
          if (email != null) ...[
            Text(
              email!,
              style: monoOf(
                context,
                theme.textTheme.bodySmall,
                color: surfaces.muted,
              ),
            ),
            const SizedBox(width: 12),
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: surfaces.isDark ? Console.chip : surfaces.inset,
                shape: BoxShape.circle,
                border: Border.all(color: surfaces.hairline),
              ),
              child: Text(
                email!.characters.first.toUpperCase(),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: surfaces.accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The registry search field.
///
/// Renders and does nothing yet, which is a deliberate half-step rather than an
/// oversight: the bar is part of the shape of the redesign, and searching
/// across projects wants to reach package names too — a server question this
/// build has no endpoint for. Disabled rather than merely inert, so it declines
/// the caret instead of silently eating what someone types into it.
class _SearchField extends StatelessWidget {
  const _SearchField();

  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);
    final theme = Theme.of(context);

    return Tooltip(
      message: 'Search is not wired up yet',
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: surfaces.isDark ? surfaces.page : surfaces.inset,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: surfaces.hairline),
        ),
        child: Row(
          children: [
            Icon(Icons.search, size: 17, color: surfaces.faint),
            const SizedBox(width: 9),
            Text(
              'Search registry…',
              style: theme.textTheme.bodySmall?.copyWith(color: surfaces.faint),
            ),
          ],
        ),
      ),
    );
  }
}

/// The bounded column the console's screens lay their content out in.
class ConsolePage extends StatelessWidget {
  const ConsolePage({
    required this.child,
    this.max = 1200,
    this.padding = const EdgeInsets.fromLTRB(40, 36, 40, 64),
    super.key,
  });

  final Widget child;
  final double max;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        padding: padding,
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: max),
            child: SizedBox(width: double.infinity, child: child),
          ),
        ),
      );
}
