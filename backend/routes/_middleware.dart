import 'package:dart_frog/dart_frog.dart';

import '../lib/src/deps.dart';

/// Injects shared services and permissive CORS for local Flutter Web dev.
Handler middleware(Handler handler) {
  return handler
      .use(provider<Deps>((_) => deps))
      .use(_cors());
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
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};
