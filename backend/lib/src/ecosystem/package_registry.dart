import 'package:pub_semver/pub_semver.dart';
import 'package:shared/shared.dart';

/// The registry half of an [Ecosystem]: everything the analysis needs to know
/// about a package that is not in the repository being scanned.
///
/// The types here were pub.dev's and are now nobody's in particular. That was
/// not much of a move: advisories were already OSV documents, which is a
/// cross-ecosystem format by design, and versions were already semver, which
/// npm and pub share. What was genuinely pub-specific — the URL shapes, the
/// analysis-tag vocabulary licenses are read from — stays behind the
/// [PackageRegistry] interface with the client that speaks it.

/// A security advisory published for a package, in OSV shape.
///
/// An advisory applies to specific versions, not to the package as a whole, so
/// [affects] must be consulted before reporting a dependency as vulnerable.
class Advisory {
  const Advisory({
    required this.id,
    this.aliases = const [],
    this.summary,
    this.affectedVersions = const {},
    this.ranges = const [],
    this.cvssVector,
    this.databaseSeverity,
    this.withdrawn,
  });

  final String id;

  /// Other identifiers for the same issue, e.g. `CVE-2020-35669`.
  final List<String> aliases;
  final String? summary;

  /// Exact versions the database lists as affected. Authoritative when present.
  final Set<String> affectedVersions;

  /// Version ranges, used when no explicit version list is published.
  final List<AdvisoryRange> ranges;

  /// The CVSS v3 base vector, when one was published. Scored by [CvssV3].
  final String? cvssVector;

  /// The publishing database's own band — GitHub writes `MODERATE` where CVSS
  /// says medium. Used only when there is no vector to score.
  final String? databaseSeverity;

  /// When this advisory was retracted, or null while it stands.
  ///
  /// OSV publishes `withdrawn` for an advisory its database has taken back —
  /// wrongly filed, a duplicate, or a disputed report that did not hold up.
  /// A withdrawn advisory is not a weaker finding; it is the database saying
  /// the finding was never right.
  ///
  /// This is not theoretical. pub.dev's `/advisories` endpoint serves withdrawn
  /// entries alongside live ones: `dio` comes back with
  /// `GHSA-jwpw-q68h-r678`, retracted in October 2023, and nothing in the
  /// response distinguishes it from the real advisory beside it. OSV's own
  /// query endpoint filters them out, so this field is belt and braces — but
  /// the belt is what was missing, and reporting a package as vulnerable to a
  /// retracted advisory is the kind of wrong answer that teaches people to
  /// ignore the report.
  final DateTime? withdrawn;

  /// Whether this advisory has been retracted by its database.
  bool get isWithdrawn => withdrawn != null;

  /// Whether [version] is actually affected by this advisory.
  bool affects(Version version) {
    // A retracted advisory affects nothing. Checked before the ranges rather
    // than filtered by the caller, so no caller can forget.
    if (isWithdrawn) return false;

    if (affectedVersions.isNotEmpty) {
      return affectedVersions.contains(version.toString());
    }
    if (ranges.isEmpty) return false;
    return ranges.any((r) => r.contains(version));
  }

  /// The version this advisory says fixes [version], from the OSV ranges.
  ///
  /// Only the range actually covering [version] can answer: an advisory may
  /// carry several `[introduced, fixed)` windows across different release
  /// lines, and the fix for the 2.x line says nothing to someone on 1.x.
  ///
  /// Null when the advisory listed affected versions individually, or left a
  /// range open — in OSV that means no fix has been published yet.
  Version? fixedVersionFor(Version version) {
    Version? best;
    for (final range in ranges) {
      final fixed = range.fixed;
      if (fixed == null || !range.contains(version)) continue;
      if (best == null || fixed < best) best = fixed;
    }
    return best;
  }

  static Advisory? fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString();
    if (id == null) return null;

    final affected = (json['affected'] as List?) ?? const [];
    final versions = <String>{};
    final ranges = <AdvisoryRange>[];

    for (final entry in affected.whereType<Map<String, dynamic>>()) {
      versions.addAll(
        ((entry['versions'] as List?) ?? const []).map((v) => v.toString()),
      );
      for (final range in ((entry['ranges'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()) {
        ranges.addAll(AdvisoryRange.fromEvents(range['events'] as List?));
      }
    }

    return Advisory(
      id: id,
      aliases:
          ((json['aliases'] as List?) ?? const []).map((a) => '$a').toList(),
      summary: json['summary']?.toString(),
      affectedVersions: versions,
      ranges: ranges,
      cvssVector: _cvssVector(json['severity']),
      databaseSeverity: (json['database_specific'] as Map<String, dynamic>?)?[
              'severity']
          ?.toString(),
      withdrawn: switch (json['withdrawn']) {
        final String s => DateTime.tryParse(s),
        _ => null,
      },
    );
  }

  /// The CVSS v3 vector from an OSV `severity` array.
  ///
  /// The array may carry several scoring systems. v3 is the one taken: it is
  /// what practically every advisory in these ecosystems publishes, and mixing
  /// scales would make the numbers incomparable across packages.
  static String? _cvssVector(Object? severity) {
    if (severity is! List) return null;
    for (final entry in severity.whereType<Map<String, dynamic>>()) {
      if (entry['type'] == 'CVSS_V3') return entry['score']?.toString();
    }
    return null;
  }
}

/// A half-open version range `[introduced, fixed)`, as described by OSV events.
class AdvisoryRange {
  const AdvisoryRange({this.introduced, this.fixed, this.lastAffected});

  final Version? introduced;
  final Version? fixed;
  final Version? lastAffected;

  bool contains(Version version) {
    if (introduced != null && version < introduced!) return false;
    if (fixed != null && version >= fixed!) return false;
    if (lastAffected != null && version > lastAffected!) return false;
    return true;
  }

  /// Walks an OSV `events` array, which is an ordered stream of `introduced`
  /// and `fixed`/`last_affected` markers rather than a list of range objects.
  static List<AdvisoryRange> fromEvents(List<dynamic>? events) {
    if (events == null) return const [];

    final ranges = <AdvisoryRange>[];
    Version? introduced;
    var open = false;

    for (final event in events.whereType<Map<String, dynamic>>()) {
      if (event['introduced'] != null) {
        introduced = _parse('${event['introduced']}');
        open = true;
      }
      if (event['fixed'] != null) {
        ranges.add(
          AdvisoryRange(
            introduced: introduced,
            fixed: _parse('${event['fixed']}'),
          ),
        );
        open = false;
      } else if (event['last_affected'] != null) {
        ranges.add(
          AdvisoryRange(
            introduced: introduced,
            lastAffected: _parse('${event['last_affected']}'),
          ),
        );
        open = false;
      }
    }

    // An `introduced` with no closing event means everything from there on.
    if (open) ranges.add(AdvisoryRange(introduced: introduced));
    return ranges;
  }

  /// OSV uses `"0"` to mean "from the beginning", which is not valid semver.
  static Version? _parse(String raw) {
    if (raw == '0') return Version.none;
    try {
      return Version.parse(raw);
    } on FormatException {
      return null;
    }
  }
}

/// One published version of a package, with the dependency constraints that
/// version declares.
class PackageVersion {
  const PackageVersion({
    required this.version,
    this.dependencies = const {},
    this.sdkConstraint,
  });

  final Version version;

  /// The runtime range this version demands — `environment.sdk` in a pubspec,
  /// `engines.node` in a `package.json`. A version demanding a newer runtime
  /// than the project allows cannot be taken.
  final String? sdkConstraint;

  /// Regular (non-dev) dependencies: package name -> constraint string. Only
  /// constraints the registry can resolve appear; git/path/SDK entries are
  /// dropped because there are no published versions to resolve them against.
  final Map<String, String> dependencies;
}

/// Latest version + advisory info for a package.
class RegistryInfo {
  const RegistryInfo({required this.latest, this.advisories = const []});

  final String? latest;

  /// Every advisory published for the package, unfiltered. Callers must use
  /// [Advisory.affects] to decide which apply to the version in use.
  final List<Advisory> advisories;
}

/// Where an ecosystem's published packages are looked up.
///
/// One instance per ecosystem, holding whatever HTTP client and base URL that
/// ecosystem's registry needs. Implementations are expected to be polite API
/// clients — the analyzer already bounds its concurrency, but caching and
/// request shaping belong here.
abstract class PackageRegistry {
  /// Whether [name] is a legal package name in this ecosystem.
  ///
  /// Not a nicety: names arrive from manifests fetched off the internet and are
  /// interpolated into request paths. A name like `../../admin` normalises the
  /// API prefix away and issues a request nobody asked for, so this is
  /// validation rather than escaping — a name that is not legal is not a
  /// package, and there is nothing to look up.
  bool isValidPackageName(String name);

  /// The latest published version and every advisory for [package].
  Future<RegistryInfo> info(String package);

  /// Published versions of [package], for resolution and for finding the
  /// lowest release above a vulnerable one.
  Future<List<PackageVersion>> versions(String package);

  /// The regular dependency names [package] at [version] declares, for graph
  /// edges. Empty for versions the registry does not know.
  Future<List<String>> dependencyNames(String package, String version);

  /// The license [package] is published under at [installed].
  ///
  /// Takes [latest] as well because a registry may hold no answer for an old
  /// version — pub.dev keeps one analysis per version and drops the rest — and
  /// the latest release is the honest fallback. The returned
  /// [PackageLicense.source] records which of the two was read, since a
  /// relicensing between the installed version and today is exactly what a
  /// compliance report exists to notice.
  ///
  /// Returns [PackageLicense.undetermined] rather than null when the registry
  /// has nothing: null on a node means nobody ever looked, and somebody just
  /// did.
  Future<PackageLicense> licenseFor(
    String package,
    String installed,
    String? latest,
  );

  /// What [package] at [version] weighs, or null where the registry does not
  /// say.
  ///
  /// Null is the common answer rather than the exceptional one, and callers
  /// must treat it as "not measured" rather than as zero. npm records
  /// `unpackedSize` only for versions published since it started to, which
  /// leaves most releases of the small old packages a tree is full of; pub.dev
  /// publishes no size at all, so its figure is the compressed archive and
  /// costs a request that can fail on its own.
  ///
  /// The returned [PackageSize] carries the [SizeBasis] it was measured on,
  /// because the two registries are not answering the same question.
  Future<PackageSize?> sizeOf(String package, String version);
}
