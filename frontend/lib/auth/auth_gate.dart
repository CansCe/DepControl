import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme.dart';
import 'session_monitor.dart';
import 'sign_in_screen.dart';

/// Chooses between [SignInScreen] and the signed-in app based on the live
/// Supabase auth state.
///
/// Listening to `onAuthStateChange` rather than reading `currentSession` once
/// means a sign-out, a token refresh failure, or a session restored from
/// storage all move the UI without any screen having to navigate.
///
/// The decision of *what to do about* a session that ended lives in
/// [SessionGate], which knows nothing about Supabase and can therefore be
/// tested without it.
class AuthGate extends StatelessWidget {
  const AuthGate({required this.child, this.monitor, super.key});

  /// Shown once a session exists.
  final Widget child;

  /// Defaults to the app-wide monitor; injectable for tests.
  final SessionMonitor? monitor;

  @override
  Widget build(BuildContext context) {
    final auth = Supabase.instance.client.auth;

    return StreamBuilder<AuthState>(
      stream: auth.onAuthStateChange,
      builder: (context, snapshot) {
        // The stream emits on subscribe, but only after Supabase has restored
        // any persisted session; until then fall back to the current value so
        // a returning user doesn't flash the sign-in screen.
        final session = snapshot.data?.session ?? auth.currentSession;

        if (snapshot.connectionState == ConnectionState.waiting &&
            session == null) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        return SessionGate(
          hasSession: session != null,
          monitor: monitor ?? SessionMonitor.instance,
          child: child,
        );
      },
    );
  }
}

/// Decides whether the app, the sign-in screen, or a warning is what someone
/// should be looking at.
///
/// Split out from [AuthGate] because the interesting part is not reading the
/// auth state — it is the rule that a session ending on its own gets announced
/// before the screen changes, while one the user ended themselves does not.
class SessionGate extends StatefulWidget {
  const SessionGate({
    required this.hasSession,
    required this.monitor,
    required this.child,
    super.key,
  });

  final bool hasSession;
  final SessionMonitor monitor;
  final Widget child;

  @override
  State<SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<SessionGate> {
  /// Whether this gate has ever seen a session. Without it, arriving at the
  /// sign-in screen for the ordinary reason — nobody has signed in yet — would
  /// be indistinguishable from a session disappearing, and every cold start
  /// would open with "your session expired".
  bool _hadSession = false;

  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    widget.monitor.addListener(_onMonitorChanged);
    _reconcile();
  }

  @override
  void didUpdateWidget(covariant SessionGate old) {
    super.didUpdateWidget(old);
    if (old.monitor != widget.monitor) {
      old.monitor.removeListener(_onMonitorChanged);
      widget.monitor.addListener(_onMonitorChanged);
    }
    _reconcile();
  }

  @override
  void dispose() {
    widget.monitor.removeListener(_onMonitorChanged);
    super.dispose();
  }

  void _onMonitorChanged() {
    if (mounted) setState(_maybePrompt);
  }

  /// Reads the session against what the monitor believes and reconciles the
  /// two.
  void _reconcile() {
    final monitor = widget.monitor;

    if (widget.hasSession) {
      _hadSession = true;
      // A new session means the last one's ending is history.
      if (monitor.status == SessionStatus.ended) monitor.reset();
      return;
    }

    // No session, and nobody asked for that. Supabase drops a session the
    // moment a refresh fails, so this is the path an expiry actually takes
    // when the app is idle rather than mid-request.
    if (_hadSession && monitor.status == SessionStatus.live) {
      // Deferred: this runs during build, and notifying listeners synchronously
      // would rebuild the tree that is already building.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) monitor.reportExpired();
      });
    }

    _maybePrompt();
  }

  void _maybePrompt() {
    if (widget.monitor.status != SessionStatus.expiredUnannounced) return;
    if (_dialogOpen) return;
    _dialogOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _showDialog());
  }

  Future<void> _showDialog() async {
    if (!mounted) {
      _dialogOpen = false;
      return;
    }

    final monitor = widget.monitor;
    final signIn = await showDialog<bool>(
      context: context,
      // The screen behind this is already dead. Letting it be dismissed by a
      // stray tap would leave someone poking at a UI that cannot answer, with
      // nothing on screen explaining why.
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.lock_clock, color: Palette.pub),
        title: const Text('Your session has expired'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'You have been signed out. Sign in again to load projects, '
              're-analyze, or change anything.',
            ),
            if (monitor.reason case final reason?) ...[
              const SizedBox(height: 10),
              Text(
                reason,
                style: mono(
                  Theme.of(context).textTheme.bodySmall,
                  color: Palette.slate,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Stay on this page'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign in again'),
          ),
        ],
      ),
    );

    _dialogOpen = false;
    if (signIn ?? false) {
      await monitor.confirm();
    } else {
      monitor.postpone();
    }
  }

  /// What to say on the sign-in screen when the user did not choose to be
  /// there. Null after a deliberate sign-out, which needs no explanation.
  String? get _arrivalNotice => switch (widget.monitor.endedBy) {
        null => null,
        SessionEnding.expired => switch (widget.monitor.reason) {
            null => 'Your session expired, so you were signed out.',
            final reason =>
              'Your session expired, so you were signed out. The server '
                  'said: $reason',
          },
        // Says what happened *and* why, because unlike an expiry this was a
        // decision this app made and the reader is entitled to know the rule.
        SessionEnding.inactivity => 'Signed out after '
            '${_minutes(widget.monitor.idleFor)} with no activity, so no '
            'session was left open in this browser.',
      };

  static String _minutes(Duration? idle) {
    final minutes = idle?.inMinutes ?? 0;
    if (minutes <= 0) return 'a period';
    return minutes == 1 ? '1 minute' : '$minutes minutes';
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.monitor.status;

    // Signed out and agreed to it — by asking, or by answering the dialog.
    if (!widget.hasSession && status == SessionStatus.ended) {
      return SignInScreen(notice: _arrivalNotice);
    }
    if (!widget.hasSession && !_hadSession) return const SignInScreen();

    // Everything else keeps the app on screen. Either it is working, or it has
    // just stopped working and the user is about to be told why — and pulling
    // it out from under them is the thing this gate exists to prevent.
    if (status == SessionStatus.expiredPostponed) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ExpiredBanner(onSignIn: widget.monitor.confirm),
          Expanded(child: widget.child),
        ],
      );
    }

    return widget.child;
  }
}

/// The strip that stays after someone chooses to keep reading.
///
/// Not a snackbar: this is a condition rather than an event, and it lasts until
/// they sign in. Nothing below it can load or save, so it says so in as many
/// words rather than leaving them to work it out from failures.
class _ExpiredBanner extends StatelessWidget {
  const _ExpiredBanner({required this.onSignIn});

  final Future<void> Function() onSignIn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: const Color(0xFF3A2A12),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
          child: Row(
            children: [
              const Icon(
                Icons.warning_amber_outlined,
                size: 18,
                color: Palette.minorOnInk,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Signed out. What is on screen is the last thing that '
                  'loaded — nothing here will refresh or save until you sign '
                  'in again.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Palette.minorOnInk,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              TextButton(
                onPressed: onSignIn,
                style: TextButton.styleFrom(
                  foregroundColor: Palette.minorOnInk,
                ),
                child: const Text('Sign in'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
