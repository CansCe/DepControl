import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/auth/session_monitor.dart';
import 'package:frontend/platform/app_surface.dart';
import 'package:frontend/security/app_lock.dart';
import 'package:frontend/security/pin_gate.dart';
import 'package:frontend/security/web_session_timeout.dart';

/// A monitor that records the sign-out instead of calling Supabase.
SessionMonitor recordingInto(List<String> calls) =>
    SessionMonitor(signOut: () async => calls.add('signOut'));

Future<void> pump(
  WidgetTester tester,
  Widget child, {
  required AppSurface surface,
  Duration idleLimit = const Duration(minutes: 30),
  SessionMonitor? monitor,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: WebSessionTimeout(
        surface: surface,
        idleLimit: idleLimit,
        monitor: monitor,
        child: child,
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('the PIN gate', () {
    testWidgets('never locks the browser build', (tester) async {
      // A PIN set by an older build must not lock somebody out of a version
      // that no longer offers to unlock it.
      final lock = AppLock()..lockNow();

      await tester.pumpWidget(
        MaterialApp(
          home: PinGate(
            surface: AppSurface.browser,
            lock: lock,
            userId: 'u1',
            child: const Text('the app'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('the app'), findsOneWidget);
    });
  });

  group('idle sign-out', () {
    testWidgets('does not run on the installed app', (tester) async {
      final calls = <String>[];
      await pump(
        tester,
        const Text('app'),
        surface: AppSurface.app,
        idleLimit: const Duration(minutes: 5),
        monitor: recordingInto(calls),
      );

      await tester.pump(const Duration(minutes: 10));

      // The phone has its own lock screen and keeps its PIN; signing someone
      // out for reading something else is an annoyance that buys nothing there.
      expect(calls, isEmpty);
    });

    testWidgets('signs the browser out once the limit passes', (tester) async {
      final calls = <String>[];
      final monitor = recordingInto(calls);
      await pump(
        tester,
        const Text('app'),
        surface: AppSurface.browser,
        idleLimit: const Duration(minutes: 10),
        monitor: monitor,
      );

      await tester.pump(const Duration(minutes: 11));
      await tester.pumpAndSettle();

      expect(calls, ['signOut']);
      expect(monitor.endedBy, SessionEnding.inactivity);
      // Not an expiry: nothing about the token ran out, this app made a
      // decision, and the sign-in screen has to say which.
      expect(monitor.endedByExpiry, isFalse);
      expect(monitor.idleFor, const Duration(minutes: 10));
    });

    testWidgets('warns before it does it', (tester) async {
      await pump(
        tester,
        const Text('app'),
        surface: AppSurface.browser,
        idleLimit: const Duration(minutes: 10),
        monitor: recordingInto([]),
      );

      await tester.pump(const Duration(minutes: 8, seconds: 30));
      await tester.pump();

      expect(find.textContaining('has been idle'), findsOneWidget);
      expect(find.text("I'm here"), findsOneWidget);
    });

    testWidgets('a tap puts the whole limit back', (tester) async {
      final calls = <String>[];
      await pump(
        tester,
        const Text('app'),
        surface: AppSurface.browser,
        idleLimit: const Duration(minutes: 10),
        monitor: recordingInto(calls),
      );

      // Nine minutes in, someone touches it.
      await tester.pump(const Duration(minutes: 9));
      await tester.tapAt(const Offset(200, 300));
      await tester.pump();

      // Another nine takes the original clock past its limit; the restarted
      // one has not reached it.
      await tester.pump(const Duration(minutes: 9));
      expect(calls, isEmpty);

      await tester.pump(const Duration(minutes: 2));
      await tester.pumpAndSettle();
      expect(calls, ['signOut']);
    });

    testWidgets('scrolling counts as being there', (tester) async {
      // A long report is read by scrolling and nothing else. Without this the
      // timeout fires at the reader's desk while they are looking at it.
      final calls = <String>[];
      await pump(
        tester,
        ListView(children: [for (var i = 0; i < 60; i++) Text('row $i')]),
        surface: AppSurface.browser,
        idleLimit: const Duration(minutes: 10),
        monitor: recordingInto(calls),
      );

      await tester.pump(const Duration(minutes: 9));
      await tester.drag(find.text('row 1'), const Offset(0, -200));
      await tester.pump();

      await tester.pump(const Duration(minutes: 9));
      expect(calls, isEmpty);
    });

    testWidgets('"I\'m here" dismisses the warning and keeps the session',
        (tester) async {
      final calls = <String>[];
      await pump(
        tester,
        const Text('app'),
        surface: AppSurface.browser,
        idleLimit: const Duration(minutes: 10),
        monitor: recordingInto(calls),
      );

      await tester.pump(const Duration(minutes: 8, seconds: 30));
      await tester.pump();
      await tester.tap(find.text("I'm here"));
      await tester.pumpAndSettle();

      expect(find.textContaining('has been idle'), findsNothing);

      await tester.pump(const Duration(minutes: 9));
      expect(calls, isEmpty);
    });

    testWidgets('signs out immediately when asked to', (tester) async {
      final calls = <String>[];
      await pump(
        tester,
        const Text('app'),
        surface: AppSurface.browser,
        idleLimit: const Duration(minutes: 10),
        monitor: recordingInto(calls),
      );

      await tester.pump(const Duration(minutes: 8, seconds: 30));
      await tester.pump();
      await tester.tap(find.text('Sign out now'));
      await tester.pumpAndSettle();

      expect(calls, ['signOut']);
    });
  });

  group('SessionMonitor', () {
    test('a deliberate sign-out has no reason to announce', () async {
      final monitor = recordingInto([]);
      await monitor.signOutRequested();

      expect(monitor.endedBy, isNull);
      expect(monitor.endedByExpiry, isFalse);
      expect(monitor.idleFor, isNull);
    });

    test('signing in again forgets how the last session ended', () async {
      final monitor = recordingInto([]);
      await monitor.signedOutForInactivity(const Duration(minutes: 30));
      monitor.reset();

      expect(monitor.endedBy, isNull);
      expect(monitor.idleFor, isNull);
    });

    test('an inactivity sign-out does not re-fire', () async {
      final calls = <String>[];
      final monitor = recordingInto(calls);

      await monitor.signedOutForInactivity(const Duration(minutes: 30));
      await monitor.signedOutForInactivity(const Duration(minutes: 30));

      expect(calls, ['signOut']);
    });
  });
}
