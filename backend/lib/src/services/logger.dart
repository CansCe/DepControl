import 'dart:io';

/// Severity levels, ordered from most to least verbose.
enum LogLevel {
  debug(0, 'DEBUG', '\x1B[90m'), // grey
  info(1, 'INFO ', '\x1B[36m'), // cyan
  warn(2, 'WARN ', '\x1B[33m'), // yellow
  error(3, 'ERROR', '\x1B[31m'); // red

  const LogLevel(this.severity, this.label, this.color);

  final int severity;
  final String label;
  final String color;
}

/// A tiny structured console logger for the backend.
///
/// Output format: `HH:mm:ss.SSS LEVEL [tag] message`. Colour is used on a TTY
/// in development and suppressed otherwise (or when `NO_COLOR` is set), so logs
/// stay readable when piped to a file or a production log collector.
///
/// The default [Logger.fromEnv] instance reads:
///   * `ENV` / `DART_ENV` — anything other than `production` counts as
///     development (the default when unset).
///   * `LOG_LEVEL` — `debug|info|warn|error`; defaults to `debug` in
///     development and `info` in production.
class Logger {
  Logger({
    required this.minLevel,
    required this.isDevelopment,
    bool useColor = false,
    String? tag,
    StringSink? out,
    StringSink? err,
  })  : _useColor = useColor,
        _tag = tag,
        _out = out ?? stdout,
        _err = err ?? stderr;

  /// Builds a logger from the process environment. See the class docs.
  factory Logger.fromEnv({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final isDev = (env['ENV'] ?? env['DART_ENV'] ?? 'development') != 'production';

    final level = _parseLevel(env['LOG_LEVEL']) ??
        (isDev ? LogLevel.debug : LogLevel.info);

    final useColor = isDev &&
        !env.containsKey('NO_COLOR') &&
        stdout.hasTerminal &&
        stdout.supportsAnsiEscapes;

    return Logger(minLevel: level, isDevelopment: isDev, useColor: useColor);
  }

  /// Messages below this level are dropped.
  final LogLevel minLevel;

  /// True unless `ENV`/`DART_ENV` is `production`. Callers gate dev-only
  /// behaviour (e.g. request logging) on this.
  final bool isDevelopment;

  final bool _useColor;
  final String? _tag;
  final StringSink _out;
  final StringSink _err;

  /// Returns a child logger that stamps every line with [tag] (e.g. `http`,
  /// `db`, `auth`). Shares this logger's level, colour settings, and sinks.
  Logger tagged(String tag) => Logger(
        minLevel: minLevel,
        isDevelopment: isDevelopment,
        useColor: _useColor,
        tag: tag,
        out: _out,
        err: _err,
      );

  void debug(String message) => log(LogLevel.debug, message);
  void info(String message) => log(LogLevel.info, message);
  void warn(String message) => log(LogLevel.warn, message);

  void error(String message, {Object? error, StackTrace? stackTrace}) =>
      log(LogLevel.error, message, error: error, stackTrace: stackTrace);

  void log(
    LogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (level.severity < minLevel.severity) return;

    final buffer = StringBuffer()
      ..write(_timestamp(DateTime.now()))
      ..write(' ')
      ..write(_colorize(level.label, level.color))
      ..write(' ');
    if (_tag != null) buffer.write('[$_tag] ');
    buffer.write(message);
    if (error != null) buffer.write(' | error: $error');

    // Warnings and errors go to stderr; everything else to stdout.
    final sink = level.severity >= LogLevel.warn.severity ? _err : _out;
    sink.writeln(buffer);
    if (stackTrace != null) sink.writeln(stackTrace);
  }

  String _colorize(String text, String color) =>
      _useColor ? '$color$text\x1B[0m' : text;

  static LogLevel? _parseLevel(String? raw) {
    if (raw == null) return null;
    switch (raw.trim().toLowerCase()) {
      case 'debug':
        return LogLevel.debug;
      case 'info':
        return LogLevel.info;
      case 'warn':
      case 'warning':
        return LogLevel.warn;
      case 'error':
        return LogLevel.error;
      default:
        return null;
    }
  }

  static String _timestamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    String three(int n) => n.toString().padLeft(3, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}'
        '.${three(t.millisecond)}';
  }
}

/// Process-wide logger, configured from the environment.
final log = Logger.fromEnv();
