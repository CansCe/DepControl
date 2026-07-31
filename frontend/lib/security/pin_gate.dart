import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/session_monitor.dart';
import '../platform/app_surface.dart';
import 'app_lock.dart';
import 'pin_lock_screen.dart';
import 'pin_store.dart';

/// Puts [child] behind the device PIN when there is one.
///
/// Sits *inside* the auth gate rather than beside it: the PIN guards a session
/// that already exists, and there is nothing for it to lock when nobody is
/// signed in.
///
/// **Not on the browser build.** The feature was always worth less there, and
/// [PinScope] has said so in as many words since it was written: the session
/// token lives in the same `localStorage` the PIN's own hash does, so anyone
/// who can open the developer console reads the token and calls the API without
/// ever meeting this lock. What it bought was a cover over the screen; what it
/// cost was a second secret to forget, on the one surface where forgetting it
/// is most likely because the browser is not the thing people carry.
///
/// The risk it was aimed at — a signed-in tab left open on a shared machine —
/// is now handled by ending the session after a period of inactivity, which
/// unlike a screen lock actually ends something. See `WebSessionTimeout`.
class PinGate extends StatefulWidget {
  const PinGate({
    required this.child,
    this.lock,
    this.userId,
    this.email,
    this.onForgotten,
    this.surface,
    super.key,
  });

  final Widget child;

  /// Which build this is. Defaults to the real one; a widget test runs on
  /// neither platform and passes a value.
  final AppSurface? surface;

  /// Defaults to the app-wide lock; injectable for tests.
  final AppLock? lock;

  /// Who is signed in. Defaults to the Supabase session, so callers in the app
  /// pass nothing; tests pass a value and stay clear of Supabase.
  final String? userId;
  final String? email;

  /// What "forgot your PIN" does. Defaults to clearing it and signing out.
  final Future<void> Function()? onForgotten;

  @override
  State<PinGate> createState() => _PinGateState();
}

class _PinGateState extends State<PinGate> {
  late final AppLock _lock = widget.lock ?? AppLock.instance;
  late final AppSurface _surface = widget.surface ?? AppSurface.current();

  @override
  void initState() {
    super.initState();
    // Never armed in a browser, so a PIN set by an older build of this app
    // cannot lock somebody out of a feature that no longer offers to unlock it.
    // The stored hash is left alone rather than deleted: it is inert here, and
    // it is the same account's PIN on the installed app, which still uses it.
    if (!_surface.isBrowser) _lock.bind(widget.userId ?? _currentUserId);
  }

  @override
  void dispose() {
    // Signing out ends the binding, so signing back in is a fresh decision and
    // locks again rather than dropping someone straight into the app.
    if (!_surface.isBrowser) _lock.unbind();
    super.dispose();
  }

  String? get _currentUserId {
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      // No Supabase in this build — a test, or a widget preview. Nothing to
      // lock to, which the lock reads as "not armed".
      return null;
    }
  }

  String? get _email {
    if (widget.email != null) return widget.email;
    try {
      return Supabase.instance.client.auth.currentUser?.email;
    } catch (_) {
      return null;
    }
  }

  Future<void> _forgotten() async {
    if (widget.onForgotten case final handler?) return handler();
    await PinStore().clear();
    await _lock.refresh();
    await SessionMonitor.instance.signOutRequested();
  }

  @override
  Widget build(BuildContext context) {
    // Straight through in a browser — not even a listener, so nothing here can
    // put a lock screen up on a build that offers no way to set one.
    if (_surface.isBrowser) return widget.child;

    return AnimatedBuilder(
      animation: _lock,
      builder: (context, child) => _lock.isLocked
          ? PinLockScreen(
              lock: _lock,
              email: _email,
              onForgotten: _forgotten,
            )
          : child!,
      child: widget.child,
    );
  }
}
