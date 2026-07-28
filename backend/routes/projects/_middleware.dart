import 'package:backend/src/auth/auth_middleware.dart';
import 'package:backend/src/services/rate_limit_middleware.dart';
import 'package:dart_frog/dart_frog.dart';

/// Everything under `/projects` requires a valid Supabase JWT: projects are
/// owned by the user who added them, so there is no anonymous view.
///
/// Order matters. `use` wraps, so the last one applied runs first: `requireAuth`
/// establishes who is calling, and the limiter — running inside it — can then
/// count against that user rather than against the whole process.
Handler middleware(Handler handler) =>
    handler.use(rateLimitOutboundWork()).use(requireAuth());
