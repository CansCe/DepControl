/// PBKDF2-HMAC-SHA256, on whichever engine this is running.
///
/// The browser has a native implementation and the Dart VM does not, and the
/// difference is not marginal: the same rounds cost tens of milliseconds
/// through WebCrypto and most of a second through a hand-rolled HMAC loop.
/// Since this app is Flutter Web, and the loop runs on the UI thread — there is
/// no isolate to move it to — that difference is the whole experience of typing
/// a PIN.
///
/// The Dart implementation stays for tests, and for the one browser case where
/// WebCrypto is missing: `crypto.subtle` only exists in a secure context, so a
/// build served over plain `http://` to anything but localhost has to fall back.
library;

export 'pbkdf2_dart.dart' if (dart.library.js_interop) 'pbkdf2_web.dart';
