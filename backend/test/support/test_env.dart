import 'dart:io';

import 'package:backend/src/env.dart';

/// Configuration for the tests that need a real service.
///
/// The server reads the process environment and nothing else, which is right
/// for a deployment: a container is configured by its environment, and a file
/// on disk that silently overrides it is how a staging credential reaches
/// production. But `backend/.env.example` tells a developer to copy it to
/// `.env` and fill it in, so that is where `DATABASE_URL` ends up — and an
/// integration test reading only `Platform.environment` then skips, reporting
/// that a variable the developer demonstrably set is not set.
///
/// So the tests look in both, and say which. Nothing here is used by `lib/`.
abstract final class TestEnv {
  /// [name] from the process environment, falling back to `backend/.env`.
  ///
  /// Null when neither has it, or when it is present but empty — an empty
  /// string is not a connection string, and treating it as one turns a
  /// configuration mistake into a connection error much further away.
  static String? read(String name) {
    final fromProcess = readEnvironment()[name];
    if (fromProcess != null && fromProcess.isNotEmpty) return fromProcess;

    final fromFile = _dotEnv()[name];
    return (fromFile != null && fromFile.isNotEmpty) ? fromFile : null;
  }

  /// Why a test that needs [name] is being skipped, or null when it is not.
  ///
  /// Names both places it looked. A skip reason that only says "set it" sends
  /// somebody to set a variable they already set.
  static String? skipReasonFor(String name) => read(name) == null
      ? 'Set $name to run this — either as an environment variable '
          '(\$env:$name="…" in PowerShell) or in backend/.env.'
      : null;

  /// `backend/.env`, parsed, or empty when there is none.
  ///
  /// Deliberately minimal: `KEY=value` a line at a time, `#` comments, and
  /// [unwrapEnvValue] for the quoting a value picks up on its way into a file.
  /// It is not a dotenv implementation and does not try to be — no `export`,
  /// no interpolation, no multi-line values.
  static Map<String, String> _dotEnv() {
    if (_cache != null) return _cache!;

    final file = File(_locate());
    if (!file.existsSync()) return _cache = const {};

    final values = <String, String>{};
    for (final line in file.readAsLinesSync()) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

      final split = trimmed.indexOf('=');
      if (split <= 0) continue;

      values[trimmed.substring(0, split).trim()] =
          unwrapEnvValue(trimmed.substring(split + 1));
    }
    return _cache = values;
  }

  static Map<String, String>? _cache;

  /// `backend/.env`, whichever directory the test runner started in.
  ///
  /// `dart test` runs from `backend/`, but an IDE will happily run a single
  /// test file from the workspace root.
  static String _locate() {
    const relative = '.env';
    if (File(relative).existsSync()) return relative;
    return 'backend/.env';
  }
}
