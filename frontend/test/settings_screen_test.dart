import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/screens/settings_screen.dart';
import 'package:frontend/security/app_lock.dart';
import 'package:frontend/security/pin_scope.dart';
import 'package:frontend/security/pin_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<PinStore> emptyStore() async {
  SharedPreferences.setMockInitialValues({});
  return PinStore(prefs: await SharedPreferences.getInstance());
}

Future<void> pumpSettings(
  WidgetTester tester, {
  required PinStore store,
  AppLock? lock,
  DateTime? expiresAt,
  PinScope? scope,
  Future<void> Function()? onSignOut,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: SettingsScreen(
        email: 'dev@example.com',
        userId: 'user-1',
        sessionExpiresAt: expiresAt,
        store: store,
        lock: lock ?? AppLock(store: store),
        scope: scope,
        onSignOut: onSignOut ?? () async {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Types [value] into the field labelled [label].
Future<void> fill(WidgetTester tester, String label, String value) async {
  await tester.enterText(
    find.ancestor(of: find.text(label), matching: find.byType(TextField)).first,
    value,
  );
}

void main() {
  group('the session card', () {
    testWidgets('prints when the token actually runs out', (tester) async {
      await pumpSettings(
        tester,
        store: await emptyStore(),
        expiresAt: DateTime.now().add(const Duration(days: 7)),
      );

      expect(find.textContaining('good until'), findsOneWidget);
      expect(find.textContaining('7 days from now'), findsOneWidget);
    });

    testWidgets('says so when there is nothing to report', (tester) async {
      await pumpSettings(tester, store: await emptyStore());

      expect(find.textContaining('No session token'), findsOneWidget);
    });
  });

  group('the PIN card', () {
    testWidgets('offers one when none is set', (tester) async {
      await pumpSettings(tester, store: await emptyStore());

      expect(find.textContaining('Off.'), findsOneWidget);
      expect(find.text('Set a PIN'), findsOneWidget);
      expect(find.text('Change PIN'), findsNothing);
    });

    testWidgets('tells a browser the lock can be stepped around', (
      tester,
    ) async {
      await pumpSettings(
        tester,
        store: await emptyStore(),
        scope: const PinScope(isBrowser: true),
      );

      expect(
        find.textContaining('does not protect the session itself'),
        findsOneWidget,
      );
      expect(find.textContaining('developer console'), findsOneWidget);
    });

    testWidgets('does not tell the app build the same thing', (tester) async {
      // The browser's caveat is false in an installed app, where the token is
      // in storage private to it. Saying it anyway would be understating
      // someone's security, which is its own kind of wrong answer.
      await pumpSettings(
        tester,
        store: await emptyStore(),
        scope: const PinScope(isBrowser: false),
      );

      expect(find.textContaining('developer console'), findsNothing);
      expect(find.textContaining('private to it'), findsOneWidget);
      // Still says what it does not survive, rather than overselling instead.
      expect(find.textContaining('rooted'), findsOneWidget);
    });

    testWidgets('sets one', (tester) async {
      final store = await emptyStore();
      await pumpSettings(tester, store: store);

      await tester.tap(find.text('Set a PIN'));
      await tester.pumpAndSettle();
      await fill(tester, 'New PIN', '4820');
      await fill(tester, 'Repeat it', '4820');
      await tester.tap(find.text('Set PIN'));
      await tester.pumpAndSettle();

      final state = await store.read();
      expect(state.appliesTo('user-1'), isTrue);
      expect((await store.verify('4820')).ok, isTrue);

      // And the card now offers the things you do to an existing PIN.
      expect(find.text('Change PIN'), findsOneWidget);
      expect(find.text('Lock now'), findsOneWidget);
    });

    testWidgets('refuses two that do not match', (tester) async {
      final store = await emptyStore();
      await pumpSettings(tester, store: store);

      await tester.tap(find.text('Set a PIN'));
      await tester.pumpAndSettle();
      await fill(tester, 'New PIN', '4820');
      await fill(tester, 'Repeat it', '4821');
      await tester.tap(find.text('Set PIN'));
      await tester.pumpAndSettle();

      expect(find.text('The two PINs do not match.'), findsOneWidget);
      expect((await store.read()).isSet, isFalse);
    });

    testWidgets('refuses a PIN not worth having', (tester) async {
      final store = await emptyStore();
      await pumpSettings(tester, store: store);

      await tester.tap(find.text('Set a PIN'));
      await tester.pumpAndSettle();
      await fill(tester, 'New PIN', '1234');
      await fill(tester, 'Repeat it', '1234');
      await tester.tap(find.text('Set PIN'));
      await tester.pumpAndSettle();

      expect(find.textContaining('run of digits'), findsOneWidget);
      expect((await store.read()).isSet, isFalse);
    });

    testWidgets('changing asks for the current one first', (tester) async {
      final store = await emptyStore();
      await store.setPin('4820', userId: 'user-1');
      await pumpSettings(tester, store: store);

      await tester.tap(find.text('Change PIN'));
      await tester.pumpAndSettle();
      await fill(tester, 'Current PIN', '0000');
      await fill(tester, 'New PIN', '5931');
      await fill(tester, 'Repeat it', '5931');
      await tester.tap(find.text('Change PIN').last);
      await tester.pumpAndSettle();

      expect(find.text('That is not your current PIN.'), findsOneWidget);
      expect((await store.verify('4820')).ok, isTrue);
    });

    testWidgets('changing works with the current one', (tester) async {
      final store = await emptyStore();
      await store.setPin('4820', userId: 'user-1');
      await pumpSettings(tester, store: store);

      await tester.tap(find.text('Change PIN'));
      await tester.pumpAndSettle();
      await fill(tester, 'Current PIN', '4820');
      await fill(tester, 'New PIN', '5931');
      await fill(tester, 'Repeat it', '5931');
      await tester.tap(find.text('Change PIN').last);
      await tester.pumpAndSettle();

      expect((await store.verify('5931')).ok, isTrue);
      expect((await store.verify('4820')).ok, isFalse);
    });

    testWidgets('removing needs the current one too', (tester) async {
      final store = await emptyStore();
      await store.setPin('4820', userId: 'user-1');
      await pumpSettings(tester, store: store);

      await tester.tap(find.text('Remove PIN'));
      await tester.pumpAndSettle();
      await fill(tester, 'Current PIN', '4820');
      await tester.tap(find.text('Remove PIN').last);
      await tester.pumpAndSettle();

      expect((await store.read()).isSet, isFalse);
      expect(find.text('Set a PIN'), findsOneWidget);
    });
  });

  testWidgets('signs out', (tester) async {
    var signOuts = 0;
    await pumpSettings(
      tester,
      store: await emptyStore(),
      onSignOut: () async => signOuts++,
    );

    await tester.ensureVisible(find.text('Sign out'));
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    expect(signOuts, 1);
  });
}
