import 'package:pub_semver/pub_semver.dart';
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:shared/shared.dart';
import 'package:yaml/yaml.dart';

import 'constraint_resolver.dart';
import 'git_fetcher.dart';
import 'pub_api_client.dart';

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
  Resolver(this._pub);

  final PubApiClient _pub;

  Future<ResolutionResult> simulate(
    FetchedPubspecs files,
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

    final Pubspec pubspec;
    try {
      pubspec = Pubspec.parse(files.pubspecYaml);
    } on Exception catch (e) {
      return ResolutionResult(
        request: request,
        success: false,
        conflict: 'Could not read pubspec.yaml: $e',
      );
    }

    final deps = _hosted(pubspec.dependencies);
    final devDeps = _hosted(pubspec.devDependencies);

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
    final baseline = files.hasLock
        ? _parseLock(files.pubspecLock!)
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

  Future<ResolutionOutcome> _resolve(
    Map<String, String> deps,
    Map<String, String> dev,
  ) =>
      // A fresh resolver per call: it caches version listings for the run.
      ConstraintResolver(_pub).resolve(deps, dev: dev);

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

  Map<String, String> _hosted(Map<String, Dependency> deps) => {
        for (final entry in deps.entries)
          if (entry.value case final HostedDependency hosted)
            entry.key: hosted.version.toString(),
      };

  /// Minimal pubspec.lock reader: package -> resolved version.
  Map<String, String> _parseLock(String lockContent) {
    try {
      final doc = loadYaml(lockContent) as YamlMap;
      final packages = doc['packages'] as YamlMap?;
      if (packages == null) return {};
      return {
        for (final entry in packages.entries)
          entry.key as String:
              (entry.value as YamlMap)['version'] as String? ?? '(unknown)',
      };
    } catch (_) {
      return {};
    }
  }

  static VersionConstraint? _parseConstraint(String raw) {
    if (raw.trim().isEmpty) return null;
    try {
      return VersionConstraint.parse(raw);
    } on FormatException {
      return null;
    }
  }
}
