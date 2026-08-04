import 'package:backend/src/services/idle_watchdog.dart';
import 'package:test/test.dart';

void main() {
  group('IdleWatchdog', () {
    /// Builds a watchdog whose clocks are short enough to test against, and
    /// records whether it decided to stop the machine.
    ({IdleWatchdog watchdog, List<int> exits}) watchdogFor(
      Future<int> Function() pendingWork, {
      Duration idleAfter = const Duration(milliseconds: 20),
      Duration unreadableGrace = const Duration(milliseconds: 60),
      bool Function()? localWork,
    }) {
      final exits = <int>[];
      final watchdog = IdleWatchdog(
        pendingWork: pendingWork,
        localWork: localWork ?? () => false,
        idleAfter: idleAfter,
        unreadableGrace: unreadableGrace,
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

    group('when the queue cannot be read', () {
      test('stays up at first, in case it is a blip', () async {
        final subject = watchdogFor(
          () async => throw StateError('no database'),
          unreadableGrace: const Duration(seconds: 30),
        );
        addTearDown(subject.watchdog.stop);

        subject.watchdog.start();
        await Future<void>.delayed(const Duration(milliseconds: 120));

        expect(subject.exits, isEmpty);
      });

      // The bug this replaced: an unreadable queue meant "stay up", full stop.
      // A missing table never comes back, so the machine ran for ever and said
      // so only as a bill — the one outcome the watchdog exists to prevent.
      test('stops once it is clearly not a blip', () async {
        final subject = watchdogFor(
          () async => throw StateError('relation "scan_jobs" does not exist'),
          unreadableGrace: const Duration(milliseconds: 50),
        );
        addTearDown(subject.watchdog.stop);

        subject.watchdog.start();
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(subject.exits, [0]);
      });

      // The safety this trades against, and the reason the local check comes
      // first: a scan running *here* is work that stopping would destroy, and
      // knowing about it depends on nothing that can fail.
      test('never stops while a scan is running here', () async {
        final subject = watchdogFor(
          () async => throw StateError('relation "scan_jobs" does not exist'),
          unreadableGrace: const Duration(milliseconds: 20),
          localWork: () => true,
        );
        addTearDown(subject.watchdog.stop);

        subject.watchdog.start();
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(subject.exits, isEmpty);
      });

      test('a queue that comes back resets the patience', () async {
        var broken = true;
        final subject = watchdogFor(
          () async {
            if (broken) throw StateError('briefly away');
            return 1;
          },
          unreadableGrace: const Duration(milliseconds: 50),
        );
        addTearDown(subject.watchdog.stop);

        subject.watchdog.start();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        broken = false;
        await Future<void>.delayed(const Duration(milliseconds: 40));
        broken = true;

        // Without the reset, the two outages would add up to more than the
        // grace and stop a machine that had been answering in between.
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(subject.exits, isEmpty);
      });
    });

    test('a scan running here keeps the machine up on its own', () async {
      final subject = watchdogFor(() async => 0, localWork: () => true);
      addTearDown(subject.watchdog.stop);

      subject.watchdog.start();
      await Future<void>.delayed(const Duration(milliseconds: 120));

      // The queue says nothing is outstanding — which it would, for a job this
      // machine has already claimed and is part-way through.
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
