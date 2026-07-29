import 'package:flutter/widgets.dart';

import 'pin_store.dart';

/// Decides whether the app is behind its PIN right now.
///
/// Two things put it there: opening the app, and coming back to a tab that has
/// been in the background long enough that whoever is looking at it might not
/// be the person who left it. Neither is a security boundary — see [PinStore]
/// for what a PIN in a browser can and cannot do — they are the two moments
/// where a screen full of somebody's projects is left facing the room.
class AppLock extends ChangeNotifier with WidgetsBindingObserver {
  AppLock({PinStore? store, this.awayBeforeLock = const Duration(minutes: 5)})
      : _store = store ?? PinStore();

  static final AppLock instance = AppLock();

  final PinStore _store;

  /// How long the tab has to be out of sight before coming back needs the PIN.
  ///
  /// Zero would lock on every alt-tab, which teaches people to turn the feature
  /// off. Long enough to switch to a terminal and back, short enough that a
  /// walk to the kitchen does not leave the account open.
  final Duration awayBeforeLock;

  PinState _state = PinState.none;
  bool _locked = false;
  bool _bound = false;
  DateTime? _awaySince;

  /// What is on this device — whether a PIN exists, who it belongs to, and
  /// whether wrong tries have earned a wait.
  PinState get state => _state;

  bool get isLocked => _locked;

  /// Whether a PIN is set and guards the signed-in account.
  bool get isArmed => _state.appliesTo(_userId);

  String? _userId;

  /// Attaches the lock to the signed-in user, locking immediately when that
  /// user has a PIN. Called when the app is entered with a session.
  Future<void> bind(String? userId) async {
    _userId = userId;
    _state = await _store.read();
    _locked = _state.appliesTo(userId);

    if (!_bound) {
      _bound = true;
      WidgetsBinding.instance.addObserver(this);
    }
    notifyListeners();
  }

  /// Detaches on sign-out, so the next sign-in is a fresh decision.
  void unbind() {
    if (_bound) {
      WidgetsBinding.instance.removeObserver(this);
      _bound = false;
    }
    _userId = null;
    _locked = false;
    _awaySince = null;
    notifyListeners();
  }

  /// Re-reads the stored PIN — after it is set, changed or removed.
  Future<void> refresh() async {
    _state = await _store.read();
    if (!_state.appliesTo(_userId)) _locked = false;
    notifyListeners();
  }

  /// Puts the lock on now, at the user's request.
  void lockNow() {
    if (!isArmed || _locked) return;
    _locked = true;
    notifyListeners();
  }

  /// Checks [pin] and lifts the lock when it is right.
  Future<PinVerification> unlock(String pin) async {
    final result = await _store.verify(pin);
    _state = await _store.read();
    if (result.ok) {
      _locked = false;
      _awaySince = null;
    }
    notifyListeners();
    return result;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      // `inactive` is deliberately not here. On the web it fires whenever the
      // window loses focus — clicking the devtools panel, or another window on
      // the same screen — and locking on that would make the app unusable
      // beside anything else.
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _awaySince ??= DateTime.now();
      case AppLifecycleState.resumed:
        final since = _awaySince;
        _awaySince = null;
        if (since == null || !isArmed || _locked) return;
        if (DateTime.now().difference(since) >= awayBeforeLock) {
          _locked = true;
          notifyListeners();
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  void dispose() {
    if (_bound) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
