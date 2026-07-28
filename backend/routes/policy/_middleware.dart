import 'package:backend/src/auth/auth_middleware.dart';
import 'package:dart_frog/dart_frog.dart';

/// A license policy belongs to the user who wrote it, so `/policy` requires a
/// valid Supabase JWT just as `/projects` does.
///
/// No rate limiter here, unlike `/projects`: reading and writing one JSONB row
/// makes no outbound requests, and that limiter exists to bound the traffic one
/// user can drive out of this server towards pub.dev and the git hosts.
Handler middleware(Handler handler) => handler.use(requireAuth());
