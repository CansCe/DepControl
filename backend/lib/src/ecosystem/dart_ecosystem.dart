import 'package:pub_semver/pub_semver.dart';
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:shared/shared.dart';
import 'package:yaml/yaml.dart';

import '../services/import_scanner.dart';
import '../services/license_catalog.dart';
import '../services/pub_api_client.dart';
import 'ecosystem.dart';
import 'osv_client.dart';

/// Dart and Flutter packages: `pubspec.yaml`, `pubspec.lock`, pub.dev.
///
/// The reference implementation of [Ecosystem] — everything here was the whole
/// of this application before a second ecosystem existed, so where the
/// interface looks shaped around pub, that is the reason and not an accident.
class DartEcosystem implements Ecosystem {
  DartEcosystem(PubApiClient pub, {OsvClient? osv})
      : registry = DartRegistry(pub, osv: osv ?? OsvClient());

  @override
  String get id => 'dart';

  @override
  String get displayName => 'Dart / Flutter';

  @override
  final DartRegistry registry;

  @override
  ManifestNaming get naming => const ManifestNaming(
        ecosystem: 'dart',
        manifest: 'pubspec.yaml',
        lockFiles: ['pubspec.lock'],
        sourceExtensions: ['.dart'],
        // A lint set is pulled in by `include:` and imported by nothing, which
        // is the only reason `lints` is not reported as unused by every project
        // that uses it.
        auxiliaryFiles: ['analysis_options.yaml'],
      );

  @override
  SourceScanner? get sourceScanner => const DartSourceScanner();

  @override
  ParsedManifest parse(ManifestFiles files) {
    final pubspec = Pubspec.parse(files.manifest);

    return ParsedManifest(
      packageName: pubspec.name,
      dependencies: _declarations(pubspec.dependencies),
      devDependencies: _declarations(pubspec.devDependencies),
      locked: files.lock == null ? const {} : _parseLock(files.lock!),
    );
  }

  @override
  VersionConstraint? parseConstraint(String text) {
    try {
      return VersionConstraint.parse(text);
    } on FormatException {
      return null;
    }
  }

  @override
  String constraintAtLeast(Version version) => '^$version';

  Map<String, DeclaredDependency> _declarations(
    Map<String, Dependency> deps,
  ) =>
      {
        for (final entry in deps.entries)
          entry.key: DeclaredDependency(
            constraint: switch (entry.value) {
              final HostedDependency hosted => hosted.version.toString(),
              final other => other.toString(),
            },
            foreignOrigin: _originOf(entry.value),
          ),
      };

  /// Where a declared dependency comes from, or null when it comes from
  /// pub.dev — the only case anything downstream needs to query.
  static String? _originOf(Dependency dependency) => switch (dependency) {
        HostedDependency() => null,
        SdkDependency() => 'the SDK',
        PathDependency() => 'a path dependency',
        GitDependency() => 'a git dependency',
      };

  /// Minimal `pubspec.lock` reader: package -> resolved version and where it
  /// came from.
  static Map<String, LockedDependency> _parseLock(String lockContent) {
    final doc = loadYaml(lockContent);
    if (doc is! YamlMap) return const {};
    final packages = doc['packages'];
    if (packages is! YamlMap) return const {};

    return {
      for (final entry in packages.entries)
        if (entry.value case final YamlMap package)
          entry.key as String: LockedDependency(
            version: package['version'] as String? ?? '(unknown)',
            foreignOrigin: _lockOrigin(package['source']?.toString()),
          ),
    };
  }

  /// Where a lockfile entry says a package came from, or null for pub.dev.
  ///
  /// An entry with no `source:` is telling us nothing, so it is taken as
  /// published — which is what a lockfile entry without a source almost always
  /// is. An entry naming a source this build does not recognise *is* saying
  /// something, and it is not saying "pub.dev".
  static String? _lockOrigin(String? source) => switch (source) {
        null || 'hosted' => null,
        'sdk' => 'the SDK',
        'path' => 'a path dependency',
        'git' => 'a git dependency',
        _ => 'outside pub.dev',
      };
}

/// pub.dev, behind the [PackageRegistry] interface.
///
/// Thin: [PubApiClient] already speaks the protocol. What lives here is the
/// part that was previously spread between the client and the analyzer —
/// deciding which of pub.dev's two license analyses to believe, and saying so.
class DartRegistry implements PackageRegistry {
  const DartRegistry(this._pub, {required OsvClient osv}) : _osv = osv;

  final PubApiClient _pub;

  /// Advisories, which no longer come from pub.dev — see [info].
  final OsvClient _osv;

  /// OSV's name for this ecosystem. Case-sensitive, and not [Ecosystem.id].
  static const osvEcosystem = 'Pub';

  @override
  bool isValidPackageName(String name) => PubApiClient.isPackageName(name);

  /// The latest version from pub.dev, and the advisories from OSV.
  ///
  /// pub.dev serves advisories too, and this used to take them from there. Two
  /// reasons it no longer does.
  ///
  /// The first is that npm has no equivalent endpoint, so OSV had to be spoken
  /// to anyway; having one advisory path rather than two means the version
  /// matching, the CVSS scoring and the banding are exercised by every test in
  /// either ecosystem instead of half of them each.
  ///
  /// The second is that pub.dev's endpoint is **wrong** in a way that matters.
  /// It serves withdrawn advisories alongside live ones: asking it about `dio`
  /// returns `GHSA-jwpw-q68h-r678`, retracted in October 2023, with nothing in
  /// the response marking it as different from the real advisory beside it.
  /// OSV excludes withdrawn entries from a query, and [Advisory.affects] now
  /// refuses them besides. Checked package by package before the switch: the
  /// two sources agree on every live advisory, field for field, and disagree
  /// only where pub.dev is serving something its own upstream has taken back.
  @override
  Future<RegistryInfo> info(String package) async {
    if (!isValidPackageName(package)) return const RegistryInfo(latest: null);

    return RegistryInfo(
      latest: await _pub.latestVersion(package),
      advisories: await _osv.advisoriesFor(package, ecosystem: osvEcosystem),
    );
  }

  @override
  Future<List<PackageVersion>> versions(String package) =>
      _pub.versions(package);

  @override
  Future<List<String>> dependencyNames(String package, String version) =>
      _pub.dependencyNames(package, version);

  /// The license of the installed version, from pub.dev's analysis of it.
  ///
  /// Falls back to the latest release's analysis, which is what pub.dev still
  /// has for a package whose installed version is old enough that its analysis
  /// has been dropped. The fallback turns on the absence of a `license:` tag
  /// rather than on an empty response, because a version whose analysis was
  /// dropped still answers with *other* tags — publisher, `is:obsolete` — and
  /// only [LicenseCatalog] can draw that distinction.
  @override
  Future<PackageLicense> licenseFor(
    String package,
    String installed,
    String? latest,
  ) async {
    final exact = LicenseCatalog.read(
      await _pub.versionTags(package, installed),
      source: LicenseSource.installedVersion,
      readFromVersion: installed,
    );
    if (exact != null) return exact;

    final fromLatest = LicenseCatalog.read(
      await _pub.latestTags(package),
      source: LicenseSource.latestRelease,
      readFromVersion: latest,
    );
    return fromLatest ?? PackageLicense.undetermined;
  }
}

/// [ImportScanner] behind the [SourceScanner] interface.
class DartSourceScanner implements SourceScanner {
  const DartSourceScanner();

  @override
  Set<String> scan(
    Iterable<String> sources, {
    Iterable<String> auxiliary = const [],
  }) =>
      ImportScanner.scan(sources, optionsFiles: auxiliary);
}
