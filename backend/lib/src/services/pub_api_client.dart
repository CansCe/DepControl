import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';

import '../ecosystem/package_registry.dart';

// The OSV advisory types, the published-version record and the registry info
// envelope were defined here when pub.dev was the only registry this server
// knew about. They were never pub-specific — OSV is a cross-ecosystem format
// and semver is shared — so they now live in the ecosystem layer, and are
// re-exported here so that reading pub.dev's client still hands you the types
// it deals in.
export '../ecosystem/package_registry.dart'
    show Advisory, AdvisoryRange, PackageVersion, RegistryInfo;

/// Thin client over the public pub.dev API.
///
/// Docs: https://pub.dev/help/api
class PubApiClient {
  PubApiClient({http.Client? client, this.baseUrl = 'https://pub.dev'})
      : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;

  static const _timeout = Duration(seconds: 20);

  /// Package names as pub.dev defines them: a Dart identifier.
  ///
  /// Names reach this client from fetched pubspecs, which are untrusted. An
  /// unchecked name is interpolated into the request path, and something like
  /// `../../admin` normalises the API prefix away — the host stays pub.dev, but
  /// the request stops being the one this client meant to make.
  ///
  /// A leading underscore is legal and is not a corner case: `_fe_analyzer_shared`
  /// is pulled in by every project that depends on `analyzer`. Rejecting it made
  /// this client answer null for the package silently, so its latest version, its
  /// advisories and its license all came back as unknown rather than as an error.
  static final _packageName = RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]{0,63}$');

  /// Whether [name] is a package name pub.dev could serve, by the rule above.
  ///
  /// Public because the rule belongs to pub.dev rather than to this client, and
  /// [DartRegistry] answers the same question for the ecosystem layer. A second
  /// copy of the pattern is how the leading-underscore bug gets reintroduced.
  static bool isPackageName(String name) => _packageName.hasMatch(name);

  /// The newest version pub.dev has published for [package].
  ///
  /// This client no longer fetches advisories. It used to, from
  /// `/api/packages/<package>/advisories`, but that endpoint serves *withdrawn*
  /// advisories alongside live ones with nothing in the response to tell them
  /// apart — see [DartRegistry.info]. Advisories for both ecosystems now come
  /// from OSV, which is where pub.dev's came from in the first place.
  Future<String?> latestVersion(String package) async {
    final json = await _getJson('/api/packages/$package', package);
    if (json == null) return null;
    final latest = json['latest'] as Map<String, dynamic>?;
    return latest?['version'] as String?;
  }

  /// pub.dev's analysis tags for one published version of [package], which is
  /// where its detected license is published.
  ///
  /// Beware what "no analysis" looks like here. pub.dev keeps one analysis per
  /// version and drops the old ones, but a dropped version still answers with a
  /// tag list — just a shorter one, holding the facts that need no analysis
  /// (`publisher:dart.dev`, `is:obsolete`) and no `license:` tag at all. So an
  /// empty list is not the signal a caller wants; the absence of the tag it
  /// came for is. [LicenseCatalog] reads that distinction.
  ///
  /// Endpoint: `/api/packages/<package>/versions/<version>/score` -> `tags`.
  Future<List<String>> versionTags(String package, String version) async {
    try {
      Version.parse(version);
    } on FormatException {
      return const [];
    }
    return _tags('/api/packages/$package/versions/$version/score', package);
  }

  /// pub.dev's analysis tags for the latest release of [package].
  ///
  /// Endpoint: `/api/packages/<package>/score` -> `tags`.
  Future<List<String>> latestTags(String package) =>
      _tags('/api/packages/$package/score', package);

  Future<List<String>> _tags(String path, String package) async {
    final json = await _getJson(path, package);
    final tags = json?['tags'] as List?;
    return tags == null ? const [] : tags.map((t) => '$t').toList();
  }

  /// Every published version of [package], each with the constraints it
  /// declares.
  ///
  /// `/api/packages/<package>` already embeds each version's pubspec, so the
  /// whole resolution input for a package costs a single request.
  Future<List<PackageVersion>> versions(String package) async {
    final json = await _getJson('/api/packages/$package', package);
    if (json == null) return const [];

    final list = (json['versions'] as List?) ?? const [];
    final out = <PackageVersion>[];

    for (final entry in list.whereType<Map<String, dynamic>>()) {
      final raw = entry['version']?.toString();
      if (raw == null) continue;
      final Version version;
      try {
        version = Version.parse(raw);
      } on FormatException {
        continue;
      }

      final pubspec = entry['pubspec'] as Map<String, dynamic>?;
      final deps = pubspec?['dependencies'] as Map<String, dynamic>?;
      final environment = pubspec?['environment'] as Map<String, dynamic>?;
      out.add(
        PackageVersion(
          version: version,
          sdkConstraint: environment?['sdk']?.toString(),
          dependencies: {
            for (final e in (deps ?? const {}).entries)
              // Only plain string constraints are hosted deps; a map means
              // git/path/sdk, which pub.dev cannot resolve for us.
              if (e.value is String) e.key: e.value as String,
          },
        ),
      );
    }
    return out;
  }

  /// The names of the regular (non-dev) dependencies declared by a specific
  /// published version of [package]. Used to build the dependency graph's
  /// edges. Returns empty for versions pub.dev doesn't know (git/sdk/path deps).
  ///
  /// Endpoint: `/api/packages/<package>/versions/<version>` -> `pubspec`.
  Future<List<String>> dependencyNames(String package, String version) async {
    // The version comes from a lockfile the project controls, so it gets the
    // same treatment as the package name.
    try {
      Version.parse(version);
    } on FormatException {
      return const [];
    }

    final json = await _getJson(
      '/api/packages/$package/versions/$version',
      package,
    );
    if (json == null) return const [];
    final pubspec = json['pubspec'] as Map<String, dynamic>?;
    final deps = pubspec?['dependencies'] as Map<String, dynamic>?;
    return deps?.keys.toList() ?? const [];
  }

  /// GETs [path] on [baseUrl] and decodes it, or null when pub.dev has nothing
  /// to say.
  ///
  /// [package] is validated rather than escaped: a name that is not a package
  /// name is not a request worth making, and refusing it here means no caller
  /// has to remember to check.
  Future<Map<String, dynamic>?> _getJson(String path, String package) async {
    if (!_packageName.hasMatch(package)) return null;

    final http.Response res;
    try {
      res = await _client.get(Uri.parse('$baseUrl$path')).timeout(_timeout);
    } on TimeoutException {
      // One slow package should not fail a whole report; the node simply
      // reports what could not be established.
      return null;
    }
    if (res.statusCode != 200) return null;

    try {
      final decoded = jsonDecode(res.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  void close() => _client.close();
}
