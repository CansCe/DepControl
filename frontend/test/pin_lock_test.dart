import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/security/app_lock.dart';
import 'package:frontend/security/pin_gate.dart';
import 'package:frontend/security/pin_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<PinStore> emptyStore() async {
  SharedPreferences.setMockInitialValues({});
  return PinStore(prefs: await SharedPreferences.getInstance());
}

/// A store with `4820` already set for [userId].
Future<PinStore> storeWithPin({String userId = 'user-1'}) async {
  final store = await emptyStore();
  await store.setPin('4820', userId: userId);
  return store;
}

Future<void> pumpGate(
  WidgetTester tester, {
  required AppLock lock,
  String? userId = 'user-1',
  Future<void> Function()? onForgotten,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: PinGate(
        lock: lock,
        userId: userId,
        email: 'dev@example.com',
        onForgotten: onForgotten ?? () async {},
        child: const Scaffold(body: Center(child: Text('the app'))),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('AppLock', () {
    test('locks on entry when the signed-in user has a PIN', () async {
      final lock = AppLock(store: await storeWithPin());
      await lock.bind('user-1');

      expect(lock.isLocked, isTrue);
      expect(lock.isArmed, isTrue);
    });

    test('stays open when there is no PIN', () async {
      final lock = AppLock(store: await emptyStore());
      await lock.bind('user-1');

      expect(lock.isLocked, isFalse);
      expect(lock.isArmed, isFalse);
    });

    test('does not lock a different account out with someone else\'s PIN',
        () async {
      final lock = AppLock(store: await storeWithPin(userId: 'user-1'));
      await lock.bind('user-2');

      expect(lock.isLocked, isFalse);
    });

    test('the right PIN lifts it; a wrong one does not', () async {
      final lock = AppLock(store: await storeWithPin());
      await lock.bind('user-1');

      expect((await lock.unlock('0000')).ok, isFalse);
      expect(lock.isLocked, isTrue);

      expect((await lock.unlock('4820')).ok, isTrue);
      expect(lock.isLocked, isFalse);
    });

    test('locks again on request', () async {
      final lock = AppLock(store: await storeWithPin());
      await lock.bind('user-1');
      await lock.unlock('4820');

      lock.lockNow();
      expect(lock.isLocked, isTrue);
    });

    test('will not lock when there is no PIN to unlock it with', () async {
      final lock = AppLock(store: await emptyStore());
      await lock.bind('user-1');

      lock.lockNow();
      expect(lock.isLocked, isFalse);
    });

    test('re-reads after the PIN is removed', () async {
      final store = await storeWithPin();
      final lock = AppLock(store: store);
      await lock.bind('user-1');
      await lock.unlock('4820');

      await store.clear();
      await lock.refresh();

      expect(lock.isArmed, isFalse);
      lock.lockNow();
      expect(lock.isLocked, isFalse);
    });

    test('signing out unbinds, so signing back in locks again', () async {
      final lock = AppLock(store: await storeWithPin());
      await lock.bind('user-1');
      await lock.unlock('4820');
      expect(lock.isLocked, isFalse);

      lock.unbind();
      await lock.bind('user-1');

      expect(lock.isLocked, isTrue);
    });

    group('coming back to the tab', () {
      testWidgets('locks after a long absence', (tester) async {
        final lock = AppLock(
          store: await storeWithPin(),
          awayBeforeLock: Duration.zero,
        );
        await lock.bind('user-1');
        await lock.unlock('4820');

        lock.didChangeAppLifecycleState(AppLifecycleState.hidden);
        lock.didChangeAppLifecycleState(AppLifecycleState.resumed);

        expect(lock.isLocked, isTrue);
      });

      testWidgets('does not lock after a short one', (tester) async {
        final lock = AppLock(
          store: await storeWithPin(),
          awayBeforeLock: const Duration(hours: 1),
        );
        await lock.bind('user-1');
        await lock.unlock('4820');

        lock.didChangeAppLifecycleState(AppLifecycleState.hidden);
        lock.didChangeAppLifecycleState(AppLifecycleState.resumed);

        expect(lock.isLocked, isFalse);
      });

      testWidgets('losing focus alone is not being away', (tester) async {
        // `inactive` fires when another window is clicked. Locking on it would
        // make the app unusable next to an editor.
        final lock = AppLock(
          store: await storeWithPin(),
          awayBeforeLock: Duration.zero,
        );
        await lock.bind('user-1');
        await lock.unlock('4820');

        lock.didChangeAppLifecycleState(AppLifecycleState.inactive);
        lock.didChangeAppLifecycleState(AppLifecycleState.resumed);

        expect(lock.isLocked, isFalse);
      });
    });
  });

  group('PinGate', () {
    testWidgets('shows the app when nothing is set', (tester) async {
      await pumpGate(tester, lock: AppLock(store: await emptyStore()));

      expect(find.text('the app'), findsOneWidget);
    });

    testWidgets('covers the app with the lock screen', (tester) async {
      await pumpGate(tester, lock: AppLock(store: await storeWithPin()));

      expect(find.text('the app'), findsNothing);
      expect(find.text('Enter your PIN.'), findsOneWidget);
      // Says whose session it is holding, so the screen is not a mystery box.
      expect(find.textContaining('dev@example.com'), findsOneWidget);
    });

    testWidgets('the right PIN gets through', (tester) async {
      await pumpGate(tester, lock: AppLock(store: await storeWithPin()));

      await tester.enterText(find.byType(TextField), '4820');
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();

      expect(find.text('the app'), findsOneWidget);
    });

    testWidgets('a wrong PIN says how many tries are left', (tester) async {
      await pumpGate(tester, lock: AppLock(store: await storeWithPin()));

      await tester.enterText(find.byType(TextField), '0000');
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();

      expect(find.text('the app'), findsNothing);
      expect(find.textContaining('Wrong PIN'), findsOneWidget);
      expect(find.textContaining('4 tries'), findsOneWidget);
    });

    testWidgets('a forgotten PIN can be traded for signing out', (
      tester,
    ) async {
      var forgotten = 0;
      await pumpGate(
        tester,
        lock: AppLock(store: await storeWithPin()),
        onForgotten: () async => forgotten++,
      );

      await tester.tap(find.text('Forgot your PIN?'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove PIN and sign out'));
      await tester.pumpAndSettle();

      expect(forgotten, 1);
    });

    testWidgets('backing out of that leaves the lock on', (tester) async {
      var forgotten = 0;
      await pumpGate(
        tester,
        lock: AppLock(store: await storeWithPin()),
        onForgotten: () async => forgotten++,
      );

      await tester.tap(find.text('Forgot your PIN?'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(forgotten, 0);
      expect(find.text('Enter your PIN.'), findsOneWidget);
    });
  });
}
