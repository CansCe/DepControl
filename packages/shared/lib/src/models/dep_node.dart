import 'dep_advisory.dart';
import 'package_license.dart';

/// How a dependency is pulled into the project.
enum DepKind { direct, dev, transitive }

/// Whether a newer version exists / a security advisory applies.
enum DepStatus { upToDate, outdated, vulnerable, unknown }

/// Where a dependency's [DepNode.installed] version came from.
///
/// Distinguishes fact from inference: a lockfile records what is actually
/// installed, whereas a constraint only tells us what `pub get` would pick
/// today, which may differ from what a developer has on disk.
enum DepSource {
  /// Read from `pubspec.lock` — authoritative.
  lockfile,

  /// Inferred by resolving the declared constraint against pub.dev.
  constraint,

  /// No version could be determined.
  unresolved,
}

/// A single resolved dependency in a project's tree.
class DepNode {
  const DepNode({
    required this.name,
    required this.kind,
    required this.installed,
    this.constraint,
    this.latest,
    this.status = DepStatus.unknown,
    this.source = DepSource.unresolved,
    this.advisories = const [],
    this.license,
    this.dependencies = const [],
    this.manifests = const [],
    this.imported,
  });

  /// Identity within a report: two versions of one package are two entries.
  String get key => '$name@$installed';

  /// A copy carrying [manifests].
  DepNode inManifests(List<String> manifests) => DepNode(
        name: name,
        kind: kind,
        installed: installed,
        constraint: constraint,
        latest: latest,
        status: status,
        source: source,
        advisories: advisories,
        license: license,
        dependencies: dependencies,
        manifests: manifests,
        imported: imported,
      );

  final String name;
  final DepKind kind;

  /// Version currently locked in `pubspec.lock`.
  final String installed;

  /// The constraint from `pubspec.yaml` (null for purely transitive deps).
  final String? constraint;

  /// Latest version on pub.dev, if known.
  final String? latest;

  final DepStatus status;

  /// Whether [installed] is a fact from the lockfile or inferred from the
  /// constraint. Surfaced so a report never presents a guess as a measurement.
  final DepSource source;

  /// Security advisories affecting [installed], if any.
  final List<DepAdvisory> advisories;

  /// The license this version is published under, as pub.dev identified it.
  ///
  /// Null means nobody looked — a report generated before license scanning
  /// existed. That is deliberately not the same value as a scan that came back
  /// unidentified ([PackageLicense.undetermined]), because a compliance report
  /// must not present "not checked" as "checked and found nothing".
  final PackageLicense? license;

  /// Direct children (names) in the dependency graph.
  final List<String> dependencies;

  /// Which of the repository's pubspecs resolve this package at this version.
  /// Empty for a single-package repository, where there is nothing to
  /// disambiguate.
  ///
  /// A repository can resolve the same package at two versions — a directory
  /// kept out of the pub workspace resolves separately — and those are two
  /// different things to assess, since an advisory applies to a version.
  final List<String> manifests;

  /// Whether any of the repository's own Dart source imports this package.
  ///
  /// Null means the source was never read — a report from a scan that could
  /// only reach the manifests. That is not the same as false, which is a
  /// measurement, and the two must not be shown alike: false on a declared
  /// dependency says nothing in the project uses it, and null says nobody
  /// checked.
  ///
  /// True on a transitive dependency is the more urgent reading. The project
  /// imports a package it never declared, so it compiles only for as long as
  /// something else keeps pulling that package in — and nothing in the pubspec
  /// will warn about the upgrade that stops it.
  final bool? imported;

  factory DepNode.fromJson(Map<String, dynamic> json) {
    return DepNode(
      name: json['name'] as String,
      kind: DepKind.values.byName(json['kind'] as String),
      installed: json['installed'] as String,
      constraint: json['constraint'] as String?,
      latest: json['latest'] as String?,
      status: DepStatus.values.byName(
        (json['status'] as String?) ?? 'unknown',
      ),
      source: DepSource.values.byName(
        (json['source'] as String?) ?? 'unresolved',
      ),
      advisories: _advisoriesFrom(json['advisories']),
      license: switch (json['license']) {
        final Map license =>
          PackageLicense.fromJson(license.cast<String, dynamic>()),
        _ => null,
      },
      dependencies:
          (json['dependencies'] as List?)?.cast<String>() ?? const [],
      manifests: (json['manifests'] as List?)?.cast<String>() ?? const [],
      imported: json['imported'] as bool?,
    );
  }

  /// Reads the advisory list, tolerating reports stored before advisories
  /// carried anything but an id.
  ///
  /// Those rows are plain strings in the `dep_reports` jsonb. Dropping them
  /// would quietly turn a stored report's vulnerable packages into clean ones,
  /// which is the worst direction for this particular field to fail in.
  static List<DepAdvisory> _advisoriesFrom(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final entry in raw)
        if (entry is String)
          DepAdvisory(id: entry)
        else if (entry is Map)
          DepAdvisory.fromJson(entry.cast<String, dynamic>()),
    ];
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'kind': kind.name,
        'installed': installed,
        'constraint': constraint,
        'latest': latest,
        'status': status.name,
        'source': source.name,
        'advisories': advisories.map((a) => a.toJson()).toList(),
        // Omitted rather than written as null, so a stored report keeps saying
        // "never scanned" instead of acquiring an empty license field.
        if (license != null) 'license': license!.toJson(),
        'dependencies': dependencies,
        if (manifests.isNotEmpty) 'manifests': manifests,
        // Omitted rather than written as null, so a report stored before import
        // scanning keeps reading back as "never scanned".
        if (imported != null) 'imported': imported,
      };
}
