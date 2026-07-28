import 'dep_advisory.dart';
import 'resolution_result.dart';

/// How a remediation gets the fixed version into the project.
enum RemediationKind {
  /// The project declares the vulnerable package: raise its constraint.
  raiseConstraint,

  /// The project does not declare it, but bumping the dependency that pulls it
  /// in reaches a fixed version. The tidiest fix for a transitive problem.
  bumpParent,

  /// Nothing the project declares reaches a fixed version, so the vulnerable
  /// package is promoted to a direct dependency with a floor.
  ///
  /// This works, but it is a pin on someone else's dependency and it will need
  /// removing later — [Remediation.caveat] says so.
  promoteToDirect,
}

/// Why no remediation could be offered.
enum RemediationBlocker {
  /// The advisory names no fixed version, so there is nothing to move to.
  noFixPublished,

  /// A fix exists, but no change to this pubspec reaches it — usually because
  /// something else in the project pins the vulnerable package down.
  unreachable,
}

/// A concrete, verified change to `pubspec.yaml` that clears one advisory.
///
/// Every remediation here has been run through the resolver: it is offered
/// because the resulting version set actually contains a fixed version, not
/// because the arithmetic on the constraint looked right. An unverifiable idea
/// is reported as a [blocker] instead of as a suggestion — a fix that does not
/// resolve costs more time than no suggestion at all.
class Remediation {
  const Remediation({
    required this.package,
    required this.advisoryIds,
    this.kind,
    this.editPackage,
    this.fromConstraint,
    this.toConstraint,
    this.resolves = const [],
    this.blocker,
    this.caveat,
  });

  /// The vulnerable package this clears.
  final String package;

  /// Advisories on [package] that this change resolves.
  final List<String> advisoryIds;

  /// How the fix works. Null when [blocker] is set.
  final RemediationKind? kind;

  /// The package whose constraint changes in `pubspec.yaml`. The same as
  /// [package] except for [RemediationKind.bumpParent], where it is the
  /// dependency that pulls the vulnerable one in.
  final String? editPackage;

  /// [editPackage]'s constraint now — null when it is being added.
  final String? fromConstraint;

  /// [editPackage]'s constraint after the change.
  final String? toConstraint;

  /// What the resolution moves as a result, [package] included. This is the
  /// real cost of the fix: one advisory can drag a dozen packages with it.
  final List<VersionChange> resolves;

  /// Why there is no change to offer.
  final RemediationBlocker? blocker;

  /// Something true about this fix that the diff does not show — that it is a
  /// major bump, or a pin someone will have to undo.
  final String? caveat;

  bool get isActionable => blocker == null && kind != null;

  /// The version [package] ends up at, when the change was verified.
  String? get resolvedVersion {
    for (final change in resolves) {
      if (change.package == package) return change.to;
    }
    return null;
  }

  /// The single line this would change in `pubspec.yaml`.
  String? get diffLine => editPackage == null || toConstraint == null
      ? null
      : '  $editPackage: $toConstraint';

  factory Remediation.fromJson(Map<String, dynamic> json) => Remediation(
        package: json['package'] as String,
        advisoryIds: ((json['advisoryIds'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        kind: RemediationKind.values.asNameMap()[json['kind']],
        editPackage: json['editPackage'] as String?,
        fromConstraint: json['fromConstraint'] as String?,
        toConstraint: json['toConstraint'] as String?,
        resolves: ((json['resolves'] as List?) ?? const [])
            .map((e) => VersionChange.fromJson(e as Map<String, dynamic>))
            .toList(),
        blocker: RemediationBlocker.values.asNameMap()[json['blocker']],
        caveat: json['caveat'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'package': package,
        'advisoryIds': advisoryIds,
        'kind': kind?.name,
        'editPackage': editPackage,
        'fromConstraint': fromConstraint,
        'toConstraint': toConstraint,
        'resolves': resolves.map((c) => c.toJson()).toList(),
        'blocker': blocker?.name,
        'caveat': caveat,
      };
}

/// Every remediation for one project's advisories, worst first.
class RemediationPlan {
  const RemediationPlan({
    required this.projectId,
    this.remediations = const [],
    this.worstSeverity,
  });

  final String projectId;
  final List<Remediation> remediations;

  /// The worst severity the plan covers, so a caller can lead with it.
  final AdvisorySeverity? worstSeverity;

  List<Remediation> get actionable =>
      remediations.where((r) => r.isActionable).toList();

  List<Remediation> get blocked =>
      remediations.where((r) => !r.isActionable).toList();

  factory RemediationPlan.fromJson(Map<String, dynamic> json) =>
      RemediationPlan(
        projectId: json['projectId'] as String,
        remediations: ((json['remediations'] as List?) ?? const [])
            .map((e) => Remediation.fromJson(e as Map<String, dynamic>))
            .toList(),
        worstSeverity:
            AdvisorySeverity.values.asNameMap()[json['worstSeverity']],
      );

  Map<String, dynamic> toJson() => {
        'projectId': projectId,
        'remediations': remediations.map((r) => r.toJson()).toList(),
        'worstSeverity': worstSeverity?.name,
      };
}
