import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';
import 'package:shared/shared.dart';

import '../../services/license_catalog.dart';
import '../osv_client.dart';
import '../package_registry.dart';
import 'npm_version_range.dart';

/// registry.npmjs.org, behind [PackageRegistry].
class NpmRegistry implements PackageRegistry {
  NpmRegistry({
    http.Client? client,
    OsvClient? osv,
    this.baseUrl = 'https://registry.npmjs.org',
  })  : _client = client ?? http.Client(),
        _osv = osv ?? OsvClient(client: client);

  final http.Client _client;

  /// Where advisories come from. npm publishes none in a per-package form, so
  /// unlike pub.dev this is a second host — see [OsvClient].
  final OsvClient _osv;

  final String baseUrl;

  static const _timeout = Duration(seconds: 20);

  /// OSV's name for this ecosystem, which is not [Ecosystem.id] and is
  /// case-sensitive.
  static const osvEcosystem = 'npm';

  /// The abbreviated packument, which the registry serves in response to this
  /// content type.
  ///
  /// It carries exactly what resolution needs — every version, its
  /// dependencies, its engines, and the dist-tags — and leaves out the readme,
  /// the maintainer history and the per-version metadata that make a full
  /// packument for a popular package megabytes of JSON. `lodash` is about
  /// forty times smaller this way.
  ///
  /// What it does *not* carry is the licence, which is why [licenseFor] asks
  /// for a single version document instead.
  static const _abbreviated = 'application/vnd.npm.install-v1+json';

  /// Packuments already fetched, so `info`, `versions` and `dependencyNames`
  /// cost one request between them rather than three.
  ///
  /// Cleared wholesale when it grows past a bound. A scan touches a few hundred
  /// packages and this object lives for the life of the process, so something
  /// has to give way; dropping everything is crude but it is one line and the
  /// cost of a miss is one request.
  final _packuments = <String, Map<String, dynamic>?>{};

  static const _maxCachedPackuments = 2000;

  /// npm package names: lowercase, optionally scoped, no leading dot or
  /// underscore, at most 214 characters including any scope.
  ///
  /// Validated rather than escaped, for the same reason pub.dev names are: a
  /// name arrives from a fetched `package.json` and is interpolated into a
  /// request path. `../../-/all` would normalise the path away and issue a
  /// request nobody asked for.
  static final _name = RegExp(
    r'^(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$',
  );

  @override
  bool isValidPackageName(String name) =>
      name.length <= 214 && !name.contains('..') && _name.hasMatch(name);

  @override
  Future<RegistryInfo> info(String package) async {
    // Checked here as well as in [_getJson], because this method makes a second
    // outbound call to a different host. A name that is not a package is not a
    // request worth making to *either* of them, and validating only the one
    // that interpolates it into a path leaves the other reachable.
    if (!isValidPackageName(package)) return const RegistryInfo(latest: null);

    final packument = await _packument(package);
    // Read defensively rather than cast. Everything in a packument is
    // publisher-supplied and the registry has served every field shape someone
    // has ever managed to publish.
    final tags = packument?['dist-tags'];
    final latest = tags is Map ? tags['latest'] : null;

    return RegistryInfo(
      latest: latest?.toString(),
      advisories:
          await _osv.advisoriesFor(package, ecosystem: osvEcosystem),
    );
  }

  @override
  Future<List<PackageVersion>> versions(String package) async {
    final packument = await _packument(package);
    final versions = packument?['versions'];
    if (versions is! Map<String, dynamic>) return const [];

    final out = <PackageVersion>[];
    for (final entry in versions.entries) {
      final Version version;
      try {
        version = Version.parse(entry.key);
      } on FormatException {
        continue;
      }

      final doc = entry.value;
      if (doc is! Map<String, dynamic>) continue;

      out.add(
        PackageVersion(
          version: version,
          sdkConstraint: _nodeEngine(doc['engines']),
          dependencies: _resolvableDependencies(doc),
        ),
      );
    }
    return out;
  }

  /// The Node range a published version demands, from its `engines`.
  ///
  /// `engines` is usually `{"node": ">=14"}`, but npm has also long accepted an
  /// array of `"name range"` strings, and packages old enough to still carry
  /// that form are exactly the ones a dependency report digs up. A blind cast
  /// to a map threw on them — and because this runs while building the version
  /// list, one such release took down the whole list, leaving the package
  /// unresolvable rather than merely missing an engine constraint.
  static String? _nodeEngine(Object? engines) => switch (engines) {
        final Map m => m['node']?.toString(),
        final List l => l
            .whereType<String>()
            .where((e) => e.trimLeft().startsWith('node'))
            .map((e) => e.trim().substring('node'.length).trim())
            .where((e) => e.isNotEmpty)
            .firstOrNull,
        _ => null,
      };

  @override
  Future<List<String>> dependencyNames(String package, String version) async {
    final packument = await _packument(package);
    final versions = packument?['versions'];
    if (versions is! Map<String, dynamic>) return const [];

    final doc = versions[version];
    if (doc is! Map<String, dynamic>) return const [];

    final deps = doc['dependencies'];
    return deps is Map<String, dynamic> ? deps.keys.toList() : const [];
  }

  /// The licence npm holds for one published version.
  ///
  /// A single version document rather than the packument: the abbreviated
  /// packument omits the field, and the full one is enormous for exactly the
  /// popular packages a report is most likely to be asking about.
  ///
  /// npm's `license` is whatever the publisher typed. It is not detected from
  /// the shipped LICENSE file the way pub.dev's is, so it is weaker evidence,
  /// and [PackageLicense] records that through [LicenseSource]. What it must
  /// not do is fabricate: a version document that omits the field, or carries
  /// the deprecated `{"type": ...}` object form, reads as undetermined rather
  /// than as anything in particular.
  @override
  Future<PackageLicense> licenseFor(
    String package,
    String installed,
    String? latest,
  ) async {
    final exact = await _licenseAt(package, installed);
    if (exact != null) {
      return PackageLicense(
        spdxId: exact,
        // Null from the catalogue means never heard of it, which under the
        // standard policy sends it to a human rather than to "probably fine".
        // npm licences are also frequently SPDX *expressions* —
        // `(MIT OR Apache-2.0)` — which no single-id table can classify, and
        // those land here too.
        category: LicenseCatalog.categoryFor(exact) ?? LicenseCategory.unknown,
        source: LicenseSource.installedVersion,
        readFromVersion: installed,
      );
    }

    // An unpublished or yanked version has no document; the latest release is
    // the honest fallback and the report says which was read.
    if (latest != null && latest != installed) {
      final fromLatest = await _licenseAt(package, latest);
      if (fromLatest != null) {
        return PackageLicense(
          spdxId: fromLatest,
          category: LicenseCatalog.categoryFor(fromLatest) ??
              LicenseCategory.unknown,
          source: LicenseSource.latestRelease,
          readFromVersion: latest,
        );
      }
    }

    return PackageLicense.undetermined;
  }

  Future<String?> _licenseAt(String package, String version) async {
    try {
      Version.parse(version);
    } on FormatException {
      return null;
    }

    final doc = await _getJson('/${_pathFor(package)}/$version', package);
    final license = doc?['license'];

    // The string form is current. The `{"type": "MIT", "url": ...}` object and
    // the `licenses: [...]` array are both long deprecated but remain in
    // published metadata for anything old enough to matter.
    return switch (license) {
      final String s when s.trim().isNotEmpty => s.trim(),
      final Map m when m['type'] is String => (m['type'] as String).trim(),
      _ => switch (doc?['licenses']) {
          final List l when l.isNotEmpty => switch (l.first) {
              final String s => s.trim(),
              final Map m when m['type'] is String => (m['type'] as String).trim(),
              _ => null,
            },
          _ => null,
        },
    };
  }

  /// The dependencies of a published version that resolution can use.
  ///
  /// `dependencies` and `optionalDependencies` both install and both ship, so
  /// both count. `peerDependencies` do not: a peer is a requirement this
  /// package makes of whoever installs it, not something it brings along, and
  /// counting them would attribute another project's choices to this one.
  /// `devDependencies` of a *published* package are not installed at all.
  ///
  /// Entries whose specifier is not a range — a git URL, a tarball, a `file:`
  /// path — are dropped, since the registry publishes no versions to resolve
  /// them against.
  Map<String, String> _resolvableDependencies(Map<String, dynamic> doc) {
    final out = <String, String>{};
    for (final key in const ['dependencies', 'optionalDependencies']) {
      final deps = doc[key];
      if (deps is! Map<String, dynamic>) continue;
      for (final entry in deps.entries) {
        final spec = entry.value;
        if (spec is! String) continue;
        if (parseNpmRange(spec) == null) continue;
        out[entry.key] = spec;
      }
    }
    return out;
  }

  Future<Map<String, dynamic>?> _packument(String package) async {
    if (_packuments.containsKey(package)) return _packuments[package];

    final fetched = await _getJson(
      '/${_pathFor(package)}',
      package,
      accept: _abbreviated,
    );

    if (_packuments.length >= _maxCachedPackuments) _packuments.clear();
    return _packuments[package] = fetched;
  }

  /// A package name as a single path segment.
  ///
  /// A scoped name contains a slash that is part of the *name*, not of the
  /// path, so it is encoded — otherwise `@types/node` requests the `node`
  /// document under a `@types` prefix, which is a different thing entirely and
  /// on some registries is a real one.
  /// Uppercase `%2F`, which is the canonical percent-encoding — and what a Uri
  /// normalises to, so a test asserting on the request URL sees the same bytes
  /// that went out.
  static String _pathFor(String package) =>
      package.startsWith('@') ? package.replaceFirst('/', '%2F') : package;

  Future<Map<String, dynamic>?> _getJson(
    String path,
    String package, {
    String? accept,
  }) async {
    if (!isValidPackageName(package)) return null;

    final http.Response response;
    try {
      response = await _client
          .get(
            Uri.parse('$baseUrl$path'),
            headers: {if (accept != null) 'Accept': accept},
          )
          .timeout(_timeout);
    } on TimeoutException {
      return null;
    } on http.ClientException {
      return null;
    }
    if (response.statusCode != 200) return null;

    try {
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  void close() {
    _client.close();
    _osv.close();
  }
}
