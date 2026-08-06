import 'package:backend/src/auth/auth_middleware.dart';
import 'package:dart_frog/dart_frog.dart';

/// Minting and reading a pairing session both need to know who is asking — a
/// session belongs to whoever mints it, same as everything under `/projects`.
///
/// The sibling `/collector/bundles` deliberately has no such middleware: that
/// route is reached with a code instead of a session, and keeping the two in
/// separate directories makes which is which a structural fact rather than
/// something to remember while reading `onRequest`.
Handler middleware(Handler handler) => handler.use(requireAuth());
