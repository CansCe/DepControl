import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/security/pin_prompt.dart';
import 'package:frontend/security/pin_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<PinStore> emptyStore() async {
  SharedPreferences.setMockInitialValues({});
  return PinStore(prefs: await SharedPreferences.getInstance());
}

Future<void> pumpPrompt(
  WidgetTester tester, {
  required PinStore store,
  String? userId = 'user-1',
  VoidCallback? onSetUp,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PinPrompt(
          store: store,
          userId: userId,
          onSetUp: onSetUp ?? () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('offers a PIN to someone who has none', (tester) async {
    await pumpPrompt(tester, store: await emptyStore());

    expect(find.text('Set a PIN'), findsOneWidget);
    expect(find.textContaining('stays signed in for days'), findsOneWidget);
  });

  testWidgets('says nothing to someone who already set one', (tester) async {
    final store = await emptyStore();
    await store.setPin('4820', userId: 'user-1');

    await pumpPrompt(tester, store: store);

    expect(find.text('Set a PIN'), findsNothing);
  });

  testWidgets('still offers when the stored PIN is another account\'s', (
    tester,
  ) async {
    // Otherwise the second person to use a machine is silently left without
    // one, on the strength of a PIN that does nothing for them.
    final store = await emptyStore();
    await store.setPin('4820', userId: 'user-1');

    await pumpPrompt(tester, store: store, userId: 'user-2');

    expect(find.text('Set a PIN'), findsOneWidget);
  });

  testWidgets('asks once', (tester) async {
    final store = await emptyStore();
    await pumpPrompt(tester, store: store);

    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(find.text('Set a PIN'), findsNothing);

    // And still nothing on the next visit.
    await pumpPrompt(tester, store: store);
    expect(find.text('Set a PIN'), findsNothing);
  });

  testWidgets('takes the willing to where a PIN is set', (tester) async {
    var opened = 0;
    await pumpPrompt(
      tester,
      store: await emptyStore(),
      onSetUp: () => opened++,
    );

    await tester.tap(find.text('Set a PIN'));
    await tester.pump();

    expect(opened, 1);
  });
}
