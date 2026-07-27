import 'package:flutter/material.dart';
import 'package:shared/shared.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'api/api_client.dart';
import 'auth/auth_gate.dart';

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
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF0553B1), // Dart blue
        useMaterial3: true,
      ),
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
  String? _error;

  @override
  void initState() {
    super.initState();
    _projects = _api.listProjects();
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
      setState(() => _projects = _api.listProjects());
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('DepControl — Registry'),
        actions: [
          if (email != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(email, style: Theme.of(context).textTheme.bodySmall),
              ),
            ),
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () => supabase.auth.signOut(),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _AddForm(
              controller: _urlController,
              adding: _adding,
              onSubmit: _add,
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: Colors.red.shade700)),
            ],
            const SizedBox(height: 24),
            Expanded(child: _ProjectList(future: _projects)),
          ],
        ),
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
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'Git URL',
              hintText: 'https://github.com/owner/repo',
              border: OutlineInputBorder(),
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
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Add project'),
        ),
      ],
    );
  }
}

class _ProjectList extends StatelessWidget {
  const _ProjectList({required this.future});
  final Future<List<Project>> future;

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

        final projects = snap.data ?? const [];
        if (projects.isEmpty) {
          return const Center(
            child: Text('No projects yet — add one by Git URL above.'),
          );
        }
        return ListView.separated(
          itemCount: projects.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final p = projects[i];
            return ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(p.name),
              subtitle: Text('${p.gitUrl} @ ${p.ref}'),
              trailing: const Icon(Icons.chevron_right),
              // TODO(phase1): push ReportScreen(projectId: p.id).
              onTap: () {},
            );
          },
        );
      },
    );
  }
}
