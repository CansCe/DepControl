/// How one dependency's requirements change between two versions.
enum DependencyDeltaKind { added, removed, changed }

/// A single difference in what a package requires of its own dependencies.
class DependencyDelta {
  const DependencyDelta({
    required this.package,
    required this.kind,
    this.before,
    this.after,
  });

  final String package;
  final DependencyDeltaKind kind;

  /// Constraint in the installed version, null when newly added.
  final String? before;

  /// Constraint in the target version, null when dropped.
  final String? after;

  factory DependencyDelta.fromJson(Map<String, dynamic> json) =>
      DependencyDelta(
        package: json['package'] as String,
        kind: DependencyDeltaKind.values.byName(json['kind'] as String),
        before: json['before'] as String?,
        after: json['after'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'package': package,
        'kind': kind.name,
        'before': before,
        'after': after,
      };
}

/// What actually changes in a package's contract between two versions.
///
/// These are the causes that can be established from published metadata: which
/// breaking boundaries the jump crosses, whether it demands a newer Dart SDK
/// than the project allows, and how its own requirements shift. It does not
/// describe API changes — those live in prose in the changelog, which is
/// linked rather than summarised.
class UpgradeImpact {
  const UpgradeImpact({
    required this.package,
    required this.from,
    required this.to,
    this.majorVersionsCrossed = const [],
    this.releasesBetween = 0,
    this.sdkBefore,
    this.sdkAfter,
    this.projectSdk,
    this.sdkTooNew = false,
    this.dependencyChanges = const [],
    this.changelogUrl,
  });

  final String package;
  final String from;
  final String to;

  /// Breaking boundaries the jump passes, e.g. `2.0.0` and `3.0.0` when going
  /// from 1.9.0 to 3.1.0. More boundaries means more accumulated change.
  final List<String> majorVersionsCrossed;

  /// How many releases sit between the two versions.
  final int releasesBetween;

  /// Dart SDK constraint declared by each version.
  final String? sdkBefore;
  final String? sdkAfter;

  /// The SDK constraint the project itself declares.
  final String? projectSdk;

  /// True when the target version needs a newer SDK than the project allows —
  /// a concrete blocker rather than a risk.
  final bool sdkTooNew;

  /// Differences in what the package requires of other packages.
  final List<DependencyDelta> dependencyChanges;

  final String? changelogUrl;

  bool get hasFindings =>
      majorVersionsCrossed.isNotEmpty ||
      sdkTooNew ||
      dependencyChanges.isNotEmpty;

  factory UpgradeImpact.fromJson(Map<String, dynamic> json) => UpgradeImpact(
        package: json['package'] as String,
        from: json['from'] as String,
        to: json['to'] as String,
        majorVersionsCrossed:
            ((json['majorVersionsCrossed'] as List?) ?? const [])
                .map((e) => e.toString())
                .toList(),
        releasesBetween: (json['releasesBetween'] as int?) ?? 0,
        sdkBefore: json['sdkBefore'] as String?,
        sdkAfter: json['sdkAfter'] as String?,
        projectSdk: json['projectSdk'] as String?,
        sdkTooNew: (json['sdkTooNew'] as bool?) ?? false,
        dependencyChanges: ((json['dependencyChanges'] as List?) ?? const [])
            .map((e) => DependencyDelta.fromJson(e as Map<String, dynamic>))
            .toList(),
        changelogUrl: json['changelogUrl'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'package': package,
        'from': from,
        'to': to,
        'majorVersionsCrossed': majorVersionsCrossed,
        'releasesBetween': releasesBetween,
        'sdkBefore': sdkBefore,
        'sdkAfter': sdkAfter,
        'projectSdk': projectSdk,
        'sdkTooNew': sdkTooNew,
        'dependencyChanges': dependencyChanges.map((d) => d.toJson()).toList(),
        'changelogUrl': changelogUrl,
      };
}
