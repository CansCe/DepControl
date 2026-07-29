import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/auth/auth_gate.dart';
import 'package:frontend/auth/session_monitor.dart';

/// Drives [SessionGate] the way [AuthGate] does — by rebuilding it with a new
/// `hasSession` — without standing up Supabase.
class _Harness extends StatefulWidget {
  const _Harness({
    required this.monitor,
    this.initialSession = true,
    super.key,
  });

  final SessionMonitor monitor;
  final bool initialSession;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late bool _hasSession = widget.initialSession;

  void setSession(bool value) => setState(() => _hasSession = value);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: SessionGate(
        hasSession: _hasSession,
        monitor: widget.monitor,
        child: const Scaffold(body: Center(child: Text('the app'))),
      ),
    );
  }
}

void main() {
  late int signOuts;
  late SessionMonitor monitor;

  setUp(() {
    signOuts = 0;
    monitor = SessionMonitor(signOut: () async => signOuts++);
  });

  Future<_HarnessState> pump(
    WidgetTester tester, {
    bool initialSession = true,
  }) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(
      _Harness(key: key, monitor: monitor, initialSession: initialSession),
    );
    await tester.pumpAndSettle();
    return key.currentState!;
  }

  group('a live session', () {
    testWidgets('shows the app', (tester) async {
      await pump(tester);

      expect(find.text('the app'), findsOneWidget);
      expect(find.text('Your session has expired'), findsNothing);
    });

    testWidgets('a cold start with no session goes straight to sign-in', (
      tester,
    ) async {
      await pump(tester, initialSession: false);

      // Never had one, so nothing expired — and saying so would be a lie on
      // every first visit.
      expect(find.text('Your session has expired'), findsNothing);
      expect(find.text('Sign in'), findsWidgets);
    });
  });

  group('an expired session', () {
    testWidgets('asks before it takes the screen away', (tester) async {
      await pump(tester);

      monitor.reportExpired('Token expired');
      await tester.pumpAndSettle();

      expect(find.text('Your session has expired'), findsOneWidget);
      // Still there behind the dialog. Nothing has been navigated.
      expect(find.text('the app'), findsOneWidget);
      expect(signOuts, 0);
    });

    testWidgets('passes on what the server said', (tester) async {
      await pump(tester);

      monitor.reportExpired('Token expired');
      await tester.pumpAndSettle();

      expect(find.text('Token expired'), findsOneWidget);
    });

    testWidgets('confirming signs out and shows sign-in', (tester) async {
      final harness = await pump(tester);

      monitor.reportExpired('Token expired');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign in again'));
      await tester.pumpAndSettle();

      expect(signOuts, 1);

      // Supabase clears the session, which is what the real gate sees next.
      harness.setSession(false);
      await tester.pumpAndSettle();

      expect(find.text('the app'), findsNothing);
      expect(
        find.textContaining('Your session expired'),
        findsOneWidget,
      );
    });

    testWidgets('declining keeps the screen, behind a banner', (tester) async {
      final harness = await pump(tester);

      monitor.reportExpired('Token expired');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stay on this page'));
      await tester.pumpAndSettle();
      harness.setSession(false);
      await tester.pumpAndSettle();

      expect(signOuts, 0);
      expect(find.text('the app'), findsOneWidget);
      expect(find.textContaining('nothing here will refresh'), findsOneWidget);
    });

    testWidgets('the banner still leads to sign-in', (tester) async {
      final harness = await pump(tester);

      monitor.reportExpired('Token expired');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stay on this page'));
      await tester.pumpAndSettle();
      harness.setSession(false);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(signOuts, 1);
    });

    testWidgets('a second failure does not reopen the dialog', (tester) async {
      // Parallel requests all 401 at once. One notice, not four.
      await pump(tester);

      monitor.reportExpired('Token expired');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stay on this page'));
      await tester.pumpAndSettle();

      monitor.reportExpired('Token expired');
      await tester.pumpAndSettle();

      expect(find.text('Your session has expired'), findsNothing);
    });

    testWidgets('a session that vanishes on its own is treated as expiry', (
      tester,
    ) async {
      // The idle path: no request failed, Supabase just gave up refreshing.
      final harness = await pump(tester);

      harness.setSession(false);
      await tester.pumpAndSettle();

      expect(find.text('Your session has expired'), findsOneWidget);
      expect(monitor.status, SessionStatus.expiredUnannounced);
    });
  });

  group('a deliberate sign-out', () {
    testWidgets('goes straight to sign-in with no notice', (tester) async {
      final harness = await pump(tester);

      await monitor.signOutRequested();
      await tester.pumpAndSettle();
      harness.setSession(false);
      await tester.pumpAndSettle();

      expect(signOuts, 1);
      expect(find.text('Your session has expired'), findsNothing);
      expect(find.textContaining('Your session expired'), findsNothing);
      expect(find.text('the app'), findsNothing);
    });
  });

  group('signing back in', () {
    testWidgets('clears the last session\'s ending', (tester) async {
      final harness = await pump(tester);

      await monitor.signOutRequested();
      await tester.pumpAndSettle();
      harness.setSession(false);
      await tester.pumpAndSettle();

      harness.setSession(true);
      await tester.pumpAndSettle();

      expect(monitor.status, SessionStatus.live);
      expect(find.text('the app'), findsOneWidget);
    });
  });
}
