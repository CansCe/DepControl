import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/session_monitor.dart';
import '../platform/app_surface.dart';

/// Signs the browser build out after a stretch with no interaction.
///
/// **Why this exists, and what it is not.** Supabase issues one access-token
/// lifetime for the whole project — the client cannot ask for a shorter one
/// because it is a browser, and nothing in this app can change what the token
/// says. So a "shorter session on the web" is not something to request; it is
/// something to *enforce*, here, by ending the session early.
///
/// What that genuinely buys is the risk the device PIN used to cover, on the
/// surface where it covers the most: a signed-in tab left open on a laptop, a
/// shared machine, a desk someone else walks past. After the timeout there is
/// no session in this browser to walk up to, which is more than a screen lock
/// ever did — the PIN sat in front of a token that was still sitting in
/// `localStorage` for anyone who opened the developer console.
///
/// What it does **not** buy is protection against a token that has already been
/// copied. Signing out clears this browser's copy; it does not tell the API to
/// stop honouring one somebody else took, and the backend verifies tokens
/// locally against the JWKS without asking Supabase whether the session is
/// still wanted. Until that token's own `exp` passes it stays good. Shortening
/// *that* window is the Supabase JWT expiry setting, which is project-wide and
/// documented in docs/DEPLOY.md — a different lever, in a different place, and
/// this one is not a substitute for it.
///
/// Not on the installed app, which keeps its PIN: its storage is private, the
/// device has a lock screen of its own, and signing someone out of a phone app
/// because they read something else for half an hour is an annoyance that buys
/// nothing there.
class WebSessionTimeout extends StatefulWidget {
  const WebSessionTimeout({
    required this.child,
    this.idleLimit = defaultIdleLimit,
    this.surface,
    this.monitor,
    super.key,
  });

  /// How long the tab may sit untouched.
  ///
  /// Thirty minutes is chosen to be shorter than a lunch break and longer than
  /// reading a long report, which are the two things this has to tell apart.
  /// It is deliberately not aggressive: a timeout that fires while somebody is
  /// still reading teaches them to keep the tab active, which defeats it.
  static const defaultIdleLimit = Duration(minutes: 30);

  /// How long before the limit to warn, so the sign-out is never a surprise
  /// that eats half-typed input.
  static const warnBefore = Duration(minutes: 2);

  final Widget child;
  final Duration idleLimit;

  /// Defaults to the real build; injectable so a test can drive either.
  final AppSurface? surface;

  /// Defaults to the app-wide monitor.
  final SessionMonitor? monitor;

  @override
  State<WebSessionTimeout> createState() => _WebSessionTimeoutState();
}

class _WebSessionTimeoutState extends State<WebSessionTimeout> {
  late final AppSurface _surface = widget.surface ?? AppSurface.current();
  SessionMonitor get _monitor => widget.monitor ?? SessionMonitor.instance;

  Timer? _warn;
  Timer? _signOut;

  /// Whether the warning is on screen. Held rather than read off the timer so
  /// that dismissing it and restarting the clock are one decision.
  bool _warning = false;

  @override
  void initState() {
    super.initState();
    if (_enabled) _restart();
  }

  /// The browser build only.
  ///
  /// "Only while signed in" is structural rather than checked here: this sits
  /// inside the auth gate, so it is not built at all when nobody is signed in
  /// and no timer can fire into an empty session.
  bool get _enabled => _surface.isBrowser;

  @override
  void dispose() {
    _warn?.cancel();
    _signOut?.cancel();
    super.dispose();
  }

  /// Any interaction at all puts the full limit back.
  ///
  /// Including while the warning is up, where it counts as answering it. The
  /// button is there for someone who reads the banner, but somebody who simply
  /// carries on typing has demonstrated the same thing, and signing them out
  /// mid-sentence because they did not click the right button would be the
  /// exact failure this warning exists to prevent.
  void _touched() {
    if (!_enabled) return;
    if (_warning) {
      _stayed();
      return;
    }
    _restart();
  }

  void _restart() {
    _warn?.cancel();
    _signOut?.cancel();

    final lead = widget.idleLimit - WebSessionTimeout.warnBefore;
    if (lead > Duration.zero) {
      _warn = Timer(lead, _showWarning);
    }
    _signOut = Timer(widget.idleLimit, _endSession);
  }

  void _showWarning() {
    if (!mounted) return;
    setState(() => _warning = true);
  }

  Future<void> _endSession() async {
    if (!mounted) return;
    setState(() => _warning = false);
    await _monitor.signedOutForInactivity(widget.idleLimit);
  }

  /// The user is still there. Clears the warning and starts the clock over.
  void _stayed() {
    if (!mounted) return;
    setState(() => _warning = false);
    _restart();
  }

  @override
  Widget build(BuildContext context) {
    if (!_enabled) return widget.child;

    return Listener(
      // Listening rather than intercepting: `behavior: deferToChild` would miss
      // taps on empty space, and anything that consumed the event would break
      // every button underneath. This sees the pointer on its way down and
      // passes it along untouched.
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _touched(),
      onPointerSignal: (_) => _touched(),
      // A long report is read by scrolling and nothing else, so a scroll has to
      // count as being there. Without this the timeout fires at the reader's
      // desk while they are looking straight at it.
      onPointerMove: (_) => _touched(),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (_, __) {
          _touched();
          return KeyEventResult.ignored;
        },
        child: Stack(
          children: [
            widget.child,
            if (_warning)
              _IdleWarning(
                within: WebSessionTimeout.warnBefore,
                onStay: _stayed,
                onSignOutNow: _endSession,
              ),
          ],
        ),
      ),
    );
  }
}

/// The last-call notice, shown a couple of minutes before the session ends.
///
/// A banner rather than a modal dialog. A dialog would take the keyboard, and
/// the most likely reader is somebody mid-sentence in the "add a project" field
/// who needs to finish the sentence, not answer a question about it.
class _IdleWarning extends StatelessWidget {
  const _IdleWarning({
    required this.within,
    required this.onStay,
    required this.onSignOutNow,
  });

  final Duration within;
  final VoidCallback onStay;
  final Future<void> Function() onSignOutNow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final minutes = within.inMinutes;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(12),
            color: theme.colorScheme.inverseSurface,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
              child: Row(
                children: [
                  Icon(
                    Icons.timer_outlined,
                    size: 20,
                    color: theme.colorScheme.onInverseSurface,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'This browser has been idle. It will sign out in '
                      '$minutes minutes to leave no session open here.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onInverseSurface,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => onSignOutNow(),
                    child: const Text('Sign out now'),
                  ),
                  const SizedBox(width: 4),
                  FilledButton(
                    onPressed: onStay,
                    child: const Text("I'm here"),
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
