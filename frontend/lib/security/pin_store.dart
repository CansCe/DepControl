import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'pbkdf2.dart';

/// Where a device PIN is kept, and what it is honestly worth.
///
/// The PIN is a **lock on the screen**. What that is worth depends on the
/// build, and [PinScope] carries the difference into the words the user reads:
/// in a browser the session token and this hash share one `localStorage`, so
/// anyone with the developer console can skip the lock entirely; in the Android
/// app that storage is private and the lock sits on top of real protection.
/// Either way what it buys is the ordinary case — a laptop left open, a phone
/// handed over, a tab someone wanders into — and with a session that now lasts
/// a week rather than an hour, that case comes up a lot more often than it did.
///
/// It is stored the way a password would be anyway: PBKDF2-HMAC-SHA256 over a
/// random salt, so the stored value is not the PIN and cannot be read back as
/// one. Four to eight digits is a small enough space that [iterations] is doing
/// real work here — at 100,000 rounds, grinding the whole six-digit space costs
/// days rather than seconds.
class PinStore {
  PinStore({SharedPreferences? prefs, Random? random})
      : _prefs = prefs,
        _random = random ?? Random.secure();

  SharedPreferences? _prefs;
  final Random _random;

  /// Short enough to type one-handed, long enough that shoulder-surfing is the
  /// easier attack. The ceiling exists so the field cannot become a password
  /// field by another name, with none of a password field's affordances.
  static const minLength = 4;
  static const maxLength = 8;

  /// PBKDF2 rounds, when the browser derives keys natively.
  ///
  /// Free to be generous here: WebCrypto runs this in the browser's own native
  /// code, so 200,000 rounds costs tens of milliseconds and the field is ready
  /// before anyone has finished lifting a finger off the last digit.
  static const iterations = 200000;

  /// PBKDF2 rounds when the derivation is the Dart loop — the Android build, a
  /// browser with no WebCrypto, or a test.
  ///
  /// Lower because the Dart loop is roughly two orders of magnitude slower than
  /// the browser's native one: measured in Chromium, 200,000 rounds cost 4.2
  /// seconds against WebCrypto's 74ms. That time is spent on the calling
  /// thread — see `pbkdf2_dart.dart` for why an isolate did not turn out to be
  /// the answer — and a phone is slower than the desktop those numbers came
  /// off.
  ///
  /// So the trade is made in the direction of the person typing. Against the
  /// attacker this guards — someone reading the stored hash, who by definition
  /// already has the session token sitting beside it — the work factor was
  /// never the thing standing in their way.
  static const fallbackIterations = 20000;

  /// What a new PIN is hashed with here.
  static int get workFactor => pbkdf2IsNative ? iterations : fallbackIterations;

  /// Wrong tries before the lock starts making people wait.
  static const attemptsBeforeDelay = 5;

  /// The longest wait a run of wrong tries can earn.
  static const maxLockout = Duration(minutes: 5);

  static const _kUser = 'pin.userId';
  static const _kSalt = 'pin.salt';
  static const _kHash = 'pin.hash';
  static const _kRounds = 'pin.iterations';
  static const _kSetAt = 'pin.setAt';
  static const _kFailures = 'pin.failures';
  static const _kLockedUntil = 'pin.lockedUntil';
  /// Who has already been offered a PIN and said no.
  ///
  /// Per account rather than per device: two people sharing a browser are two
  /// people to ask, and the second one inheriting the first one's answer would
  /// quietly leave them without the thing this prompt exists to offer.
  static const _kPromptDeclined = 'pin.promptDeclinedBy';

  Future<SharedPreferences> get _store async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// What is on this device right now.
  Future<PinState> read() async {
    final prefs = await _store;
    final lockedUntilMs = prefs.getInt(_kLockedUntil);
    final setAt = prefs.getString(_kSetAt);

    return PinState(
      isSet: prefs.getString(_kHash) != null,
      userId: prefs.getString(_kUser),
      setAt: setAt == null ? null : DateTime.tryParse(setAt),
      failures: prefs.getInt(_kFailures) ?? 0,
      lockedUntil: lockedUntilMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lockedUntilMs),
      promptDeclinedBy: prefs.getStringList(_kPromptDeclined) ?? const [],
    );
  }

  /// Sets or replaces the PIN, recording which account it belongs to.
  ///
  /// The owner matters: a PIN is a lock on one person's session on one device,
  /// so it must not still be standing when somebody else signs in on the same
  /// machine — they would be locked out of their own account by a number they
  /// were never told.
  Future<void> setPin(String pin, {required String userId}) async {
    final problem = validate(pin);
    if (problem != null) throw ArgumentError(problem);

    final salt = Uint8List.fromList(
      [for (var i = 0; i < 16; i++) _random.nextInt(256)],
    );
    final rounds = workFactor;
    final hash = await derivePbkdf2(
      password: pin,
      salt: salt,
      iterations: rounds,
    );

    final prefs = await _store;
    await prefs.setString(_kUser, userId);
    await prefs.setString(_kSalt, base64Encode(salt));
    await prefs.setString(_kHash, base64Encode(hash));
    // Stored with the record rather than read from the constant: a PIN set in
    // a browser with WebCrypto must stay checkable in one without it, and vice
    // versa, so the count that produced this hash travels with it.
    await prefs.setInt(_kRounds, rounds);
    await prefs.setString(_kSetAt, DateTime.now().toUtc().toIso8601String());
    await prefs.remove(_kFailures);
    await prefs.remove(_kLockedUntil);
    // Setting one answers the prompt more definitively than dismissing it.
    await dismissPrompt(userId);
  }

  /// Checks [pin], counting the attempt.
  ///
  /// Wrong answers accumulate and eventually cost time. A correct one clears
  /// the record, including a wait already earned — the point of the delay is to
  /// slow down someone guessing, not to punish the owner for a typo.
  Future<PinVerification> verify(String pin) async {
    final prefs = await _store;
    final state = await read();

    if (state.isLockedOut) {
      return PinVerification(
        ok: false,
        failures: state.failures,
        retryIn: state.lockoutRemaining,
      );
    }

    final storedHash = prefs.getString(_kHash);
    final storedSalt = prefs.getString(_kSalt);
    if (storedHash == null || storedSalt == null) {
      return const PinVerification(ok: false, failures: 0, retryIn: Duration.zero);
    }

    final candidate = await derivePbkdf2(
      password: pin,
      salt: base64Decode(storedSalt),
      iterations: prefs.getInt(_kRounds) ?? iterations,
    );

    if (_constantTimeEquals(candidate, base64Decode(storedHash))) {
      await prefs.remove(_kFailures);
      await prefs.remove(_kLockedUntil);
      return const PinVerification(ok: true, failures: 0, retryIn: Duration.zero);
    }

    final failures = state.failures + 1;
    await prefs.setInt(_kFailures, failures);

    final wait = lockoutAfter(failures);
    if (wait > Duration.zero) {
      await prefs.setInt(
        _kLockedUntil,
        DateTime.now().add(wait).millisecondsSinceEpoch,
      );
    }

    return PinVerification(ok: false, failures: failures, retryIn: wait);
  }

  /// How long a run of [failures] wrong tries has to wait before the next one.
  ///
  /// Nothing for the first few — a mistyped digit is not an attack — then a
  /// doubling delay, which turns even the four-digit space into something that
  /// takes weeks by hand.
  static Duration lockoutAfter(int failures) {
    // The nth wrong try is free up to and including [attemptsBeforeDelay]; the
    // one after it is the first to cost anything.
    final over = failures - attemptsBeforeDelay - 1;
    if (over < 0) return Duration.zero;
    final seconds = 30 * (1 << over.clamp(0, 10));
    return seconds >= maxLockout.inSeconds
        ? maxLockout
        : Duration(seconds: seconds);
  }

  /// Removes the PIN and everything about it. Used when someone turns it off,
  /// and when someone has forgotten it and signs out instead.
  Future<void> clear() async {
    final prefs = await _store;
    for (final key in [
      _kUser,
      _kSalt,
      _kHash,
      _kRounds,
      _kSetAt,
      _kFailures,
      _kLockedUntil,
    ]) {
      await prefs.remove(key);
    }
  }

  /// Remembers that [userId] was offered a PIN and answered, so the offer is
  /// made once rather than every time they open the app.
  Future<void> dismissPrompt(String userId) async {
    final prefs = await _store;
    final declined = {
      ...?prefs.getStringList(_kPromptDeclined),
      userId,
    };
    await prefs.setStringList(_kPromptDeclined, declined.toList());
  }

  /// Why [pin] is not usable, or null when it is.
  static String? validate(String pin) {
    if (pin.length < minLength || pin.length > maxLength) {
      return 'Use between $minLength and $maxLength digits.';
    }
    if (!RegExp(r'^\d+$').hasMatch(pin)) return 'Digits only.';
    if (RegExp(r'^(.)\1*$').hasMatch(pin)) {
      return 'That is the same digit repeated — pick something else.';
    }
    if (_isSequential(pin)) return 'That is a run of digits — pick something else.';
    return null;
  }

  /// `1234`, `4321` and their longer relatives. Refused because they are the
  /// first things anyone tries, which makes them worth roughly nothing.
  static bool _isSequential(String pin) {
    var ascending = true;
    var descending = true;
    for (var i = 1; i < pin.length; i++) {
      final delta = pin.codeUnitAt(i) - pin.codeUnitAt(i - 1);
      if (delta != 1) ascending = false;
      if (delta != -1) descending = false;
    }
    return ascending || descending;
  }

  /// Compares without leaking where the difference is through timing.
  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

/// The PIN as it stands on this device.
class PinState {
  const PinState({
    required this.isSet,
    this.userId,
    this.setAt,
    this.failures = 0,
    this.lockedUntil,
    this.promptDeclinedBy = const [],
  });

  static const none = PinState(isSet: false);

  final bool isSet;

  /// The account this PIN belongs to. A PIN set by someone else does not lock
  /// the app for whoever is signed in now.
  final String? userId;

  final DateTime? setAt;
  final int failures;
  final DateTime? lockedUntil;

  /// The accounts that have already answered the offer to set one.
  final List<String> promptDeclinedBy;

  /// Whether [userId] has already been asked.
  bool hasDeclinedPrompt(String? userId) =>
      userId != null && promptDeclinedBy.contains(userId);

  bool get isLockedOut => lockoutRemaining > Duration.zero;

  Duration get lockoutRemaining {
    final until = lockedUntil;
    if (until == null) return Duration.zero;
    final left = until.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Whether this PIN guards [userId]'s session.
  bool appliesTo(String? userId) =>
      isSet && userId != null && this.userId == userId;
}

/// The outcome of one attempt.
class PinVerification {
  const PinVerification({
    required this.ok,
    required this.failures,
    required this.retryIn,
  });

  final bool ok;

  /// Consecutive wrong answers, this one included.
  final int failures;

  /// How long before another attempt is accepted. Zero unless the lock is
  /// making them wait.
  final Duration retryIn;

  bool get isLockedOut => retryIn > Duration.zero;
}
