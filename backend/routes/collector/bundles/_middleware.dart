import 'package:backend/src/services/rate_limit_middleware.dart';
import 'package:dart_frog/dart_frog.dart';

/// No `requireAuth` here, deliberately: this route has no Supabase session,
/// only a pairing code, and the sibling `/collector/sessions` is where
/// authentication lives instead. Rate limited by IP rather than by user,
/// since there is no user id to key on until a code has already resolved to
/// one — see `rateLimitByIp`.
Handler middleware(Handler handler) => handler.use(rateLimitByIp());
