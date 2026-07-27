import 'package:pub_semver/pub_semver.dart';
import 'package:shared/shared.dart';

import 'pub_api_client.dart';

/// Works out what actually changes when a package moves between two versions.
///
/// Everything here comes from published metadata, so each finding is a fact
/// rather than a guess: the breaking boundaries the jump crosses, whether the
/// target needs a newer Dart SDK than the project allows, and how the package's
/// own requirements shift.
///
/// It deliberately says nothing about API changes. Those are described in prose
/// in a changelog, and paraphrasing prose is where a tool starts inventing
/// things — so the changelog is linked instead.
class UpgradeInspector {
  UpgradeInspector(this._pub);

  final PubApiClient _pub;

  /// Compares [package] at [from] against [to] (defaulting to the newest).
  ///
  /// [projectSdk] is the project's own `environment.sdk`, used to decide
  /// whether the target version is reachable at all.
  Future<UpgradeImpact?> inspect(
    String package, {
    required String from,
    String? to,
    String? projectSdk,
  }) async {
    final current = _tryVersion(from);
    if (current == null) return null;

    final versions = await _pub.versions(package);
    if (versions.isEmpty) return null;

    final stable = versions.where((v) => !v.version.isPreRelease).toList()
      ..sort((a, b) => a.version.compareTo(b.version));
    if (stable.isEmpty) return null;

    final target = to == null
        ? stable.last
        : _findVersion(stable, _tryVersion(to));
    if (target == null || target.version <= current) return null;

    final installed = _findVersion(stable, current);

    // Releases strictly between the two, and the major boundaries crossed.
    final between = stable
        .where((v) => v.version > current && v.version <= target.version)
        .toList();

    final crossed = <String>[];
    for (final candidate in between) {
      final v = candidate.version;
      final isBoundary = v.major > current.major ||
          // Below 1.0.0 the minor component carries breaking changes.
          (current.major == 0 && v.major == 0 && v.minor > current.minor);
      if (!isBoundary) continue;

      final label = v.major > 0 ? '${v.major}.0.0' : '0.${v.minor}.0';
      if (!crossed.contains(label)) crossed.add(label);
    }

    final sdkAfter = target.sdkConstraint;
    return UpgradeImpact(
      package: package,
      from: from,
      to: target.version.toString(),
      majorVersionsCrossed: crossed,
      releasesBetween: between.length,
      sdkBefore: installed?.sdkConstraint,
      sdkAfter: sdkAfter,
      projectSdk: projectSdk,
      sdkTooNew: _sdkTooNew(projectSdk, sdkAfter),
      dependencyChanges: _diffDependencies(
        installed?.dependencies ?? const {},
        target.dependencies,
      ),
      changelogUrl: 'https://pub.dev/packages/$package/changelog',
    );
  }

  /// Whether [required] demands an SDK the project's own [declared] range
  /// cannot provide.
  ///
  /// Compares lower bounds: a package needing `>=3.8.0` is out of reach for a
  /// project declaring `^3.6.0`, because that project supports SDKs the package
  /// refuses.
  static bool _sdkTooNew(String? declared, String? required) {
    if (declared == null || required == null) return false;
    final projectRange = _tryConstraint(declared);
    final packageRange = _tryConstraint(required);
    if (projectRange is! VersionRange || packageRange is! VersionRange) {
      return false;
    }

    final projectMin = projectRange.min;
    final packageMin = packageRange.min;
    if (projectMin == null || packageMin == null) return false;

    return packageMin > projectMin;
  }

  List<DependencyDelta> _diffDependencies(
    Map<String, String> before,
    Map<String, String> after,
  ) {
    final changes = <DependencyDelta>[];

    for (final entry in after.entries) {
      final previous = before[entry.key];
      if (previous == null) {
        changes.add(
          DependencyDelta(
            package: entry.key,
            kind: DependencyDeltaKind.added,
            after: entry.value,
          ),
        );
      } else if (previous != entry.value) {
        changes.add(
          DependencyDelta(
            package: entry.key,
            kind: DependencyDeltaKind.changed,
            before: previous,
            after: entry.value,
          ),
        );
      }
    }

    for (final entry in before.entries) {
      if (after.containsKey(entry.key)) continue;
      changes.add(
        DependencyDelta(
          package: entry.key,
          kind: DependencyDeltaKind.removed,
          before: entry.value,
        ),
      );
    }

    changes.sort((a, b) => a.package.compareTo(b.package));
    return changes;
  }

  PackageVersion? _findVersion(List<PackageVersion> versions, Version? target) {
    if (target == null) return null;
    for (final candidate in versions) {
      if (candidate.version == target) return candidate;
    }
    return null;
  }

  static Version? _tryVersion(String raw) {
    try {
      return Version.parse(raw);
    } on FormatException {
      return null;
    }
  }

  static VersionConstraint? _tryConstraint(String raw) {
    try {
      return VersionConstraint.parse(raw);
    } on FormatException {
      return null;
    }
  }
}
