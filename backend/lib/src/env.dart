import 'dart:io';

/// Reading configuration out of the process environment.
///
/// Every value goes through [unwrapEnvValue] first. A secret store is a plain
/// string field with no validation, so what arrives is whatever survived the
/// shell that set it — and the most common damage is invisible.

/// Strips the packaging a value picks up on its way through a shell or a secret
/// store: a UTF-8 BOM, surrounding whitespace, and one matched pair of quotes.
///
/// This is not hypothetical tidiness. `SUPABASE_URL` was once deployed as
/// `'https://….supabase.co'`, quotes included — `cmd.exe` does not treat single
/// quotes as quoting, and a value typed into a dashboard field keeps whatever
/// you type. The result crashed the server on boot with "Scheme not starting
/// with alphabetic character", which points at the scheme: the one part of the
/// URL that was correct. `fly secrets list` shows a digest rather than a value,
/// so there is nothing to eyeball either.
///
/// Quotes come off only as a matched pair. A value with one leading quote is
/// left intact so it still fails: that means it was truncated somewhere, and
/// quietly connecting with half a password is worse than not starting.
String unwrapEnvValue(String value) {
  var s = value.replaceAll('\u{feff}', '').trim();
  if (s.length >= 2) {
    final first = s[0];
    if ((first == '"' || first == "'") && s[s.length - 1] == first) {
      s = s.substring(1, s.length - 1).trim();
    }
  }
  return s;
}

/// The environment with every value passed through [unwrapEnvValue].
///
/// Pass this rather than [Platform.environment] wherever config is read, so a
/// stray pair of quotes cannot change behaviour. It matters beyond the values
/// that crash on parse: quoted `'production'` is not `production`, which would
/// silently leave a deployed server in development mode.
Map<String, String> readEnvironment([Map<String, String>? source]) {
  final env = source ?? Platform.environment;
  return {
    for (final entry in env.entries) entry.key: unwrapEnvValue(entry.value),
  };
}
