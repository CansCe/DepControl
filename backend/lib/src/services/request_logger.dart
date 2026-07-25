import 'package:dart_frog/dart_frog.dart';

import 'logger.dart';

/// Dart Frog middleware that logs one line per request:
/// `GET /projects?x=1 -> 200 (12ms)`. Intended for the **development**
/// environment — wire it in only when `log.isDevelopment` is true (see
/// `routes/_middleware.dart`).
///
/// Place it as the outermost middleware so the status it reports is the final
/// response returned to the client (after CORS and any inner middleware).
Middleware devRequestLogger([Logger? logger]) {
  final http = (logger ?? log).tagged('http');
  return (handler) {
    return (context) async {
      final stopwatch = Stopwatch()..start();
      final request = context.request;
      final method = request.method.value;
      final uri = request.uri;
      final target = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;

      try {
        final response = await handler(context);
        stopwatch.stop();
        http.info(
          '$method $target -> ${response.statusCode} '
          '(${stopwatch.elapsedMilliseconds}ms)',
        );
        return response;
      } catch (error, stackTrace) {
        stopwatch.stop();
        http.error(
          '$method $target -> unhandled error '
          '(${stopwatch.elapsedMilliseconds}ms)',
          error: error,
          stackTrace: stackTrace,
        );
        rethrow;
      }
    };
  };
}
