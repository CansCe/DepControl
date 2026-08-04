import 'package:backend/src/services/idle_watchdog.dart';
import 'package:test/test.dart';

void main() {
  group('IdleWatchdog', () {
    /// Builds a watchdog whose clocks are short enough to test against, and
    /// records whether it decided to stop the machine.
    ({IdleWatchdog watchdog, List<int> exits}) watchdogFor(
      Future<int> Function() pendingWork, {
      Duration idleAfter = const Duration(milliseconds: 20),
    }) {
      final exits = <int>[];
      final watchdog = IdleWatchdog(
        pendingWork: pendingWork,
        idleAfter: idleAfter,
        checkInterval: const Duration(milliseconds: 10),
        exit: exits.add,
      );
      return (watchdog: watchdog, exits: exits);
    }

    // The one whose absence is silent, and the whole point of the phase: a
    // machine that stops here takes a running scan with it, and the only
    // symptom is a scan that never finishes.
    test('does not stop the machine while a scan is outstanding', () async {
      final subject = watchdogFor(() async => 1);
      addTearDown(subject.watchdog.stop);

      subject.watchdog.start();
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(subject.exits, isEmpty);
    });

    test('stops once the queue is empty and nobody has asked for anything',
        () async {
      final subject = watchdogFor(() async => 0);
      addTearDown(subject.watchdog.stop);

      subject.watchdog.start();
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(subject.exits, [0]);
    });

    test('stops as soon as the queue drains, not an idle window later',
        () async {
      var pending = 1;
      final subject = watchdogFor(() async => pending);
      addTearDown(subject.watchdog.stop);

      subject.watchdog.start();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(subject.exits, isEmpty);

      // Outstanding work holds the machine up; it must not also *reset* the
      // idle clock, or a scan that finished with nobody watching would keep the
      // machine awake for another full window for no reason.
      pending = 0;
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(subject.exits, [0]);
    });

    test('a request keeps the machine up', () async {
      final subject = watchdogFor(
        () async => 0,
        idleAfter: const Duration(milliseconds: 60),
      );
      addTearDown(subject.watchdog.stop);

      subject.watchdog.start();
      for (var i = 0; i < 6; i++) {
        subject.watchdog.touch();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(subject.exits, isEmpty);
    });

    test('stays up when it cannot tell whether there is work', () async {
      final subject = watchdogFor(() async => throw StateError('no database'));
      addTearDown(subject.watchdog.stop);

      subject.watchdog.start();
      await Future<void>.delayed(const Duration(milliseconds: 120));

      // Staying up costs money. Stopping on top of a running scan costs the
      // scan, and the scan is what somebody is waiting for.
      expect(subject.exits, isEmpty);
    });

    group('configuration', () {
      test('is off unless asked for', () {
        expect(IdleWatchdog.idleFromEnvironment({}), isNull);
        expect(
          IdleWatchdog.idleFromEnvironment({'IDLE_SHUTDOWN_SECONDS': '0'}),
          isNull,
        );
        expect(
          IdleWatchdog.idleFromEnvironment({'IDLE_SHUTDOWN_SECONDS': 'soon'}),
          isNull,
        );
      });

      test('reads seconds', () {
        expect(
          IdleWatchdog.idleFromEnvironment({'IDLE_SHUTDOWN_SECONDS': '300'}),
          const Duration(minutes: 5),
        );
      });
    });
  });
}
