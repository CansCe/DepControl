import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// PBKDF2-HMAC-SHA256 in Dart, one 32-byte block.
///
/// The derived key is exactly the hash length, so the block loop of the full
/// algorithm collapses to a single pass — this is PBKDF2 with `dkLen == hLen`,
/// not a simplification of it.
///
/// Used on Android, which has no WebCrypto, and as the fallback for a browser
/// without a secure context. Synchronous inside: `PinStore.fallbackIterations`
/// is set low enough that this returns in roughly a tenth of a second, which is
/// cheaper than what it would take to get it off the calling thread.
///
/// An isolate via `compute` was tried and taken back out. It cannot help the
/// web at all — there is no isolate there — and on the platforms where it can,
/// it costs more than it saves: spawning one is tens of milliseconds against a
/// ~90ms derivation, and it hangs every widget test that checks a PIN, because
/// `testWidgets` drives a fake clock that real cross-isolate work never returns
/// to. If the mobile build ever wants a work factor high enough to be worth
/// moving, the better answer is Android's own `SecretKeyFactory` over a
/// platform channel — native, like WebCrypto is on the web.
Future<Uint8List> derivePbkdf2({
  required String password,
  required List<int> salt,
  required int iterations,
}) async {
  final hmac = Hmac(sha256, utf8.encode(password));
  // INT_32_BE(1): the block index PBKDF2 appends to the salt.
  var u = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
  final out = Uint8List.fromList(u);

  for (var i = 1; i < iterations; i++) {
    u = hmac.convert(u).bytes;
    for (var j = 0; j < out.length; j++) {
      out[j] ^= u[j];
    }
  }
  return out;
}

/// Whether this engine derives keys natively. False here — the caller uses it
/// to decide how hard it can afford to make the work factor.
bool get pbkdf2IsNative => false;
