import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'sign_in_screen.dart';

/// Chooses between [SignInScreen] and the signed-in app based on the live
/// Supabase auth state.
///
/// Listening to `onAuthStateChange` rather than reading `currentSession` once
/// means a sign-out, a token refresh failure, or a session restored from
/// storage all move the UI without any screen having to navigate.
class AuthGate extends StatelessWidget {
  const AuthGate({required this.child, super.key});

  /// Shown once a session exists.
  final Widget child;

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

        return session == null ? const SignInScreen() : child;
      },
    );
  }
}
