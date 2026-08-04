import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared/shared.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'api/api_client.dart';
import 'api/api_config.dart';
import 'api/project_index.dart';
import 'auth/auth_gate.dart';
import 'auth/session_monitor.dart';
import 'platform/app_surface.dart';
import 'platform/breakpoints.dart';
import 'routing/app_route.dart';
import 'routing/app_router.dart';
import 'scans/scan_overlay.dart';
import 'scans/scan_queue.dart';
import 'screens/registry_console.dart';
import 'security/pin_gate.dart';
import 'security/pin_prompt.dart';
import 'security/web_session_timeout.dart';
import 'theme.dart';
import 'widgets/chrome.dart';
import 'widgets/console_shell.dart';
import 'widgets/project_card.dart';

/// Shorthand for the Supabase client once [main] has initialized it.
SupabaseClient get supabase => Supabase.instance.client;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _goFullscreen();
  // Before the first client is built, so a device pointed at a different
  // backend does not spend one launch talking to the compiled-in default.
  await ApiConfig.instance.load();
  await Supabase.initialize(
    url: 'https://ogsnkqlamfvftdgvvtje.supabase.co',
    // Publishable key — public by design; safe in client code.
    // Never place the service_role/secret key here. Requires RLS on all tables.
    publishableKey: 'sb_publishable_1hxQQb522Ukayaq9TzPvpg_oiu7KkK6',
  );
  runApp(const DepControlApp());
}

/// Hands the whole screen to the app on Android and iOS.
///
/// `immersiveSticky` rather than `edgeToEdge`: the ask is for the phone's
/// navigation bar to *go away*, not to be drawn behind. Sticky is the variant
/// that puts it back on a swipe from the edge and then hides it again on its
/// own — the bar stays reachable without permanently taking a strip of a screen
/// that is mostly a long scrolling table.
///
/// Skipped on web and desktop, where there are no system bars to hide and the
/// call is a no-op that would only be misleading to read here.
void _goFullscreen() {
  if (kIsWeb) return;
  if (defaultTargetPlatform != TargetPlatform.android &&
      defaultTargetPlatform != TargetPlatform.iOS) {
    return;
  }
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  // While the bars are briefly on show, they have to be legible against the
  // ink band the app opens every screen with.
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: Palette.ink,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
}

class DepControlApp extends StatefulWidget {
  const DepControlApp({super.key});

  @override
  State<DepControlApp> createState() => _DepControlAppState();
}

class _DepControlAppState extends State<DepControlApp> {
  // Held rather than rebuilt: the delegate *is* the navigation state, and a
  // fresh one every build would put the app back on the registry on any
  // rebuild of the root.
  late final AppRouterDelegate _delegate = AppRouterDelegate(api: ApiClient());
  final _parser = const AppRouteParser();

  // Built once each. They are pure functions of nothing, and rebuilding a
  // ThemeData on every frame of a window resize is exactly the wrong time to
  // be doing it.
  late final ThemeData _paper = buildTheme();
  late final ThemeData _console = buildConsoleTheme();

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'DepControl',
      theme: _paper,
      routerDelegate: _delegate,
      routeInformationParser: _parser,
      // Everything that has to outlive a route change wraps the Navigator
      // rather than sitting inside a screen, where the very navigation it
      // exists to survive would dispose it.
      //
      // Order is deliberate. The auth gate is outermost because a URL is not a
      // way past it: opening /projects/<id> while signed out shows sign-in, and
      // the router keeps the route so the report is what appears afterwards.
      // The session timeout and the PIN sit inside it because both act on a
      // session that already exists — there is nothing to lock, and nothing to
      // time out, when nobody is signed in.
      //
      // The skin is chosen here rather than passed to `theme:` because it is a
      // width question, and width is not known until there is a MediaQuery —
      // which MaterialApp inserts above this builder and not above itself. A
      // wide browser window gets the dark console; anything narrower, including
      // every phone, keeps the light layout this app already had.
      //
      // The console shell wraps the Navigator for the same reason everything
      // else here does: the rail and the bar have to survive the navigation
      // they drive. Inside a screen they were rebuilt on every route change,
      // which made opening a project from the rail look like a page reload.
      // It sits inside the auth gate, so the sign-in screen is not framed by a
      // sidebar belonging to nobody.
      builder: (context, child) {
        final console = Layout.of(context).isConsole;
        final content = child ?? const SizedBox();

        return Theme(
          data: console ? _console : _paper,
          child: ScanOverlay(
            child: AuthGate(
              child: WebSessionTimeout(
                child: PinGate(
                  child: console
                      ? ConsoleShell(router: _delegate, child: content)
                      : content,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Reaches the router from anywhere below it.
///
/// A plain lookup rather than an inherited widget: the delegate is created once
/// in [_DepControlAppState] and never swapped, so there is nothing for
/// dependents to be notified about.
AppRouterDelegate routerOf(BuildContext context) =>
    (Router.of(context).routerDelegate as AppRouterDelegate);

/// Phase 3 entry point: the multi-project registry + an "add by git URL" form.
class RegistryScreen extends StatefulWidget {
  const RegistryScreen({
    this.api,
    this.scans,
    this.index,
    this.archived = false,
    super.key,
  });

  /// All three default to the app-wide instances. Injectable so the screen can
  /// be tested without standing up Supabase and without one test's scans
  /// leaking into the next.
  final ApiClient? api;
  final ScanQueue? scans;
  final ProjectIndex? index;

  /// Which half of the registry the route asked for.
  final bool archived;

  @override
  State<RegistryScreen> createState() => _RegistryScreenState();
}

class _RegistryScreenState extends State<RegistryScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();
  final _urlController = TextEditingController();
  late Future<List<Project>> _projects;

  ProjectIndex get _index => widget.index ?? ProjectIndex.instance;

  /// Archived projects are a separate view: putting one out of the way should
  /// take it out of the way. Seeded from the route, which is what makes the
  /// console sidebar's Archived entry reachable from any screen.
  late bool _showArchived = widget.archived;
  String? _error;

  /// How many active projects there are, once a load has said so.
  int? _trackedCount;

  ScanQueue get _scans => widget.scans ?? ScanQueue.instance;

  /// The value of [ScanQueue.completions] this list is up to date with.
  ///
  /// Compared rather than reacting to an event, because the list has to be
  /// right whenever this screen is on show — including after a scan that
  /// finished while it was being rebuilt, or before it existed at all. An event
  /// only reaches whoever happened to be listening; a number says whether
  /// anything was missed.
  late int _seenCompletions = _scans.completions;

  @override
  void initState() {
    super.initState();
    _projects = _fetch();
    _scans.addListener(_onScansChanged);
    // Scans run on the server and outlive this app, so opening it may be
    // walking in on work already in progress — started before the tab was
    // closed, or on another device. Without asking, the panel would be empty
    // and the obvious next move would be to start the same scan again.
    unawaited(_scans.reattach(_api));
  }

  /// Follows the route. The console sidebar links to `/` and `/archived`, and
  /// both land on this same screen — so a filter change arrives as a new
  /// `archived` rather than as a call to anything here.
  @override
  void didUpdateWidget(RegistryScreen old) {
    super.didUpdateWidget(old);
    if (old.archived == widget.archived) return;
    _showArchived = widget.archived;
    _reload();
  }

  /// Asks for the current half, and hands the active one to the sidebar.
  ///
  /// Only the active set is adopted: the rail lists what you are working on,
  /// and an archived project appearing there would undo the one thing
  /// archiving does.
  Future<List<Project>> _fetch() {
    final archived = _showArchived;
    final pending = _api.listProjects(archived: archived);
    pending.then((projects) {
      if (!mounted || archived != _showArchived) return;
      if (!archived) {
        _index.adopt(projects);
        setState(() => _trackedCount = projects.length);
      }
    }).catchError((Object _) {
      // The list below already renders the failure; this only exists to stop
      // an unhandled rejection, and the sidebar simply keeps what it had.
    });
    return pending;
  }

  /// Watches the router so returning here re-decides the PIN offer.
  ///
  /// This used to be the tail of `await Navigator.push(settings)` — settings
  /// closed, and the line after it bumped the revision. With the address bar
  /// participating there is no such line: the browser's back button reaches
  /// this screen without anything here having pushed anything. Listening
  /// catches that route too, which the old arrangement never did.
  AppRouterDelegate? _router;
  bool _wasOnRegistry = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final router = Router.maybeOf(context)?.routerDelegate;
    if (router is! AppRouterDelegate || identical(router, _router)) return;
    _router?.removeListener(_onRouteChanged);
    _router = router..addListener(_onRouteChanged);
  }

  void _onRouteChanged() {
    if (!mounted) return;
    final onRegistry = _router?.currentConfiguration is RegistryRoute;
    // Only the arrival, not every notification while sitting here.
    if (onRegistry && !_wasOnRegistry) {
      setState(() => _promptRevision++);
    }
    _wasOnRegistry = onRegistry;
  }

  @override
  void dispose() {
    _router?.removeListener(_onRouteChanged);
    _scans.removeListener(_onScansChanged);
    _urlController.dispose();
    super.dispose();
  }

  void _onScansChanged() {
    if (!mounted) return;
    if (_scans.completions == _seenCompletions) return;
    _seenCompletions = _scans.completions;
    _reload();
  }

  void _reload() {
    // Whatever has landed by now is in this response, so the list is current as
    // of this moment rather than as of the scan that triggered it.
    _seenCompletions = _scans.completions;
    // A statement body, not an expression one. `setState(() => x = future)`
    // returns that future from the callback, and Flutter asserts on a callback
    // that returns a Future — so in a debug build this method threw and the
    // list was never rebuilt. It looked like the reload had not been asked for;
    // it had, and it was blowing up on the way out.
    final projects = _fetch();
    setState(() {
      _projects = projects;
    });
  }

  /// Switches half. Goes through the router so the address bar follows and the
  /// sidebar's two entries agree with what is on screen.
  void _setFilter(bool archived) {
    if (archived == _showArchived) return;
    routerOf(context).go(AppRoute.registry(archived: archived));
  }

  /// Hands the repository to the background queue and clears the field.
  ///
  /// Deliberately does not await the scan. Analyzing a repository takes tens of
  /// seconds, and holding the form for that long meant a second project could
  /// not even be typed, let alone queued — with nothing on screen saying how
  /// much longer it would be. The scan announces itself in the floating panel
  /// instead, and this screen reloads when it lands.
  void _add() {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    final parsed = Uri.tryParse(url);
    if (parsed == null || !parsed.hasScheme || parsed.pathSegments.isEmpty) {
      setState(() => _error = 'That does not look like a Git URL.');
      return;
    }

    _scans.addProject(_api, url);
    _urlController.clear();
    setState(() {
      _error = null;
      // A newly added project is active, so show that view.
      _showArchived = false;
    });
  }

  /// Bumped when settings closes, so the PIN prompt is rebuilt from scratch.
  ///
  /// It decides whether to show itself once, when its state is created — so
  /// without a new key it would go on offering a PIN that was just set.
  int _promptRevision = 0;

  /// Where the account, the session and the device PIN are managed. Signing out
  /// lives there too, so the app bar spends its width on the registry rather
  /// than on account plumbing.
  void _openSettings() => routerOf(context).go(const AppRoute.settings());

  /// The signed-in address, or null where there is no Supabase to ask.
  ///
  /// Guarded the same way [PinGate] guards its own lookup: reaching for
  /// `Supabase.instance` before `main` has initialized it throws, which makes
  /// this screen unmountable in a widget test for the sake of one line of
  /// chrome.
  String? get _email {
    try {
      return supabase.auth.currentUser?.email;
    } catch (_) {
      return null;
    }
  }

  String? get _userId {
    try {
      return supabase.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  /// The offer to set a device PIN. Same widget on both skins — only where it
  /// sits differs.
  Widget get _pinPrompt => PinPrompt(
        key: ValueKey('pin-prompt-$_userId-$_promptRevision'),
        userId: _userId,
        onSetUp: _openSettings,
      );

  Widget get _list => ProjectList(
        future: _projects,
        api: _api,
        archived: _showArchived,
        index: _index,
      );

  @override
  Widget build(BuildContext context) {
    return ConsoleFrame(
      console: RegistryConsole(
        controller: _urlController,
        onSubmit: _add,
        archived: _showArchived,
        onFilter: _setFilter,
        error: _error,
        pinPrompt: _pinPrompt,
        trackedCount: _trackedCount,
        grid: _list,
      ),
      compact: _buildCompact(context),
    );
  }

  /// The layout this app had before the console: an ink band, then the list.
  Widget _buildCompact(BuildContext context) {
    final email = _email;

    final theme = Theme.of(context);

    return Scaffold(
      // The band is drawn by the body, so the bar floats over it and its
      // actions land inside the dark area rather than on a strip above it.
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('DepControl'),
        actions: [
          IconButton(
            tooltip: _showArchived ? 'Show active projects' : 'Show archived',
            icon: Icon(
              _showArchived
                  ? Icons.folder_outlined
                  : Icons.inventory_2_outlined,
            ),
            onPressed: () => _setFilter(!_showArchived),
          ),
          if (email != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  email,
                  style: mono(
                    theme.textTheme.bodySmall,
                    color: Colors.white.withValues(alpha: 0.7),
                  ),
                ),
              ),
            ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkBand(
            // Bounded to the same measure as the list below it, so the heading
            // and the rows it introduces share a left edge on a wide screen.
            child: BoundedWidth(
              max: 1180,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Eyebrow(
                    _showArchived ? 'Archived' : 'Registry',
                    color: Palette.pub,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _showArchived
                        ? 'Projects you have put out of the way.'
                        : 'Every project you track, and what it depends on.',
                    style: display(
                      theme.textTheme.headlineSmall,
                      color: Colors.white,
                    ),
                  ),
                  if (!_showArchived) ...[
                    const SizedBox(height: 18),
                    _AddForm(
                      controller: _urlController,
                      onSubmit: _add,
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _error!,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: const Color(0xFFFF9CA8)),
                    ),
                  ],
                ],
              ),
            ),
          ),
          _pinPrompt,
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
              // Bounded, so a wide monitor gives more columns rather than
              // wider rows — a project name and its menu at opposite ends of a
              // 2560-pixel row is a head-turn to read.
              child: BoundedWidth(max: 1180, child: _list),
            ),
          ),
        ],
      ),
    );
  }
}

/// The Git URL field and its button.
///
/// Has no busy state any more: the button queues a scan and returns, so there
/// is never a moment where it is unavailable. Where the scan has got to is the
/// floating panel's job, and saying it in two places would let them disagree.
class _AddForm extends StatelessWidget {
  const _AddForm({
    required this.controller,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            // A git URL is a machine-matched string, so it is set like one —
            // and the hint doubles as the shape it expects.
            style: mono(theme.textTheme.bodyMedium),
            decoration: InputDecoration(
              labelText: 'Git URL',
              hintText: 'https://github.com/owner/repo',
              hintStyle: mono(theme.textTheme.bodyMedium, color: Palette.slate),
              prefixIcon: const Icon(Icons.link, size: 20),
            ),
            onSubmitted: (_) => onSubmit(),
          ),
        ),
        const SizedBox(width: 12),
        FilledButton(
          onPressed: onSubmit,
          child: const Text('Add project'),
        ),
      ],
    );
  }
}

/// The registry's list of projects.
///
/// Public so widget tests can drive the swipe actions without standing up the
/// whole screen and its auth.
class ProjectList extends StatelessWidget {
  const ProjectList({
    required this.future,
    required this.api,
    this.archived = false,
    this.surface,
    this.index,
    super.key,
  });

  final Future<List<Project>> future;
  final ApiClient api;
  final bool archived;

  /// Kept in step when a row is deleted, so the sidebar stops offering a link
  /// to a report the server no longer has.
  final ProjectIndex? index;

  /// Which build this is — it decides whether rows can be swiped. Defaults to
  /// the real one; a widget test runs on neither platform and passes a value.
  final AppSurface? surface;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Project>>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        // Surface failures instead of rendering them as "no projects yet".
        if (snap.hasError) {
          final error = snap.error;
          if (error is ApiAuthException) {
            // Tell the gate, which asks the user before replacing the screen.
            // The message stays on show underneath, so the page still says
            // something once the dialog is answered either way.
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => SessionMonitor.instance.reportExpired(error.message),
            );
          }
          return Center(
            child: Text(
              error is ApiException
                  ? error.message
                  : 'Could not load projects.',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
              textAlign: TextAlign.center,
            ),
          );
        }

        final projects = snap.data ?? const <Project>[];
        if (projects.isEmpty) {
          return Center(
            child: Text(
              archived
                  ? 'Nothing archived.'
                  : 'No projects yet — add one by Git URL above.',
            ),
          );
        }
        return _ProjectRows(
          key: ValueKey(archived),
          projects: projects,
          api: api,
          archived: archived,
          surface: surface,
          index: index,
        );
      },
    );
  }
}

/// The rows themselves, which own their list so a swipe can take one out
/// immediately instead of waiting for a round trip.
class _ProjectRows extends StatefulWidget {
  const _ProjectRows({
    required this.projects,
    required this.api,
    required this.archived,
    this.surface,
    this.index,
    super.key,
  });

  final List<Project> projects;
  final ApiClient api;
  final ProjectIndex? index;

  /// Whether this is the archived view, which swaps archiving for restoring.
  final bool archived;

  /// Which build this is. Defaults to the real one; injectable so a widget
  /// test can drive both without running on either platform.
  final AppSurface? surface;

  @override
  State<_ProjectRows> createState() => _ProjectRowsState();
}

class _ProjectRowsState extends State<_ProjectRows> {
  late List<Project> _projects = [...widget.projects];

  /// How many times each row has come back, by project id.
  ///
  /// A [Dismissible] that has been dismissed may not reappear under the same
  /// key — Flutter asserts on it — so a restored row is given a new one.
  final _revivals = <String, int>{};

  Key _keyFor(Project project) =>
      ValueKey('${project.id}#${_revivals[project.id] ?? 0}');

  @override
  void didUpdateWidget(_ProjectRows old) {
    super.didUpdateWidget(old);
    if (!identical(old.projects, widget.projects)) {
      _projects = [...widget.projects];
    }
  }

  void _show(String message, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action));
  }

  /// Puts [project] back where it was after a failure or an undo.
  void _restoreRow(int index, Project project) {
    if (!mounted) return;
    setState(() {
      _revivals[project.id] = (_revivals[project.id] ?? 0) + 1;
      _projects.insert(index.clamp(0, _projects.length), project);
    });
  }

  /// Archiving is reversible, so it happens on the swipe and offers an undo
  /// rather than asking first.
  Future<void> _archive(
    Project project,
    int index, {
    required bool archive,
  }) async {
    setState(() => _projects.removeAt(index));
    try {
      await widget.api.setArchived(project.id, archived: archive);
    } on ApiException catch (e) {
      _restoreRow(index, project);
      _show(e.message);
      return;
    }

    _show(
      archive ? '${project.name} archived.' : '${project.name} restored.',
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () async {
          try {
            await widget.api.setArchived(project.id, archived: !archive);
            _restoreRow(index, project);
          } on ApiException catch (e) {
            _show(e.message);
          }
        },
      ),
    );
  }

  /// Deleting takes the report with it and the server keeps no copy, so this
  /// asks first. An "undo" here would mean re-adding and re-analyzing under a
  /// new id, which is not the same thing and should not be presented as if it
  /// were.
  Future<bool> _confirmDelete(Project project) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${project.name}?'),
        content: const Text(
          'This removes the project and its dependency report. It cannot be '
          'undone — you would have to add the repository again and '
          're-analyze it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _delete(Project project, int index) async {
    setState(() => _projects.removeAt(index));
    try {
      await widget.api.deleteProject(project.id);
      // The sidebar is drawn from a cache this screen feeds, so it has to be
      // told — otherwise the rail goes on linking to a report the server has
      // just thrown away.
      (widget.index ?? ProjectIndex.instance).forget(project.id);
      _show('${project.name} deleted.');
    } on ApiException catch (e) {
      _restoreRow(index, project);
      _show(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surface = widget.surface ?? AppSurface.current();

    // The console draws the same projects as cards rather than rows. Only the
    // drawing differs — archiving, deleting and their undos stay here, because
    // an optimistic removal belongs in the same object as the list it removes
    // from.
    if (ConsoleFrame.isConsole(context)) return _cards(context);

    final columns = Layout.of(context).registryColumns;

    // One column is a list; more is a grid. Not the same widget with a
    // different count, because a grid forces every cell to one height and a
    // single-column list of rows should keep sizing to its content.
    if (columns > 1) {
      return GridView.builder(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          // Wide and short: a project row is a name over a URL, and a squarer
          // cell would be mostly empty.
          mainAxisExtent: 88,
        ),
        itemCount: _projects.length,
        itemBuilder: (context, i) => _row(context, theme, surface, i),
      );
    }

    return ListView.separated(
      itemCount: _projects.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) => _row(context, theme, surface, i),
    );
  }

  /// The console's grid of project cards.
  ///
  /// Shrink-wrapped and unscrollable: the console page is one scroll view from
  /// the hero down to the banner, and a grid with its own scrolling inside that
  /// would trap the wheel over half the page.
  Widget _cards(BuildContext context) {
    // Two columns is the drawing, and it holds down to about a 1400-pixel
    // window; below that a card's repository URL starts wrapping, so the grid
    // gives up the second column rather than the legibility.
    final width = MediaQuery.sizeOf(context).width;
    final columns = width >= 1400 ? 2 : 1;

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: 20,
        crossAxisSpacing: 20,
        mainAxisExtent: 152,
      ),
      itemCount: _projects.length,
      itemBuilder: (context, i) {
        final project = _projects[i];
        return ProjectCard(
          key: ValueKey(project.id),
          project: project,
          archived: widget.archived,
          onOpen: () => routerOf(context).openReport(project),
          onArchive: () => _archive(project, i, archive: !widget.archived),
          onDelete: () async {
            if (await _confirmDelete(project)) await _delete(project, i);
          },
        );
      },
    );
  }

  /// One project, with or without the swipe wrapper.
  Widget _row(
    BuildContext context,
    ThemeData theme,
    AppSurface surface,
    int i,
  ) {
    final project = _projects[i];

    // Opaque, so that on the app build the row slides *over* the action
    // rather than letting its colour through. A bare ListTile has no
    // background of its own, which tinted the icon, text and menu the
    // colour of whichever action was being revealed.
    final row = Material(
      color: Palette.paper,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Palette.ink.withValues(alpha: 0.10)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
        leading: Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: (widget.archived ? Palette.slate : Palette.pub)
                .withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            widget.archived
                ? Icons.inventory_2_outlined
                : Icons.folder_outlined,
            size: 20,
            color: widget.archived ? Palette.slate : Palette.pub,
          ),
        ),
        title: Text(
          project.name,
          style: theme.textTheme.titleSmall,
        ),
        subtitle: Text(
          '${project.gitUrl} @ ${project.ref}',
          style: mono(theme.textTheme.bodySmall, color: Palette.slate),
        ),
        // The only way to reach these on the browser build, where there
        // is no swipe — and the way most people reach them on the app
        // build too, since a swipe is not discoverable.
        trailing: _RowActions(
          archived: widget.archived,
          onArchive: () => _archive(project, i, archive: !widget.archived),
          onDelete: () async {
            if (await _confirmDelete(project)) await _delete(project, i);
          },
        ),
        // Through the router, so the address bar follows and the report
        // can be linked to. The project goes with it, so the screen it
        // opens needs no round trip — that cost falls only on a deep
        // link, which has an id and nothing else.
        onTap: () => routerOf(context).openReport(project),
      ),
    );

    // No swipe in a browser. A drag across a row is a gesture people make
    // on a phone and one nobody makes with a mouse: it is invisible until
    // it is discovered by accident, and when it *is* discovered by accident
    // it deletes something. The row menu carries both actions on both
    // builds, so nothing is lost by leaving the gesture off the surface it
    // never suited.
    if (surface.isBrowser) return row;

    return Dismissible(
      key: _keyFor(project),
      // Swipe right deletes; swipe left archives (or restores).
      background: _SwipeBackground(
        alignment: Alignment.centerLeft,
        color: theme.colorScheme.error,
        icon: Icons.delete_outline,
        label: 'Delete',
      ),
      secondaryBackground: _SwipeBackground(
        alignment: Alignment.centerRight,
        color: widget.archived ? Colors.green.shade700 : Colors.blueGrey,
        icon:
            widget.archived ? Icons.unarchive_outlined : Icons.archive_outlined,
        label: widget.archived ? 'Restore' : 'Archive',
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          return _confirmDelete(project);
        }
        return true;
      },
      onDismissed: (direction) {
        if (direction == DismissDirection.startToEnd) {
          _delete(project, i);
        } else {
          _archive(project, i, archive: !widget.archived);
        }
      },
      child: row,
    );
  }
}

/// What shows behind a row as it is swiped away.
class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({
    required this.alignment,
    required this.color,
    required this.icon,
    required this.label,
  });

  final Alignment alignment;
  final Color color;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: color,
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// The same two actions as the swipes, reachable with a pointer.
class _RowActions extends StatelessWidget {
  const _RowActions({
    required this.archived,
    required this.onArchive,
    required this.onDelete,
  });

  final bool archived;
  final VoidCallback onArchive;
  final Future<void> Function() onDelete;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Actions',
      onSelected: (value) {
        if (value == 'archive') {
          onArchive();
        } else {
          onDelete();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'archive',
          child: Text(archived ? 'Restore' : 'Archive'),
        ),
        PopupMenuItem(
          value: 'delete',
          child: Text(
            'Delete',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      ],
    );
  }
}
