import 'package:backend/src/auth/auth_middleware.dart';
import 'package:dart_frog/dart_frog.dart';

/// A notification target names one person's channel and holds a credential for
/// it, so `/notifications` requires a valid Supabase JWT just as `/projects`
/// does.
///
/// No rate limiter here, unlike `/projects`: these routes read and write rows
/// and make no outbound request. Nothing is *delivered* from a request either —
/// announcements are sent by `tool/rescan.dart`, so no caller can use this
/// endpoint to make the server post somewhere on demand.
Handler middleware(Handler handler) => handler.use(requireAuth());
