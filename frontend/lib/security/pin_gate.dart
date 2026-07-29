import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/session_monitor.dart';
import 'app_lock.dart';
import 'pin_lock_screen.dart';
import 'pin_store.dart';

/// Puts [child] behind the device PIN when there is one.
///
/// Sits *inside* the auth gate rather than beside it: the PIN guards a session
/// that already exists, and there is nothing for it to lock when nobody is
/// signed in.
class PinGate extends StatefulWidget {
  const PinGate({
    required this.child,
    this.lock,
    this.userId,
    this.email,
    this.onForgotten,
    super.key,
  });

  final Widget child;

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

  @override
  void initState() {
    super.initState();
    _lock.bind(widget.userId ?? _currentUserId);
  }

  @override
  void dispose() {
    // Signing out ends the binding, so signing back in is a fresh decision and
    // locks again rather than dropping someone straight into the app.
    _lock.unbind();
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
