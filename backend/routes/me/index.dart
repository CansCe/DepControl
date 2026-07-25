import 'dart:io';

import 'package:backend/src/auth/auth_user.dart';
import 'package:dart_frog/dart_frog.dart';

/// GET /me -> the authenticated user. Guarded by `requireAuth` in
/// `_middleware.dart`, so the `AuthUser` is guaranteed present here.
Response onRequest(RequestContext context) {
  if (context.request.method != HttpMethod.get) {
    return Response(statusCode: HttpStatus.methodNotAllowed);
  }
  final user = context.read<AuthUser>();
  return Response.json(body: {'user': user.toJson()});
}
