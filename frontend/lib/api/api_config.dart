import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';

/// Which backend this build talks to, and the user's ability to point it
/// somewhere else.
///
/// The address is normally baked in at build time ([kDefaultApiBaseUrl]), which
/// is right for a deployment and wrong for everyone standing next to one: a
/// developer running the Dart Frog server locally, someone checking a staging
/// build against production data, anyone trying to establish whether "the app
/// is broken" means the frontend or the API behind it. Rebuilding the web
/// bundle to answer that is a poor trade.
///
/// The override is per-device and deliberately not part of the account — it
/// describes where *this* browser should look, which is not a fact about the
/// user. It is read once at startup and then held in memory, so a client
/// constructed at any point in the session sees the current value rather than
/// whatever was true when it was built.
class ApiConfig extends ChangeNotifier {
  ApiConfig({SharedPreferences? prefs}) : _prefs = prefs;

  static final ApiConfig instance = ApiConfig();

  static const _key = 'api_base_url';

  SharedPreferences? _prefs;
  String? _override;

  /// What the build was compiled to point at.
  String get compiledDefault => kDefaultApiBaseUrl;

  /// Where requests actually go.
  String get baseUrl => _override ?? kDefaultApiBaseUrl;

  /// Whether this device has been pointed somewhere other than the default.
  bool get isCustom => _override != null;

  /// Reads the stored override. Safe to call before `runApp`.
  Future<void> load() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final stored = _prefs!.getString(_key);
      _override = (stored == null || stored.isEmpty) ? null : stored;
    } on Object {
      // A device that cannot read its preferences still has a working default,
      // and failing to start over a settings lookup would be the worse bug.
      _override = null;
    }
    notifyListeners();
  }

  /// Points this device at [url], or back at the compiled default when null.
  ///
  /// Returns the reason it was refused, or null on success. Validation is not
  /// politeness: a base URL with a trailing slash or a missing scheme produces
  /// requests that fail in ways that look like the server is down.
  Future<String?> setBaseUrl(String? url) async {
    final trimmed = url?.trim();

    if (trimmed == null || trimmed.isEmpty) {
      _override = null;
    } else {
      final problem = validate(trimmed);
      if (problem != null) return problem;
      _override = normalize(trimmed);
    }

    try {
      _prefs ??= await SharedPreferences.getInstance();
      if (_override == null) {
        await _prefs!.remove(_key);
      } else {
        await _prefs!.setString(_key, _override!);
      }
    } on Object {
      return 'Could not save that on this device.';
    }

    notifyListeners();
    return null;
  }

  /// Why [url] cannot be a base URL, or null if it can.
  static String? validate(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return 'That is not a URL.';
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return 'Use an http:// or https:// address.';
    }
    if (!uri.hasAuthority || uri.host.isEmpty) return 'That URL has no host.';
    if (uri.hasQuery || uri.hasFragment) {
      return 'Give the address only — no query or fragment.';
    }
    return null;
  }

  /// Drops a trailing slash, which every call site would otherwise double up.
  static String normalize(String url) {
    var value = url.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  /// Test seam — the singleton outlives a `testWidgets` case otherwise.
  @visibleForTesting
  void reset() {
    _override = null;
    _prefs = null;
  }
}
