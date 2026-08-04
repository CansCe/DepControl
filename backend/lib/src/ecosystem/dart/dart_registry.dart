import 'package:ecosystem/ecosystem.dart';
import 'package:shared/shared.dart';

import '../../services/license_catalog.dart';
import '../../services/pub_api_client.dart';
import '../osv_client.dart';
import '../package_registry.dart';

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
  ///
  /// The two are asked at once. They are different hosts answering unrelated
  /// questions, so awaiting one before starting the other spent a round trip
  /// per package for nothing.
  @override
  Future<RegistryInfo> info(String package) async {
    if (!isValidPackageName(package)) return const RegistryInfo(latest: null);

    final (latest, advisories) = await (
      _pub.latestVersion(package),
      _osv.advisoriesFor(package, ecosystem: osvEcosystem),
    ).wait;

    return RegistryInfo(latest: latest, advisories: advisories);
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

  /// The compressed archive size, because pub.dev publishes no installed one.
  ///
  /// Reported as [SizeBasis.archive] rather than converted: source compresses
  /// somewhere between two and five times depending on what the package is
  /// mostly made of, and multiplying by a guess would turn a measured number
  /// into an invented one. `(unresolved)` and other non-versions never reach
  /// the network — there is no archive to ask about.
  ///
  /// No file count: a HEAD reports the archive's length and nothing about what
  /// is inside it, and opening the tarball to count would mean downloading
  /// every dependency of every project on every scan.
  @override
  Future<PackageSize?> sizeOf(String package, String version) async {
    if (!isValidPackageName(package)) return null;

    final bytes = await _pub.archiveSizeBytes(package, version);
    return bytes == null
        ? null
        : PackageSize(bytes: bytes, basis: SizeBasis.archive);
  }
}
