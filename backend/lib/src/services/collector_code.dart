import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Pairing codes for the local collector — see phase 1.6 in the roadmap.
///
/// A code is a bearer credential, single-use and short-lived, that lets the
/// collector binary submit one bundle without ever holding a Supabase JWT.
/// 128 bits of [Random.secure] entropy, rendered in Crockford base32 (no
/// I/L/O/U, so it survives being read aloud or misheard) as four groups of
/// four — `XXXX-XXXX-XXXX-XXXX` — copied whole by the web page rather than
/// typed, but readable if it has to travel by voice or by hand.
class CollectorCode {
  CollectorCode._();

  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  /// A fresh code. The plaintext exists only for the moment the mint route
  /// returns it — nothing past that point keeps it, only [hash] of it.
  static String generate({Random? random}) {
    final rng = random ?? Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return _group(_base32(bytes));
  }

  /// The stored form: SHA-256 over the [normalize]d code. Never the code
  /// itself — a dump of `collector_sessions` is then a set of dead rows, not
  /// a set of live grants.
  static String hash(String rawCode) =>
      sha256.convert(utf8.encode(normalize(rawCode))).toString();

  /// Folds what a human might mistype before hashing or comparing: case,
  /// dashes and whitespace, and Crockford's own confusable-letter mapping.
  /// [generate] never produces an O, I or L, but a person copying a code by
  /// hand might still write one down.
  static String normalize(String raw) {
    final stripped = raw.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
    return stripped
        .replaceAll('O', '0')
        .replaceAll('I', '1')
        .replaceAll('L', '1');
  }

  static String _base32(List<int> bytes) {
    var buffer = 0;
    var bitsLeft = 0;
    final out = StringBuffer();
    for (final byte in bytes) {
      buffer = (buffer << 8) | byte;
      bitsLeft += 8;
      while (bitsLeft >= 5) {
        bitsLeft -= 5;
        out.write(_alphabet[(buffer >> bitsLeft) & 0x1f]);
      }
    }
    if (bitsLeft > 0) {
      out.write(_alphabet[(buffer << (5 - bitsLeft)) & 0x1f]);
    }
    return out.toString();
  }

  static String _group(String flat) {
    final groups = <String>[];
    for (var i = 0; i < flat.length; i += 4) {
      groups.add(flat.substring(i, i + 4 > flat.length ? flat.length : i + 4));
    }
    return groups.join('-');
  }
}
