import 'dart:io';

import 'package:backend/src/env.dart';

/// Starts the dev server with `backend/.env` loaded into its environment.
///
/// ```
/// dart run tool/dev.dart          # http://localhost:8080
/// dart run tool/dev.dart --port 9000
/// ```
///
/// The server itself reads [Platform.environment] and nothing else, and that is
/// deliberate rather than an omission: a container is configured by its
/// environment, and a file on disk that silently overrides it is how a staging
/// credential reaches production. But `.env.example` tells a developer to copy
/// it to `.env` and fill it in, so a plain `dart_frog dev` starts a server with
/// no auth and no database — one that answers `GET /` and rejects everything
/// else with "Auth is not configured". That looks like a broken frontend.
///
/// So the loading happens out here, in a script that only ever runs on a
/// developer's machine, and the invariant inside `lib/` is untouched.
///
/// The process environment wins over the file. A variable set deliberately for
/// one run — pointing at a scratch database, say — should not be silently
/// overridden by a file the developer forgot they wrote.
Future<void> main(List<String> args) async {
  final file = File('.env');
  if (!file.existsSync()) {
    stderr.writeln(
      'No backend/.env. Copy .env.example to .env and fill it in, or set '
      'SUPABASE_URL and DATABASE_URL in your shell and run `dart_frog dev` '
      'directly.',
    );
    exit(1);
  }

  final fromFile = _parse(file.readAsLinesSync());
  final environment = {...fromFile, ...Platform.environment};

  // Names only. These are credentials — a connection string carries a
  // password, and a terminal scrollback is not a secret store.
  final loaded = fromFile.keys.where((k) => !Platform.environment.containsKey(k));
  stdout.writeln(
    loaded.isEmpty
        ? 'backend/.env had nothing the environment did not already set.'
        : 'Loaded from backend/.env: ${loaded.join(', ')}',
  );
  _warnAbout(environment);

  final server = _stdinTakesRawMode()
      ? await _hotReloading(args, environment)
      : await _headless(args, environment);

  // Ctrl-C reaches this process, not the child, so without this the terminal
  // comes back while the server keeps holding the port.
  ProcessSignal.sigint.watch().listen((_) => server.kill());

  exit(await server.exitCode);
}

/// Whether stdin will take the raw mode `dart_frog dev` puts it into.
///
/// Probes the exact call that fails rather than asking [Stdin.hasTerminal],
/// which is not the same question and answers `true` in at least one place this
/// throws — a Git Bash background process on Windows has a terminal by that
/// measure and still cannot have its echo mode set. The child inherits this
/// process's stdin, so trying it here predicts what happens there.
///
/// Setting the mode to what it already is leaves a real console untouched.
bool _stdinTakesRawMode() {
  try {
    stdin.echoMode = stdin.echoMode;
    return true;
  } on Object {
    return false;
  }
}

/// `dart_frog dev`: hot reload, and a key listener that needs a real console.
///
/// `runInShell` so Windows resolves `dart_frog.bat` through PATHEXT, which a
/// bare exec does not.
Future<Process> _hotReloading(
  List<String> args,
  Map<String, String> environment,
) =>
    Process.start(
      'dart_frog',
      ['dev', ...args],
      environment: environment,
      runInShell: true,
      mode: ProcessStartMode.inheritStdio,
    );

/// The same server, built and run directly, for when there is no console.
///
/// `dart_frog dev` puts stdin into raw mode so it can listen for the key that
/// triggers a reload, and on Windows that throws `StdinException: Error setting
/// terminal echo mode` the moment stdin is a pipe rather than a console — which
/// it is under an IDE run configuration, a CI step, or anything that captures
/// output. The server had already started and bound the port, so what you see
/// is a process that announces itself and then dies, which reads as a crash in
/// this application rather than a limitation of its runner.
///
/// So when there is no terminal to reload from, the reloading is not worth the
/// crash: build once and run the result. Same routes, same middleware, no hot
/// reload.
Future<Process> _headless(
  List<String> args,
  Map<String, String> environment,
) async {
  stdout.writeln(
    'No terminal attached — building and running without hot reload. '
    'Run this from a console to get reloading back.',
  );

  final built = await Process.run(
    'dart_frog',
    ['build'],
    environment: environment,
    runInShell: true,
  );
  if (built.exitCode != 0) {
    stderr
      ..writeln('dart_frog build failed:')
      ..writeln(built.stdout)
      ..writeln(built.stderr);
    exit(built.exitCode);
  }

  // `dart_frog dev` defaults to 8080 and reads --port; the built server reads
  // PORT, so the flag has to be translated rather than passed through.
  final port = _portFrom(args);

  return Process.start(
    Platform.resolvedExecutable,
    ['run', 'build/bin/server.dart'],
    environment: {...environment, 'PORT': port},
    mode: ProcessStartMode.inheritStdio,
  );
}

/// `--port 9000` or `--port=9000` out of [args], defaulting to dart_frog's own
/// 8080 so both paths serve the same address when nothing is asked for.
String _portFrom(List<String> args) {
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--port' && i + 1 < args.length) return args[i + 1];
    if (arg.startsWith('--port=')) return arg.substring('--port='.length);
  }
  return '8080';
}

/// Says what is missing while there is still a terminal to read it in.
///
/// Both of these fail late and confusingly: no auth looks like a broken
/// frontend, and no database looks like a working app that forgets everything
/// when you restart it.
void _warnAbout(Map<String, String> environment) {
  final hasAuth = environment.containsKey('SUPABASE_URL') ||
      environment.containsKey('SUPABASE_JWKS_URL') ||
      environment.containsKey('SUPABASE_JWT_SECRET');
  if (!hasAuth) {
    stdout.writeln(
      'No SUPABASE_URL — every authenticated request will be refused, so the '
      'frontend will look broken rather than logged out.',
    );
  }
  if (!environment.containsKey('DATABASE_URL')) {
    stdout.writeln(
      'No DATABASE_URL — running in memory. Projects and history are lost on '
      'restart.',
    );
  }
}

/// `KEY=value` a line at a time, `#` comments, and [unwrapEnvValue] for the
/// quoting a value picks up on its way into a file.
///
/// Not a dotenv implementation and not trying to be — no `export`, no
/// interpolation, no multi-line values. The same shape `TestEnv` reads, kept
/// separate because that one lives in `test/` and this must not.
Map<String, String> _parse(List<String> lines) {
  final values = <String, String>{};
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

    final split = trimmed.indexOf('=');
    if (split <= 0) continue;

    values[trimmed.substring(0, split).trim()] =
        unwrapEnvValue(trimmed.substring(split + 1));
  }
  return values;
}
