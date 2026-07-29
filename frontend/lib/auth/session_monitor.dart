import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Where a session stands, from the app's point of view rather than Supabase's.
///
/// Supabase knows one thing — whether a session exists — and it stops existing
/// the moment a refresh fails. That is enough to decide what to render and not
/// enough to decide what to *say*: being signed out because you asked and being
/// signed out because a token quietly aged out are the same event to the SDK
/// and completely different events to the person whose half-finished work is on
/// screen.
enum SessionStatus {
  /// Signed in, or never signed in. Nothing to announce.
  live,

  /// The session ended on its own and nobody has told the user yet.
  expiredUnannounced,

  /// The user was told and chose to stay where they were. The screen behind
  /// them is a snapshot now: nothing on it can be refreshed or saved.
  expiredPostponed,

  /// Over, by request or by agreement. Show sign-in.
  ended,
}

/// Tracks *why* a session ended, so the app can tell the user before the ground
/// moves under them.
///
/// The app used to call `signOut()` straight from its 401 handlers, which meant
/// the first sign of an expired session was the sign-in screen appearing where
/// the project you were reading had been — no message, no chance to finish
/// reading, and no way to tell it apart from having been signed out for some
/// other reason.
class SessionMonitor extends ChangeNotifier {
  SessionMonitor({Future<void> Function()? signOut})
      : _signOut = signOut ?? _supabaseSignOut;

  /// The app-wide instance. Screens report expiry to this; [AuthGate] watches
  /// it.
  static final SessionMonitor instance = SessionMonitor();

  static Future<void> _supabaseSignOut() =>
      Supabase.instance.client.auth.signOut();

  final Future<void> Function() _signOut;

  SessionStatus _status = SessionStatus.live;
  String? _reason;
  bool _byExpiry = false;

  SessionStatus get status => _status;

  /// Whether the sign-in screen is being shown because a session ran out
  /// rather than because someone signed out. The two want different words on
  /// arrival, and "your session expired" after pressing *Sign out* is simply
  /// untrue.
  bool get endedByExpiry => _status == SessionStatus.ended && _byExpiry;

  /// What the server said, when it said anything. Carried through to the
  /// dialog: "Token expired" and "Authentication unavailable" send someone to
  /// very different places.
  String? get reason => _reason;

  /// Whether the session has ended without the user having agreed to it.
  bool get hasEnded =>
      _status != SessionStatus.live && _status != SessionStatus.ended;

  /// Reports that the session is no longer accepted — a 401 from the API, or a
  /// session that vanished without anyone asking it to.
  ///
  /// Deliberately does *not* sign out. Tearing the screen down is the thing
  /// this class exists to stop happening unannounced; that comes from
  /// [confirm], once the user has read what happened.
  void reportExpired([String? reason]) {
    // A second 401 from a parallel request is the same event. Re-announcing it
    // would reopen a dialog the user just dismissed.
    if (_status != SessionStatus.live) return;
    _status = SessionStatus.expiredUnannounced;
    _reason = reason;
    _byExpiry = true;
    notifyListeners();
  }

  /// The user read the notice and wants to sign in again.
  Future<void> confirm() async {
    _status = SessionStatus.ended;
    notifyListeners();
    await _signOut();
  }

  /// The user read the notice and would rather keep looking at what is on
  /// screen. Nothing on it will work, and the banner says so.
  void postpone() {
    if (_status != SessionStatus.expiredUnannounced) return;
    _status = SessionStatus.expiredPostponed;
    notifyListeners();
  }

  /// The user asked to sign out. No notice: they know, they just did it.
  Future<void> signOutRequested() async {
    _status = SessionStatus.ended;
    _reason = null;
    _byExpiry = false;
    notifyListeners();
    await _signOut();
  }

  /// A session exists again — forget everything about the last one.
  void reset() {
    if (_status == SessionStatus.live) return;
    _status = SessionStatus.live;
    _reason = null;
    _byExpiry = false;
    notifyListeners();
  }
}
