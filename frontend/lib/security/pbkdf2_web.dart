import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'pbkdf2_dart.dart' as fallback;

/// PBKDF2-HMAC-SHA256 through the browser's own WebCrypto.
///
/// Same algorithm and same output as [fallback.derivePbkdf2] — this is not a
/// weaker variant chosen for speed. It is the identical derivation run by code
/// the browser ships in native form, which is why it costs tens of milliseconds
/// instead of hundreds.
Future<Uint8List> derivePbkdf2({
  required String password,
  required List<int> salt,
  required int iterations,
}) async {
  if (!pbkdf2IsNative) {
    return fallback.derivePbkdf2(
      password: password,
      salt: salt,
      iterations: iterations,
    );
  }

  final subtle = _crypto!.subtle!;

  final key = await subtle
      .importKey(
        'raw',
        Uint8List.fromList(utf8.encode(password)).toJS,
        _KeyAlgorithm(name: 'PBKDF2'),
        false,
        <JSString>['deriveBits'.toJS].toJS,
      )
      .toDart;

  final bits = await subtle
      .deriveBits(
        _Pbkdf2Params(
          name: 'PBKDF2',
          salt: Uint8List.fromList(salt).toJS,
          iterations: iterations,
          hash: 'SHA-256',
        ),
        key,
        // Bits, not bytes: 32 bytes of derived key.
        256,
      )
      .toDart;

  return bits.toDart.asUint8List();
}

/// Whether WebCrypto is actually here.
///
/// `crypto.subtle` is only defined in a secure context — https, or localhost.
/// A build served over plain http to a LAN address has `crypto` and no
/// `subtle`, and reading through it would throw rather than degrade, so the
/// check is for the property rather than for the protocol.
bool get pbkdf2IsNative => _crypto?.subtle != null;

@JS('crypto')
external _Crypto? get _crypto;

extension type _Crypto._(JSObject _) implements JSObject {
  external _SubtleCrypto? get subtle;
}

extension type _SubtleCrypto._(JSObject _) implements JSObject {
  external JSPromise<JSObject> importKey(
    String format,
    JSUint8Array keyData,
    JSObject algorithm,
    bool extractable,
    JSArray<JSString> keyUsages,
  );

  external JSPromise<JSArrayBuffer> deriveBits(
    JSObject algorithm,
    JSObject baseKey,
    int length,
  );
}

extension type _KeyAlgorithm._(JSObject _) implements JSObject {
  external factory _KeyAlgorithm({String name});
}

extension type _Pbkdf2Params._(JSObject _) implements JSObject {
  external factory _Pbkdf2Params({
    String name,
    JSUint8Array salt,
    int iterations,
    String hash,
  });
}
