import 'package:backend/src/auth/auth_middleware.dart';
import 'package:dart_frog/dart_frog.dart';

/// Everything under `/me` requires a valid Supabase JWT.
Handler middleware(Handler handler) => handler.use(requireAuth());
