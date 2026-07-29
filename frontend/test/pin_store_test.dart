import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/security/pin_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Deterministic salt, so a test can assert two stores disagree about a PIN
/// for the right reason rather than because the salts differed.
class _FixedRandom implements Random {
  _FixedRandom(this.value);
  final int value;

  @override
  int nextInt(int max) => value % max;
  @override
  bool nextBool() => false;
  @override
  double nextDouble() => 0;
}

/// Fewer rounds would be nice, but the count is baked into the stored record
/// and read back from it — using the real one keeps the test honest about what
/// unlocking costs.
Future<PinStore> store({Random? random}) async {
  SharedPreferences.setMockInitialValues({});
  return PinStore(prefs: await SharedPreferences.getInstance(), random: random);
}

void main() {
  group('validate', () {
    test('accepts an ordinary PIN', () {
      expect(PinStore.validate('4820'), isNull);
      expect(PinStore.validate('918273'), isNull);
    });

    test('rejects one that is too short or too long', () {
      expect(PinStore.validate('123'), isNotNull);
      expect(PinStore.validate('129384756'), isNotNull);
    });

    test('rejects anything that is not digits', () {
      expect(PinStore.validate('12a4'), isNotNull);
    });

    test('rejects a repeated digit and a run', () {
      expect(PinStore.validate('1111'), contains('same digit'));
      expect(PinStore.validate('1234'), contains('run of digits'));
      expect(PinStore.validate('9876'), contains('run of digits'));
    });
  });

  group('setPin', () {
    test('records that a PIN exists, and who for', () async {
      final pins = await store();
      expect((await pins.read()).isSet, isFalse);

      await pins.setPin('4820', userId: 'user-1');
      final state = await pins.read();

      expect(state.isSet, isTrue);
      expect(state.userId, 'user-1');
      expect(state.setAt, isNotNull);
      expect(state.appliesTo('user-1'), isTrue);
      // Someone else's PIN must not lock this account out of its own session.
      expect(state.appliesTo('user-2'), isFalse);
      expect(state.appliesTo(null), isFalse);
    });

    test('stores neither the PIN nor anything that looks like it', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await PinStore(prefs: prefs).setPin('4820', userId: 'user-1');

      for (final key in prefs.getKeys()) {
        expect(prefs.get(key).toString(), isNot(contains('4820')));
      }
    });

    test('salts, so the same PIN does not store the same hash', () async {
      SharedPreferences.setMockInitialValues({});
      final first = await SharedPreferences.getInstance();
      await PinStore(prefs: first, random: _FixedRandom(7))
          .setPin('4820', userId: 'u');
      final a = first.getString('pin.hash');

      SharedPreferences.setMockInitialValues({});
      final second = await SharedPreferences.getInstance();
      await PinStore(prefs: second, random: _FixedRandom(200))
          .setPin('4820', userId: 'u');

      expect(second.getString('pin.hash'), isNot(a));
    });

    test('refuses a PIN that would not validate', () async {
      final pins = await store();
      expect(
        () => pins.setPin('1111', userId: 'u'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('answers the prompt — nobody needs offering what they just set',
        () async {
      final pins = await store();
      await pins.setPin('4820', userId: 'u');

      expect((await pins.read()).hasDeclinedPrompt('u'), isTrue);
      // Only for them. Somebody else on this browser has not been asked.
      expect((await pins.read()).hasDeclinedPrompt('other'), isFalse);
    });
  });

  group('verify', () {
    test('accepts the right PIN and refuses the wrong one', () async {
      final pins = await store();
      await pins.setPin('4820', userId: 'u');

      expect((await pins.verify('4820')).ok, isTrue);
      expect((await pins.verify('4821')).ok, isFalse);
    });

    test('refuses everything when no PIN is set', () async {
      final pins = await store();
      expect((await pins.verify('4820')).ok, isFalse);
    });

    test('counts wrong tries and clears them on a right one', () async {
      final pins = await store();
      await pins.setPin('4820', userId: 'u');

      await pins.verify('0000');
      expect((await pins.verify('0000')).failures, 2);

      expect((await pins.verify('4820')).ok, isTrue);
      expect((await pins.read()).failures, 0);
    });

    test('starts making the user wait after a run of wrong tries', () async {
      final pins = await store();
      await pins.setPin('4820', userId: 'u');

      for (var i = 0; i < PinStore.attemptsBeforeDelay; i++) {
        expect((await pins.verify('0000')).isLockedOut, isFalse);
      }

      final locked = await pins.verify('0000');
      expect(locked.isLockedOut, isTrue);
      expect(locked.retryIn.inSeconds, greaterThan(0));

      // And the right PIN does not get through the wait either — otherwise the
      // delay would be no obstacle to whoever is guessing.
      final duringLockout = await pins.verify('4820');
      expect(duringLockout.ok, isFalse);
      expect(duringLockout.isLockedOut, isTrue);
    });

    test('the wait grows and then stops growing', () {
      expect(PinStore.lockoutAfter(1), Duration.zero);
      expect(PinStore.lockoutAfter(PinStore.attemptsBeforeDelay), Duration.zero);
      expect(
        PinStore.lockoutAfter(PinStore.attemptsBeforeDelay + 1),
        const Duration(seconds: 30),
      );
      expect(
        PinStore.lockoutAfter(PinStore.attemptsBeforeDelay + 2),
        const Duration(seconds: 60),
      );
      expect(PinStore.lockoutAfter(40), PinStore.maxLockout);
    });
  });

  group('clear', () {
    test('leaves nothing to check against', () async {
      final pins = await store();
      await pins.setPin('4820', userId: 'u');
      await pins.clear();

      final state = await pins.read();
      expect(state.isSet, isFalse);
      expect(state.appliesTo('u'), isFalse);
      expect((await pins.verify('4820')).ok, isFalse);
    });

    test('does not un-answer the prompt', () async {
      // Removing a PIN is a decision about PINs. Offering one again straight
      // afterwards would be arguing with it.
      final pins = await store();
      await pins.setPin('4820', userId: 'u');
      await pins.clear();

      expect((await pins.read()).hasDeclinedPrompt('u'), isTrue);
    });
  });

  group('dismissPrompt', () {
    test('is remembered, per account', () async {
      final pins = await store();
      expect((await pins.read()).hasDeclinedPrompt('u'), isFalse);

      await pins.dismissPrompt('u');
      expect((await pins.read()).hasDeclinedPrompt('u'), isTrue);
      expect((await pins.read()).hasDeclinedPrompt('other'), isFalse);
    });

    test('remembers more than one', () async {
      final pins = await store();
      await pins.dismissPrompt('u');
      await pins.dismissPrompt('other');

      final state = await pins.read();
      expect(state.hasDeclinedPrompt('u'), isTrue);
      expect(state.hasDeclinedPrompt('other'), isTrue);
    });
  });

  group('PinState', () {
    test('reports a lockout that has not run out yet', () {
      final state = PinState(
        isSet: true,
        userId: 'u',
        lockedUntil: DateTime.now().add(const Duration(seconds: 30)),
      );

      expect(state.isLockedOut, isTrue);
      expect(state.lockoutRemaining.inSeconds, greaterThan(25));
    });

    test('a lockout in the past is over', () {
      final state = PinState(
        isSet: true,
        lockedUntil: DateTime.now().subtract(const Duration(seconds: 1)),
      );

      expect(state.isLockedOut, isFalse);
      expect(state.lockoutRemaining, Duration.zero);
    });
  });
}
