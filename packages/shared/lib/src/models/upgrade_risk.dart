import 'package:pub_semver/pub_semver.dart';

import 'dep_node.dart';

/// How disruptive moving a dependency to its latest version is likely to be.
///
/// Derived from semver alone. It says what the *publisher* declared about
/// compatibility — it cannot say whether a particular project's code breaks,
/// which would need that code to be analyzed or its tests run.
enum UpgradeRisk {
  /// Already on the latest version.
  none,

  /// Backwards-compatible bug fixes.
  patch,

  /// New functionality, backwards compatible.
  minor,

  /// A breaking change, declared by the author.
  breaking,

  /// Versions could not be compared.
  unknown,
}

/// What is known about upgrading one dependency.
class UpgradeAssessment {
  const UpgradeAssessment({
    required this.risk,
    required this.withinConstraint,
    required this.summary,
    this.changelogUrl,
  });

  final UpgradeRisk risk;

  /// Whether the latest version already satisfies the declared constraint.
  ///
  /// When true the upgrade needs nothing but a `pub upgrade`. When false the
  /// constraint in `pubspec.yaml` has to be widened first, which is the real
  /// signal that a human should read the changelog.
  final bool withinConstraint;

  /// One sentence describing what the move involves.
  final String summary;

  /// Where the author documents the change, when the package is on pub.dev.
  final String? changelogUrl;

  bool get needsAttention => risk == UpgradeRisk.breaking;
}

/// Assesses moving [node] from its installed version to the latest published.
///
/// Treats `0.x` the way pub does: below 1.0.0 a change in the minor component
/// is breaking, so `0.13.0 -> 0.14.0` is not a routine bump.
UpgradeAssessment assessUpgrade(DepNode node) {
  final installed = _tryParse(node.installed);
  final latest = node.latest == null ? null : _tryParse(node.latest!);

  if (installed == null || latest == null) {
    return const UpgradeAssessment(
      risk: UpgradeRisk.unknown,
      withinConstraint: false,
      summary: 'No version to compare — nothing can be said about upgrading.',
    );
  }

  final changelog = 'https://pub.dev/packages/${node.name}/changelog';

  if (latest <= installed) {
    return UpgradeAssessment(
      risk: UpgradeRisk.none,
      withinConstraint: true,
      summary: 'Already on the latest published version.',
      changelogUrl: changelog,
    );
  }

  final constraint =
      node.constraint == null ? null : _tryConstraint(node.constraint!);
  // With no declared constraint the package is transitive: whether it can move
  // is decided by whichever package depends on it, not by this project.
  final within = constraint?.allows(latest) ?? false;

  final risk = _risk(installed, latest);
  return UpgradeAssessment(
    risk: risk,
    withinConstraint: within,
    summary: _summarise(risk, within, node),
    changelogUrl: changelog,
  );
}

UpgradeRisk _risk(Version from, Version to) {
  if (from.major != to.major) return UpgradeRisk.breaking;
  // Pre-1.0, the minor component carries breaking changes.
  if (from.major == 0) {
    return from.minor != to.minor ? UpgradeRisk.breaking : UpgradeRisk.patch;
  }
  if (from.minor != to.minor) return UpgradeRisk.minor;
  return UpgradeRisk.patch;
}

String _summarise(UpgradeRisk risk, bool within, DepNode node) {
  final latest = node.latest;
  switch (risk) {
    case UpgradeRisk.breaking:
      final lead = node.installed.startsWith('0.')
          ? 'A pre-1.0 minor bump, which pub treats as breaking'
          : 'A major version bump, which the author declares as breaking';
      return within
          ? '$lead. Your constraint already allows $latest, so this can happen '
              'on the next resolve — read the changelog.'
          : '$lead. Your constraint does not allow $latest, so pubspec.yaml '
              'has to be widened deliberately.';
    case UpgradeRisk.minor:
      return within
          ? 'Backwards-compatible additions. Already allowed by your '
              'constraint, so a resolve picks it up.'
          : 'Backwards-compatible additions, but outside your constraint — '
              'widen it to take them.';
    case UpgradeRisk.patch:
      return within
          ? 'Bug fixes only. Already allowed by your constraint.'
          : 'Bug fixes only, but outside your constraint.';
    case UpgradeRisk.none:
      return 'Already on the latest published version.';
    case UpgradeRisk.unknown:
      return 'No version to compare — nothing can be said about upgrading.';
  }
}

Version? _tryParse(String raw) {
  try {
    return Version.parse(raw);
  } on FormatException {
    return null;
  }
}

VersionConstraint? _tryConstraint(String raw) {
  try {
    return VersionConstraint.parse(raw);
  } on FormatException {
    return null;
  }
}
