import 'package:pub_semver/pub_semver.dart';
import 'package:shared/shared.dart';

import 'git_fetcher.dart';
import 'resolver.dart';

/// Works out how to get a project off its vulnerable dependency versions.
///
/// Nothing here is offered on the strength of the arithmetic looking right.
/// Every candidate change is put through [Resolver], and kept only if the
/// resulting version set actually contains a fixed version of the vulnerable
/// package. A suggestion that does not resolve costs a reader more time than no
/// suggestion at all, so those are reported as blocked instead.
///
/// Three ways a fix can land, in order of how well-mannered they are:
///
/// 1. The project declares the package — raise its constraint.
/// 2. It does not, but bumping whatever pulls it in reaches a fixed version.
///    This is the right fix for a transitive problem: the tree stays the shape
///    its authors intended.
/// 3. Neither works, so the package is promoted to a direct dependency with a
///    floor. It works, and it is a pin on someone else's dependency that
///    somebody will have to remember to remove.
class RemediationPlanner {
  RemediationPlanner(this._resolver);

  final Resolver _resolver;

  /// Plans a fix for every advisory in [report], worst first.
  ///
  /// Each candidate costs a resolution, and a resolution costs pub.dev
  /// requests, so [maxPackages] bounds the work: the tail of a long list is not
  /// where anyone starts anyway.
  Future<RemediationPlan> plan(
    DepReport report,
    FetchedPubspecs files, {
    int maxPackages = 10,
  }) async {
    final affected = report.affectedNodes.take(maxPackages);

    final remediations = <Remediation>[];
    for (final node in affected) {
      remediations.add(await _forPackage(node, report, files));
    }

    return RemediationPlan(
      projectId: report.projectId,
      remediations: remediations,
      worstSeverity: report.worstSeverity,
    );
  }

  Future<Remediation> _forPackage(
    DepNode node,
    DepReport report,
    FetchedPubspecs files,
  ) async {
    final ids = node.advisories.map((a) => a.id).toList();

    // The report is the baseline, because it is what the reader is looking at.
    final installed = {
      for (final n in report.nodes) n.name: n.installed,
    };

    // The lowest version clearing every advisory on this package: fixing one
    // and leaving another would be a strange thing to call a remediation.
    final target = _lowestSafeVersion(node);
    if (target == null) {
      return Remediation(
        package: node.name,
        advisoryIds: ids,
        blocker: RemediationBlocker.noFixPublished,
      );
    }

    final declared = node.kind == DepKind.direct || node.kind == DepKind.dev;
    if (declared) {
      final attempt = await _verify(
        files: files,
        editPackage: node.name,
        constraint: '^$target',
        vulnerable: node.name,
        target: target,
        installed: installed,
      );
      if (attempt != null) {
        return Remediation(
          package: node.name,
          advisoryIds: ids,
          kind: RemediationKind.raiseConstraint,
          editPackage: node.name,
          fromConstraint: node.constraint,
          toConstraint: '^$target',
          resolves: attempt,
          caveat: _majorBumpCaveat(node.installed, target, node.name),
        );
      }
    } else {
      // Transitive: try the dependencies that actually pull it in.
      for (final parent in _parentsOf(node.name, report)) {
        if (parent.latest == null) continue;
        final attempt = await _verify(
          files: files,
          editPackage: parent.name,
          constraint: '^${parent.latest}',
          vulnerable: node.name,
          target: target,
          installed: installed,
        );
        if (attempt == null) continue;

        return Remediation(
          package: node.name,
          advisoryIds: ids,
          kind: RemediationKind.bumpParent,
          editPackage: parent.name,
          fromConstraint: parent.constraint,
          toConstraint: '^${parent.latest}',
          resolves: attempt,
          caveat: _majorBumpCaveat(
            parent.installed,
            Version.parse(parent.latest!),
            parent.name,
          ),
        );
      }

      // Nothing declared reaches the fix, so declare the package itself.
      final attempt = await _verify(
        files: files,
        editPackage: node.name,
        constraint: '^$target',
        vulnerable: node.name,
        target: target,
        installed: installed,
      );
      if (attempt != null) {
        return Remediation(
          package: node.name,
          advisoryIds: ids,
          kind: RemediationKind.promoteToDirect,
          editPackage: node.name,
          toConstraint: '^$target',
          resolves: attempt,
          caveat: 'This adds ${node.name} to pubspec.yaml even though nothing '
              'in the project uses it directly. It is a pin to work around a '
              'dependency that has not caught up, and should come out once it '
              'has.',
        );
      }
    }

    return Remediation(
      package: node.name,
      advisoryIds: ids,
      blocker: RemediationBlocker.unreachable,
    );
  }

  /// Runs a candidate change and returns what it moves, or null when it does
  /// not resolve or does not actually reach a fixed version.
  ///
  /// The second check is the one that matters: a resolution can succeed while
  /// leaving the vulnerable package exactly where it was, because something
  /// else in the tree holds it down. That is why this asks for the whole
  /// resulting version set rather than reading a diff — a package that is
  /// already at the wanted version does not appear in a diff, and "absent"
  /// would otherwise have to mean two opposite things.
  Future<List<VersionChange>?> _verify({
    required FetchedPubspecs files,
    required String editPackage,
    required String constraint,
    required String vulnerable,
    required Version target,
    required Map<String, String> installed,
  }) async {
    final resolved = await _resolver.resolvedVersionsFor(
      files,
      ResolutionRequest(package: editPackage, targetConstraint: constraint),
    );
    if (resolved == null) return null;

    final landed = _tryParse(resolved[vulnerable]);
    if (landed == null || landed < target) return null;

    return _diff(installed, resolved);
  }

  /// What moves between the report and the proposed resolution.
  ///
  /// Reported against the stored report rather than a fresh baseline so the
  /// numbers match the versions the reader has in front of them.
  static List<VersionChange> _diff(
    Map<String, String> before,
    Map<String, String> after,
  ) {
    final changes = <VersionChange>[];
    for (final name in {...before.keys, ...after.keys}) {
      final from = before[name];
      final to = after[name];
      if (from == to) continue;
      changes.add(VersionChange(package: name, from: from, to: to));
    }

    changes.sort((a, b) => a.package.compareTo(b.package));
    return changes;
  }

  /// The lowest version that clears every advisory on [node].
  ///
  /// Null when any advisory has no published fix: moving past the others while
  /// one remains open is not a fix, and saying so is more use than a number
  /// that implies safety.
  static Version? _lowestSafeVersion(DepNode node) {
    Version? highest;
    for (final advisory in node.advisories) {
      final fixed = _tryParse(advisory.fixedIn);
      if (fixed == null) return null;
      if (highest == null || fixed > highest) highest = fixed;
    }
    return highest;
  }

  /// Dependencies the project declares that lead to [package], nearest first.
  ///
  /// Only the immediate declared parents are considered: bumping something four
  /// levels up in the hope that the change trickles down is not a fix anyone
  /// should be offered.
  static List<DepNode> _parentsOf(String package, DepReport report) {
    final declared = report.nodes.where(
      (n) => n.kind == DepKind.direct || n.kind == DepKind.dev,
    );
    return declared.where((n) => n.dependencies.contains(package)).toList();
  }

  /// Warns when the change crosses a breaking boundary, since the diff itself
  /// only shows numbers moving.
  static String? _majorBumpCaveat(String from, Version to, String package) {
    final current = _tryParse(from);
    if (current == null) return null;

    final crossesMajor = to.major > current.major ||
        (current.major == 0 && to.major == 0 && to.minor > current.minor);
    if (!crossesMajor) return null;

    return 'This is a breaking upgrade of $package ($from to $to). Its API may '
        'have changed — check what moving it involves before taking it.';
  }

  static Version? _tryParse(String? raw) {
    if (raw == null) return null;
    try {
      return Version.parse(raw);
    } on FormatException {
      return null;
    }
  }
}
