import 'package:backend/src/auth/auth_middleware.dart';
import 'package:dart_frog/dart_frog.dart';

/// Everything under `/projects` requires a valid Supabase JWT: projects are
/// owned by the user who added them, so there is no anonymous view.
Handler middleware(Handler handler) => handler.use(requireAuth());
