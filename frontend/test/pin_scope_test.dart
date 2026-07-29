import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/security/pin_scope.dart';

void main() {
  const browser = PinScope(isBrowser: true);
  const app = PinScope(isBrowser: false);

  group('the browser build', () {
    test('says the lock can be stepped around', () {
      expect(browser.explanation, contains('developer console'));
      expect(browser.explanation, contains('does not protect the session'));
    });

    test('talks about tabs', () {
      expect(browser.prompt, contains('This browser'));
      expect(browser.prompt, contains('tab'));
      expect(browser.whenOff, contains('browser'));
    });
  });

  group('the app build', () {
    test('does not repeat a caveat that is untrue there', () {
      // The whole reason this class exists. An installed app keeps its storage
      // to itself, so the browser's warning would understate what someone has.
      expect(app.explanation, isNot(contains('developer console')));
      expect(app.explanation, isNot(contains('does not protect the session')));
      expect(app.explanation, contains('private to it'));
    });

    test('still says what the lock does not survive', () {
      // Not overselling in the other direction either.
      expect(app.explanation, contains('rooted'));
      expect(app.explanation, contains('sign out'));
    });

    test('talks about phones', () {
      expect(app.prompt, contains('This app'));
      expect(app.prompt, contains('phone'));
    });
  });

  test('both say the PIN is stored hashed', () {
    for (final scope in [browser, app]) {
      expect(scope.explanation, contains('stored hashed'));
      expect(scope.whenOn, contains('asks for your PIN'));
    }
  });
}
