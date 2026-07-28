import 'package:flutter/material.dart';
import 'package:shared/shared.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'api/api_client.dart';
import 'auth/auth_gate.dart';
import 'screens/report_screen.dart';
import 'theme.dart';
import 'widgets/chrome.dart';

/// Shorthand for the Supabase client once [main] has initialized it.
SupabaseClient get supabase => Supabase.instance.client;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: 'https://ogsnkqlamfvftdgvvtje.supabase.co',
    // Publishable key — public by design; safe in client code.
    // Never place the service_role/secret key here. Requires RLS on all tables.
    publishableKey: 'sb_publishable_1hxQQb522Ukayaq9TzPvpg_oiu7KkK6',
  );
  runApp(const DepControlApp());
}

class DepControlApp extends StatelessWidget {
  const DepControlApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DepControl',
      theme: buildTheme(),
      // Projects are owned by the signed-in user, so the registry is only
      // reachable with a session.
      home: const AuthGate(child: RegistryScreen()),
    );
  }
}

/// Phase 3 entry point: the multi-project registry + an "add by git URL" form.
class RegistryScreen extends StatefulWidget {
  const RegistryScreen({super.key});

  @override
  State<RegistryScreen> createState() => _RegistryScreenState();
}

class _RegistryScreenState extends State<RegistryScreen> {
  final _api = ApiClient();
  final _urlController = TextEditingController();
  late Future<List<Project>> _projects;
  bool _adding = false;

  /// Archived projects are a separate view: putting one out of the way should
  /// take it out of the way.
  bool _showArchived = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _projects = _api.listProjects();
  }

  void _reload() {
    setState(() => _projects = _api.listProjects(archived: _showArchived));
  }

  Future<void> _add() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _adding = true;
      _error = null;
    });
    try {
      await _api.addProject(url);
      _urlController.clear();
      // A newly added project is active, so show that view.
      setState(() => _showArchived = false);
      _reload();
    } on ApiAuthException catch (e) {
      // The session died mid-use; drop it so AuthGate shows sign-in again.
      setState(() => _error = e.message);
      await supabase.auth.signOut();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = supabase.auth.currentUser?.email;

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
            onPressed: () {
              setState(() => _showArchived = !_showArchived);
              _reload();
            },
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
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () => supabase.auth.signOut(),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkBand(
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
                    adding: _adding,
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
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
              child: ProjectList(
                future: _projects,
                api: _api,
                archived: _showArchived,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddForm extends StatelessWidget {
  const _AddForm({
    required this.controller,
    required this.adding,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final bool adding;
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
          onPressed: adding ? null : onSubmit,
          child: adding
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Add project'),
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
    super.key,
  });

  final Future<List<Project>> future;
  final ApiClient api;
  final bool archived;

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
            // Session is gone; clearing it sends AuthGate back to sign-in.
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => supabase.auth.signOut(),
            );
            return const Center(child: CircularProgressIndicator());
          }
          return Center(
            child: Text(
              error is ApiException ? error.message : 'Could not load projects.',
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
    super.key,
  });

  final List<Project> projects;
  final ApiClient api;

  /// Whether this is the archived view, which swaps archiving for restoring.
  final bool archived;

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
      _show('${project.name} deleted.');
    } on ApiException catch (e) {
      _restoreRow(index, project);
      _show(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView.separated(
      itemCount: _projects.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final project = _projects[i];

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
            icon: widget.archived
                ? Icons.unarchive_outlined
                : Icons.archive_outlined,
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
          // Opaque, so the row slides *over* the action rather than letting its
          // colour through. A bare ListTile has no background of its own, which
          // tinted the icon, text and menu the colour of whichever action was
          // being revealed.
          child: Material(
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
              // A swipe is invisible with a mouse, and this runs on the web.
              trailing: _RowActions(
                archived: widget.archived,
                onArchive: () =>
                    _archive(project, i, archive: !widget.archived),
                onDelete: () async {
                  if (await _confirmDelete(project)) await _delete(project, i);
                },
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ReportScreen(
                    project: project,
                    api: widget.api,
                  ),
                ),
              ),
            ),
          ),
        );
      },
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
