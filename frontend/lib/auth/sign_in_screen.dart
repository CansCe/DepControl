import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme.dart';
import '../widgets/chrome.dart';

/// Email/password sign-in, with sign-up on the same form.
///
/// On success the auth state stream fires and [AuthGate] swaps in the app, so
/// this screen never navigates itself.
class SignInScreen extends StatefulWidget {
  const SignInScreen({this.notice, super.key});

  /// Why the user is looking at this screen, when there is a reason worth
  /// repeating — the server's explanation for an expired session, say. Shown
  /// once, above the form, and cleared as soon as they start over.
  final String? notice;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();

  bool _busy = false;
  bool _isSignUp = false;
  String? _error;
  late String? _notice = widget.notice;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });

    final auth = Supabase.instance.client.auth;
    final email = _email.text.trim();
    final password = _password.text;

    try {
      if (_isSignUp) {
        final res = await auth.signUp(email: email, password: password);
        // With email confirmation enabled, sign-up returns a user but no
        // session — the app can't proceed until the link is clicked.
        if (res.session == null && mounted) {
          setState(() => _notice =
              'Account created. Check $email for a confirmation link, then '
                  'sign in.');
          setState(() => _isSignUp = false);
        }
      } else {
        await auth.signInWithPassword(email: email, password: password);
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not reach Supabase. $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// How the GitHub authorize page is opened.
  ///
  /// The default, [LaunchMode.platformDefault], sends an `https` URL to a
  /// Custom Tab, which is a browser and stays a browser — the GitHub app never
  /// gets the chance to handle it. [LaunchMode.externalApplication] fires a
  /// plain `ACTION_VIEW` intent instead, so Android resolves it the way it
  /// resolves any link: github.com serves an `assetlinks.json` delegating to
  /// `com.github.android`, so a verified install of the GitHub app takes it and
  /// everyone else falls through to the default browser. That fallback is the
  /// point — [LaunchMode.externalNonBrowserApplication] would *require* the app
  /// and throw for the users who do not have it.
  ///
  /// Android only: iOS keeps the default so sign-in stays in the in-app
  /// Safari sheet, and web ignores the mode entirely.
  LaunchMode get _authScreenLaunchMode =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android
          ? LaunchMode.externalApplication
          : LaunchMode.platformDefault;

  Future<void> _signInWithGitHub() async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });

    try {
      await Supabase.instance.client.auth.signInWithOAuth(
        OAuthProvider.github,
        // On web the browser returns to the current origin, which must be in
        // Supabase's redirect allow list. Native builds need the deep link.
        redirectTo: kIsWeb ? null : 'io.supabase.depcontrol://login-callback/',
        authScreenLaunchMode: _authScreenLaunchMode,
      );
      // The browser navigates away; onAuthStateChange resumes the app on
      // return, so nothing more to do here.
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not start GitHub sign-in. $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Ink page, paper form. The same two surfaces the rest of the app is built
    // from, so the first screen someone sees already teaches the palette.
    return Scaffold(
      backgroundColor: Palette.ink,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Eyebrow('DepControl', color: Palette.pub),
                const SizedBox(height: 8),
                Text(
                  _isSignUp ? 'Track a project.' : 'Know what you depend on.',
                  style: display(
                    theme.textTheme.headlineMedium,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _isSignUp
                      ? 'Create an account to start tracking projects.'
                      : 'Sign in to see your projects.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.white.withValues(alpha: 0.62),
                  ),
                ),
                const SizedBox(height: 22),
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Palette.paper,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _signInWithGitHub,
                          icon: const Icon(Icons.code),
                          label: const Text('Continue with GitHub'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            const Expanded(child: Divider()),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              child: Text(
                                'or with email',
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                            const Expanded(child: Divider()),
                          ],
                        ),
                        const SizedBox(height: 20),
                        TextFormField(
                          controller: _email,
                          autofillHints: const [AutofillHints.email],
                          keyboardType: TextInputType.emailAddress,
                          // Border comes from the theme, so every field in the
                          // app rounds the same way.
                          decoration: const InputDecoration(
                            labelText: 'Email',
                            prefixIcon: Icon(Icons.alternate_email, size: 20),
                          ),
                          validator: (v) {
                            final value = v?.trim() ?? '';
                            if (value.isEmpty) return 'Enter your email';
                            if (!value.contains('@')) {
                              return 'Enter a valid email';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _password,
                          obscureText: true,
                          autofillHints: const [AutofillHints.password],
                          decoration: const InputDecoration(
                            labelText: 'Password',
                            prefixIcon: Icon(Icons.lock_outline, size: 20),
                          ),
                          onFieldSubmitted: (_) => _submit(),
                          validator: (v) {
                            if ((v ?? '').isEmpty) return 'Enter your password';
                            if (_isSignUp && (v?.length ?? 0) < 6) {
                              return 'Use at least 6 characters';
                            }
                            return null;
                          },
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            _error!,
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ],
                        if (_notice != null) ...[
                          const SizedBox(height: 12),
                          Text(_notice!, style: theme.textTheme.bodySmall),
                        ],
                        const SizedBox(height: 20),
                        FilledButton(
                          onPressed: _busy ? null : _submit,
                          child: _busy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Text(_isSignUp ? 'Create account' : 'Sign in'),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                    _isSignUp = !_isSignUp;
                                    _error = null;
                                    _notice = null;
                                  }),
                          child: Text(
                            _isSignUp
                                ? 'Already have an account? Sign in'
                                : 'No account? Create one',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
