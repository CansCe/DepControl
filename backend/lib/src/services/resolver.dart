import 'package:pub_semver/pub_semver.dart';
import 'package:shared/shared.dart';

import '../ecosystem/ecosystem.dart';
import 'constraint_resolver.dart';

/// Simulates "what happens if I change this dependency's constraint".
///
/// Resolution is computed from pub.dev metadata via [ConstraintResolver]. An
/// earlier version shelled out to `dart pub upgrade --dry-run` in a temp
/// directory, which meant running a subprocess over a pubspec fetched from a
/// user-supplied repository — a repository could declare `git:` dependencies
/// pointing anywhere and pub would fetch them. It also required the Dart SDK on
/// the server. Neither applies now: nothing is written to disk and no process
/// is started.
///
/// The trade-off is that [ConstraintResolver] does not backtrack, so a conflict
/// it reports means "no solution without downgrading something else", which is
/// weaker than pub's answer. Conflicts name the packages involved so the reason
/// is visible.
class Resolver {
  Resolver(this._ecosystem);

  final Ecosystem _ecosystem;

  Future<ResolutionResult> simulate(
    ManifestFiles files,
    ResolutionRequest request,
  ) async {
    final target = _parseConstraint(request.targetConstraint);
    if (target == null) {
      return ResolutionResult(
        request: request,
        success: false,
        conflict: '"${request.targetConstraint}" is not a valid version '
            'constraint. Use something like ^2.0.0, any, or 1.4.2.',
      );
    }

    final ParsedManifest parsed;
    try {
      parsed = _ecosystem.parse(files);
    } on Exception catch (e) {
      return ResolutionResult(
        request: request,
        success: false,
        conflict: 'Could not read ${_ecosystem.naming.manifest}: $e',
      );
    }

    final deps = parsed.registryConstraints(parsed.dependencies);
    final devDeps = parsed.registryConstraints(parsed.devDependencies);

    // Where the change lands: an existing dev dependency stays a dev
    // dependency; anything else is treated as a regular one.
    final isDev = devDeps.containsKey(request.package);
    final proposedDeps = {...deps};
    final proposedDev = {...devDeps};
    (isDev ? proposedDev : proposedDeps)[request.package] =
        request.targetConstraint;

    // Baseline: the lockfile is what is actually installed. Without one, fall
    // back to resolving the constraints as they stand, so the diff still means
    // something.
    final baseline = parsed.hasLock
        ? {
            for (final entry in parsed.locked.entries)
              entry.key: entry.value.version,
          }
        : _versionsOf(await _resolve(deps, devDeps));

    final after = await _resolve(proposedDeps, proposedDev);

    if (after.hasConflicts) {
      return ResolutionResult(
        request: request,
        success: false,
        conflict: _describeConflicts(request, after),
        rawOutput: _summarise(request, baseline, _versionsOf(after)),
      );
    }

    final resolvedAfter = _versionsOf(after);
    final changes = _diff(baseline, resolvedAfter);

    return ResolutionResult(
      request: request,
      success: true,
      changes: changes,
      rawOutput: _summarise(request, baseline, resolvedAfter),
    );
  }

  /// The complete version set a proposed change resolves to, or null when it
  /// does not resolve.
  ///
  /// [simulate] reports only what *moved*, which is the right answer for a
  /// human reading a diff and the wrong one for a caller asking "what version
  /// does this land on" — a package already sitting at the wanted version does
  /// not appear in a diff at all. The remediation planner needs the latter, and
  /// guessing "absent means unchanged" would make it depend on which baseline
  /// the simulation happened to use.
  Future<Map<String, String>?> resolvedVersionsFor(
    ManifestFiles files,
    ResolutionRequest request,
  ) async {
    final target = _parseConstraint(request.targetConstraint);
    if (target == null) return null;

    final ParsedManifest parsed;
    try {
      parsed = _ecosystem.parse(files);
    } on Exception {
      return null;
    }

    final deps = parsed.registryConstraints(parsed.dependencies);
    final devDeps = parsed.registryConstraints(parsed.devDependencies);

    final isDev = devDeps.containsKey(request.package);
    final proposedDeps = {...deps};
    final proposedDev = {...devDeps};
    (isDev ? proposedDev : proposedDeps)[request.package] =
        request.targetConstraint;

    final outcome = await _resolve(proposedDeps, proposedDev);
    return outcome.hasConflicts ? null : _versionsOf(outcome);
  }

  Future<ResolutionOutcome> _resolve(
    Map<String, String> deps,
    Map<String, String> dev,
  ) =>
      // A fresh resolver per call: it caches version listings for the run.
      ConstraintResolver(_ecosystem).resolve(deps, dev: dev);

  Map<String, String> _versionsOf(ResolutionOutcome outcome) => {
        for (final entry in outcome.packages.entries)
          entry.key: entry.value.version.toString(),
      };

  /// Packages whose version differs between the two sets, plus additions and
  /// removals. Sorted so the requested package leads.
  List<VersionChange> _diff(
    Map<String, String> before,
    Map<String, String> after,
  ) {
    final names = {...before.keys, ...after.keys};
    final changes = <VersionChange>[];

    for (final name in names) {
      final from = before[name];
      final to = after[name];
      if (from == to) continue;
      changes.add(VersionChange(package: name, from: from, to: to));
    }

    changes.sort((a, b) => a.package.compareTo(b.package));
    return changes;
  }

  String _describeConflicts(
    ResolutionRequest request,
    ResolutionOutcome outcome,
  ) {
    // Surface the requested package first when it is the one that failed.
    final conflicts = [...outcome.conflicts]..sort((a, b) {
        if (a.package == request.package) return -1;
        if (b.package == request.package) return 1;
        return a.package.compareTo(b.package);
      });

    final buffer = StringBuffer()
      ..writeln('Cannot set ${request.package} to '
          '${request.targetConstraint}:');
    for (final conflict in conflicts) {
      buffer.writeln('  - ${conflict.describe()}');
    }
    buffer.write(
      'Resolving this may need another dependency to move as well, which this '
      'simulation does not search for.',
    );
    return buffer.toString();
  }

  String _summarise(
    ResolutionRequest request,
    Map<String, String> before,
    Map<String, String> after,
  ) {
    final buffer = StringBuffer()
      ..writeln('Simulated ${request.package}: ${request.targetConstraint}')
      ..writeln('Resolved ${after.length} packages '
          '(${before.length} before).');
    for (final change in _diff(before, after)) {
      final from = change.from ?? '(new)';
      final to = change.to ?? '(removed)';
      buffer.writeln('  ${change.package}: $from -> $to');
    }
    return buffer.toString().trimRight();
  }

  /// The requested constraint, or null when it is not one this ecosystem can
  /// resolve against. An empty string is rejected here rather than in the
  /// ecosystem, because "any version" is a legal constraint and an empty text
  /// box is not a request to install one.
  VersionConstraint? _parseConstraint(String raw) =>
      raw.trim().isEmpty ? null : _ecosystem.parseConstraint(raw);
}
