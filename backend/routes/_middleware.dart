import 'package:backend/src/auth/auth_middleware.dart';
import 'package:backend/src/deps.dart';
import 'package:backend/src/services/logger.dart';
import 'package:backend/src/services/request_logger.dart';
import 'package:dart_frog/dart_frog.dart';

/// Injects shared services, an optional authenticated user, and permissive CORS
/// for local Flutter Web dev. In development, also logs every request.
Handler middleware(Handler handler) {
  var pipeline = handler
      .use(authProvider(deps.authVerifier))
      .use(provider<Deps>((_) => deps))
      .use(_cors());

  // Request logging is a development-only convenience; keep production quiet.
  if (log.isDevelopment) {
    pipeline = pipeline.use(devRequestLogger(log));
  }
  return pipeline;
}

Middleware _cors() {
  return (handler) {
    return (context) async {
      if (context.request.method == HttpMethod.options) {
        return Response(statusCode: 204, headers: _corsHeaders);
      }
      final res = await handler(context);
      return res.copyWith(
        headers: {...res.headers, ..._corsHeaders},
      );
    };
  };
}

const _corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  // PATCH and DELETE archive and remove projects. Without them here the
  // browser's preflight fails and the request never reaches a route.
  'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};
