import 'package:flutter/foundation.dart' show kIsWeb;

/// What a device PIN actually covers here.
///
/// The same feature is worth materially different things on the two builds, and
/// the difference is not a nuance to gloss: in a browser tab the session token
/// sits in `localStorage`, readable from the developer console, so the PIN
/// cannot claim to protect it. In an installed app that storage is private to
/// the app, and the claim becomes true enough to make.
///
/// Which means one wording cannot serve both. Shipping the browser's caveat to
/// the APK would tell people their security is weaker than it is, and shipping
/// the app's to the web would tell them it is stronger — and of the two, that
/// second one is how somebody ends up leaving a laptop open.
class PinScope {
  const PinScope({required this.isBrowser});

  /// What this build actually is.
  factory PinScope.current() => const PinScope(isBrowser: kIsWeb);

  final bool isBrowser;

  /// Where the app is signed in, for a sentence about how long that lasts.
  String get container => isBrowser ? 'This browser' : 'This app';

  /// The offer made to someone who has not set a PIN.
  String get prompt => '$container stays signed in for days at a time. Set a '
      'PIN so an open ${isBrowser ? 'tab' : 'phone'} is not an open account.';

  /// What is true when a PIN is set.
  String get whenOn => 'On. This app asks for your PIN when you open it, and '
      'when you come back after leaving it a while.';

  /// What is true when one is not.
  String get whenOff => isBrowser
      ? 'Off. Anyone who opens this browser goes straight to your projects.'
      : 'Off. Anyone who picks up this phone unlocked goes straight to your '
          'projects.';

  static const heading = 'What this does and does not do';

  /// The honest account of the feature, which is the part that differs.
  String get explanation => isBrowser
      ? 'The PIN covers the screen: a laptop left open, a shared machine, a tab '
          'someone else wanders into. It is stored hashed, so nobody can read '
          'it back off this device.\n\n'
          'It is not a second factor, and it does not protect the session '
          'itself. Your sign-in token lives in this browser\'s storage, and '
          'anyone who can open the developer console can read it and use the '
          'API directly without ever seeing this lock. If a device is lost '
          'rather than merely borrowed, sign out — that is the thing that ends '
          'the session.'
      : 'The PIN covers the screen: a phone handed to someone, a device left '
          'on a desk, a session you would rather not have open behind whatever '
          'else is on screen. It is stored hashed, so nobody can read it back '
          'off this device.\n\n'
          'It sits on top of the protection the phone already gives: this '
          'app\'s storage is private to it, so unlike the web build your '
          'sign-in token is not readable by other apps or by anything you '
          'browse to. What the PIN does not survive is a device someone else '
          'controls — one that is rooted, or whose backups they can read. If a '
          'device is lost rather than merely borrowed, sign out; that is the '
          'thing that ends the session.';
}
