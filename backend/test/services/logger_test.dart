import 'package:backend/src/services/logger.dart';
import 'package:test/test.dart';

void main() {
  group('Logger.fromEnv', () {
    test('defaults to development + debug level when env is empty', () {
      final logger = Logger.fromEnv(environment: const {});
      expect(logger.isDevelopment, isTrue);
      expect(logger.minLevel, LogLevel.debug);
    });

    test('ENV=production disables dev mode and defaults to info level', () {
      final logger = Logger.fromEnv(environment: const {'ENV': 'production'});
      expect(logger.isDevelopment, isFalse);
      expect(logger.minLevel, LogLevel.info);
    });

    test('DART_ENV is honoured as a fallback for ENV', () {
      final logger =
          Logger.fromEnv(environment: const {'DART_ENV': 'production'});
      expect(logger.isDevelopment, isFalse);
    });

    test('LOG_LEVEL overrides the per-environment default', () {
      final logger = Logger.fromEnv(
        environment: const {'ENV': 'production', 'LOG_LEVEL': 'error'},
      );
      expect(logger.minLevel, LogLevel.error);
    });

    test('an unrecognised LOG_LEVEL falls back to the env default', () {
      final logger = Logger.fromEnv(environment: const {'LOG_LEVEL': 'chatty'});
      expect(logger.minLevel, LogLevel.debug);
    });
  });

  group('log output', () {
    late StringBuffer out;
    late StringBuffer err;
    Logger build(LogLevel level) => Logger(
          minLevel: level,
          isDevelopment: false,
          out: out,
          err: err,
        );

    setUp(() {
      out = StringBuffer();
      err = StringBuffer();
    });

    test('messages below minLevel are dropped, others emitted', () {
      build(LogLevel.warn)
        ..debug('nope-debug')
        ..info('nope-info')
        ..warn('yes-warn')
        ..error('yes-error');

      final combined = '$out$err';
      expect(combined, isNot(contains('nope')));
      expect(combined, contains('yes-warn'));
      expect(combined, contains('yes-error'));
    });

    test('info goes to stdout, warn/error go to stderr', () {
      build(LogLevel.debug)
        ..info('an info line')
        ..warn('a warn line')
        ..error('an error line');

      expect(out.toString(), contains('an info line'));
      expect(out.toString(), isNot(contains('a warn line')));
      expect(err.toString(), contains('a warn line'));
      expect(err.toString(), contains('an error line'));
    });

    test('tagged() stamps the tag onto every line', () {
      build(LogLevel.debug).tagged('http').info('GET /health -> 200');

      final line = out.toString();
      expect(line, contains('[http]'));
      expect(line, contains('GET /health -> 200'));
      expect(line, contains('INFO'));
    });

    test('error() appends the error object and stack trace', () {
      build(LogLevel.debug).error(
        'boom',
        error: StateError('bad'),
        stackTrace: StackTrace.current,
      );

      expect(err.toString(), contains('boom'));
      expect(err.toString(), contains('error: Bad state: bad'));
    });
  });
}
