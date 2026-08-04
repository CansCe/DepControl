import 'dart:async';
import 'dart:convert';

import 'package:ecosystem/ecosystem.dart';
import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';
import 'package:shared/shared.dart';

import '../../services/license_catalog.dart';
import '../../services/request_cache.dart';
import '../osv_client.dart';
import '../package_registry.dart';

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

  /// How long an answer about the *state of the registry* stays good for.
  ///
  /// Long enough that one scan asks about each package once, however many
  /// manifests want it. Short enough that a rescan on a server that has been
  /// up for a week still notices yesterday's release.
  static const _volatile = Duration(minutes: 10);

  /// Packuments already fetched, distilled — see [_Packument].
  ///
  /// `info`, `versions`, `dependencyNames` and `sizeOf` cost one request
  /// between them rather than four, and a package reached from twenty manifests
  /// still costs that one.
  final _packuments = RequestCache<String, _Fetched<_Packument?>>(
    capacity: 2000,
    ttl: _volatile,
  );

  /// Declared licences, keyed `package@version`. Kept apart from the packument
  /// because the abbreviated form omits the field entirely.
  ///
  /// Held far longer than the packuments: a published version's own metadata
  /// is fixed, so unlike `latest` there is nothing here that can go stale.
  final _licenses = RequestCache<String, _Fetched<String?>>(
    capacity: 4000,
    ttl: const Duration(hours: 6),
  );

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

    // Asked at once: two different hosts answering unrelated questions, so
    // awaiting one before starting the other spent a round trip per package
    // for nothing.
    final (packument, advisories) = await (
      _packument(package),
      _osv.advisoriesFor(package, ecosystem: osvEcosystem),
    ).wait;

    return RegistryInfo(latest: packument?.latest, advisories: advisories);
  }

  @override
  Future<List<PackageVersion>> versions(String package) async =>
      (await _packument(package))?.versions ?? const [];

  @override
  Future<List<String>> dependencyNames(String package, String version) async =>
      (await _packument(package))?.dependencyNames[version] ?? const [];

  /// The installed weight npm recorded for one published version.
  ///
  /// Free: `dist.unpackedSize` and `dist.fileCount` are in the abbreviated
  /// packument this client already fetches and caches, so no request is added
  /// to a scan.
  ///
  /// Absent for anything published before npm began recording it, which is not
  /// a rare corner — `sax` carries it on 9 of 54 releases, `inherits` on 1 of
  /// 7 — and those small old packages are exactly what a dependency tree is
  /// full of. Missing reads as null, never as zero: a tree that reported its
  /// unmeasured half as weightless would understate itself in the one
  /// direction that matters here.
  @override
  Future<PackageSize?> sizeOf(String package, String version) async =>
      (await _packument(package))?.sizes[version];

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

    final result = await _licenses.run(
      '$package@$version',
      () async {
        final fetched = await _getJson(
          '/${_pathFor(package)}/$version',
          package,
        );
        return (
          value: _declaredLicense(fetched.json),
          answered: fetched.answered,
        );
      },
      keep: (result) => result.answered,
    );
    return result.value;
  }

  /// The licence a version document declares, in any of the three shapes npm
  /// has accepted over the years.
  ///
  /// The string form is current. The `{"type": "MIT", "url": ...}` object and
  /// the `licenses: [...]` array are both long deprecated but remain in
  /// published metadata for anything old enough to matter.
  static String? _declaredLicense(Map<String, dynamic>? doc) {
    final license = doc?['license'];
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

  Future<_Packument?> _packument(String package) async {
    final result = await _packuments.run(
      package,
      () async {
        final fetched = await _getJson(
          '/${_pathFor(package)}',
          package,
          accept: _abbreviated,
        );
        return (
          value:
              fetched.json == null ? null : _Packument.parse(fetched.json!),
          answered: fetched.answered,
        );
      },
      // An unreachable registry must not be remembered as a package that does
      // not exist; a 404 may be.
      keep: (result) => result.answered,
    );
    return result.value;
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

  /// GETs [path] and decodes it, reporting whether the registry answered.
  ///
  /// The answered flag is not the same as a body. A 404 is npm saying it has no
  /// such package; a timeout, a reset connection or a 502 is npm saying nothing
  /// at all. Both used to arrive as null, which was harmless while every
  /// lookup went to the network and is not now that answers are kept — an
  /// unreachable moment would otherwise be remembered as a missing package for
  /// the life of the process.
  Future<_Json> _getJson(
    String path,
    String package, {
    String? accept,
  }) async {
    if (!isValidPackageName(package)) return (json: null, answered: true);

    final http.Response response;
    try {
      response = await _client
          .get(
            Uri.parse('$baseUrl$path'),
            headers: {if (accept != null) 'Accept': accept},
          )
          .timeout(_timeout);
    } on TimeoutException {
      return (json: null, answered: false);
    } on http.ClientException {
      return (json: null, answered: false);
    }
    if (response.statusCode >= 500) return (json: null, answered: false);
    if (response.statusCode != 200) return (json: null, answered: true);

    try {
      final decoded = jsonDecode(response.body);
      return (
        json: decoded is Map<String, dynamic> ? decoded : null,
        answered: true,
      );
    } on FormatException {
      return (json: null, answered: true);
    }
  }

  void close() {
    _client.close();
    _osv.close();
  }
}

/// One GET's outcome: what npm said, and whether it said anything.
typedef _Json = ({Map<String, dynamic>? json, bool answered});

/// A cached lookup of any kind, carrying whether npm was reachable.
typedef _Fetched<T> = ({T value, bool answered});

/// What this client keeps from an abbreviated packument.
///
/// Distilled rather than held as the raw decoded JSON. The abbreviated form is
/// already far smaller than the full one, but it still carries tarball URLs,
/// integrity hashes and shrinkwrap flags for every release, and a scan of a
/// large repository holds hundreds of these documents at once on a machine with
/// a few hundred megabytes to its name. Keeping only the four things the
/// analysis reads makes the memory a package costs roughly constant instead of
/// proportional to its release history.
class _Packument {
  const _Packument({
    required this.latest,
    required this.versions,
    required this.dependencyNames,
    required this.sizes,
  });

  /// `dist-tags.latest`, which is what npm means by the current release.
  final String? latest;

  /// Every published version with the constraints resolution can use.
  final List<PackageVersion> versions;

  /// Version -> the names in its `dependencies`.
  ///
  /// Not the same set as [PackageVersion.dependencies]: a graph edge exists
  /// whether or not the specifier is a range resolution can follow, and
  /// optional dependencies install but are not edges the report claims.
  final Map<String, List<String>> dependencyNames;

  /// Version -> the weight npm recorded, for the releases that carry one.
  final Map<String, PackageSize> sizes;

  static _Packument parse(Map<String, dynamic> json) {
    // Read defensively rather than cast. Everything in a packument is
    // publisher-supplied and the registry has served every field shape someone
    // has ever managed to publish.
    final tags = json['dist-tags'];
    final latest = tags is Map ? tags['latest'] : null;

    final versions = <PackageVersion>[];
    final dependencyNames = <String, List<String>>{};
    final sizes = <String, PackageSize>{};

    final published = json['versions'];
    if (published is Map<String, dynamic>) {
      for (final entry in published.entries) {
        final doc = entry.value;
        if (doc is! Map<String, dynamic>) continue;

        final deps = doc['dependencies'];
        dependencyNames[entry.key] =
            deps is Map<String, dynamic> ? deps.keys.toList() : const [];

        final size = _sizeOf(doc);
        if (size != null) sizes[entry.key] = size;

        final Version version;
        try {
          version = Version.parse(entry.key);
        } on FormatException {
          // Not resolvable, but still nameable: the edges and the size above
          // are keyed by the string npm published, so they stand.
          continue;
        }

        versions.add(
          PackageVersion(
            version: version,
            sdkConstraint: _nodeEngine(doc['engines']),
            dependencies: _resolvableDependencies(doc),
          ),
        );
      }
    }

    return _Packument(
      latest: latest?.toString(),
      versions: versions,
      dependencyNames: dependencyNames,
      sizes: sizes,
    );
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
  static Map<String, String> _resolvableDependencies(Map<String, dynamic> doc) {
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

  static PackageSize? _sizeOf(Map<String, dynamic> doc) {
    // Publisher-supplied, like everything else in a packument: read
    // defensively rather than cast.
    final dist = doc['dist'];
    if (dist is! Map) return null;

    final bytes = _positiveInt(dist['unpackedSize']);
    if (bytes == null) return null;

    return PackageSize(
      bytes: bytes,
      basis: SizeBasis.unpacked,
      fileCount: _positiveInt(dist['fileCount']),
    );
  }

  /// A non-negative integer from a JSON number that a registry has, in
  /// practice, served as a string often enough to be worth tolerating.
  static int? _positiveInt(Object? raw) {
    final value = switch (raw) {
      final int i => i,
      final num n => n.toInt(),
      final String s => int.tryParse(s),
      _ => null,
    };
    return value != null && value >= 0 ? value : null;
  }
}
