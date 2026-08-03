import 'package:flutter/material.dart';
import 'package:shared/shared.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
/// suits it — see [ConsoleFrame], which is what each screen uses to choose.
///
/// Mounted **above the Navigator**, not inside a screen. That is the whole
/// point of it: a rail whose job is to still be there while you move between
/// projects cannot be part of what moves. Built per-screen it was torn down and
/// rebuilt on every navigation — the sidebar re-fetched, the bar blinked, and
/// clicking a project in the rail read as a full page load rather than as
/// opening the next report. Above the Navigator only the content swaps.
class ConsoleShell extends StatefulWidget {
  const ConsoleShell({
    required this.router,
    required this.child,
    this.api,
    this.email,
    this.index,
    super.key,
  });

  /// Where the shell reads which entry is lit, and where its links go.
  ///
  /// Passed rather than looked up: this sits in `MaterialApp.builder`, whose
  /// context is *above* the Router, so `Router.of` would not find it.
  final AppRouterDelegate router;

  /// The Navigator.
  final Widget child;

  /// Fills the sidebar. Defaults to the router's own client.
  final ApiClient? api;

  /// The signed-in address, shown in the bar. Read from the session when null.
  final String? email;

  /// Where the sidebar's list comes from. Defaults to the app-wide index;
  /// injectable so a test does not inherit another case's registry.
  final ProjectIndex? index;

  @override
  State<ConsoleShell> createState() => _ConsoleShellState();
}

class _ConsoleShellState extends State<ConsoleShell> {
  ProjectIndex get _index => widget.index ?? ProjectIndex.instance;
  ApiClient get _api => widget.api ?? widget.router.api;

  @override
  void initState() {
    super.initState();
    _index.addListener(_onChanged);
    widget.router.addListener(_onChanged);
    // Runs once for the session now that the shell outlives navigation. Costs
    // nothing when the registry screen has already handed its fetch over, and
    // covers arriving straight at a report from a bookmark.
    _index.ensureLoaded(_api);
  }

  @override
  void didUpdateWidget(ConsoleShell old) {
    super.didUpdateWidget(old);
    if (identical(old.router, widget.router)) return;
    old.router.removeListener(_onChanged);
    widget.router.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.router.removeListener(_onChanged);
    _index.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// Which rail entry the current route lights.
  ConsoleNav get _active => switch (widget.router.currentConfiguration) {
        RegistryRoute(:final archived) =>
          archived ? ConsoleNav.archived : ConsoleNav.projects,
        SettingsRoute() => ConsoleNav.settings,
        // A report is a project, and projects are what the registry lists.
        ReportRoute() => ConsoleNav.projects,
      };

  /// Which tracked project is open, so its row reads as the current one rather
  /// than as another link.
  String? get _selectedProjectId =>
      switch (widget.router.currentConfiguration) {
        ReportRoute(:final projectId) => projectId,
        _ => null,
      };

  /// The signed-in address, or null where there is no Supabase to ask.
  String? get _email {
    if (widget.email != null) return widget.email;
    try {
      return Supabase.instance.client.auth.currentUser?.email;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);
    // Just over the console threshold the rail keeps its icons and drops its
    // words: 240 pixels of labels is a fifth of a 1150-pixel window, and the
    // content is what people came for.
    final collapsed = MediaQuery.sizeOf(context).width < 1280;

    // An Overlay of the shell's own, and it is not optional.
    //
    // The only Overlay in the app belongs to the Navigator, and the Navigator
    // arrives here as [widget.child] — *below* this widget. So everything the
    // shell draws around it (the rail, the bar, the search field) is mounted
    // above the one thing a tooltip, a popup menu or a snackbar needs, and
    // asking for any of them throws `No Overlay widget found`.
    //
    // That is the cost of the arrangement in `main.dart`, which mounts this
    // above the Navigator on purpose so the chrome survives the navigation it
    // drives. The chrome keeps that, and gets somewhere to put a tooltip.
    //
    // Worth knowing how this failed, because the symptom named neither cause:
    // current Flutter resolves the Overlay while *building* a tooltip rather
    // than when showing one, so the first frame threw and the subtree never
    // laid out — which surfaced in a release build as `RenderBox was not laid
    // out` against a minified frame, pointing nowhere near a tooltip.
    return Overlay(
      initialEntries: [
        OverlayEntry(
          builder: (context) => Scaffold(
            backgroundColor: surfaces.page,
            body: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Sidebar(
                  collapsed: collapsed,
                  active: _active,
                  projects: _index.projects,
                  loading: _index.isLoading && !_index.isLoaded,
                  selectedProjectId: _selectedProjectId,
                  onGo: widget.router.go,
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _TopBar(email: _email),
                      Expanded(child: widget.child),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Picks which of its two layouts a screen shows.
///
/// One place decides what a wide window means, so a screen says "here is my
/// console body and here is my narrow one" rather than each of them
/// re-deriving it. The compact build is handed straight through untouched — it
/// is not a narrower console, it is the layout this app already had.
///
/// The console body is *bare*: no Scaffold, no rail, no bar. Those come from
/// [ConsoleShell], which is mounted once above the Navigator.
class ConsoleFrame extends StatelessWidget {
  const ConsoleFrame({
    required this.console,
    required this.compact,
    super.key,
  });

  /// The body to lay inside the shell's content column.
  final Widget console;

  /// The whole screen, Scaffold and all, for a narrow window.
  final Widget compact;

  /// Whether [context] is wide enough for the console.
  static bool isConsole(BuildContext context) => Layout.of(context).isConsole;

  @override
  Widget build(BuildContext context) =>
      isConsole(context) ? console : compact;
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
