import 'package:pub_semver/pub_semver.dart';

import '../ecosystem/ecosystem.dart';

/// One package pinned to a concrete version by [ConstraintResolver].
class ResolvedPackage {
  const ResolvedPackage({
    required this.name,
    required this.version,
    required this.constraint,
    required this.isDirect,
    this.dependencies = const [],
  });

  final String name;
  final Version version;

  /// The accumulated constraint this version had to satisfy.
  final VersionConstraint constraint;

  /// True when the root project declares this package itself, as opposed to
  /// pulling it in through another package.
  final bool isDirect;

  /// Names of this version's own regular dependencies.
  final List<String> dependencies;
}

/// A package that could not be pinned to any version.
class ResolutionConflict {
  const ResolutionConflict({
    required this.package,
    required this.constraint,
    required this.requiredBy,
    required this.reason,
  });

  final String package;

  /// The combined constraint that nothing satisfied.
  final VersionConstraint constraint;

  /// Which packages contributed a constraint. `root` means the project itself.
  final List<String> requiredBy;

  final String reason;

  String describe() {
    final by = requiredBy.isEmpty ? '' : ' (required by ${requiredBy.join(', ')})';
    return '$package $constraint$by: $reason';
  }
}

/// The result of a resolution: what could be pinned, and what could not.
class ResolutionOutcome {
  const ResolutionOutcome({this.packages = const {}, this.conflicts = const []});

  final Map<String, ResolvedPackage> packages;
  final List<ResolutionConflict> conflicts;

  bool get hasConflicts => conflicts.isNotEmpty;
}

/// Works out which versions `pub get` would choose, without running pub.
///
/// This is an approximation, not a re-implementation of pub's solver. It picks
/// the highest version satisfying the accumulated constraint for each package
/// and iterates to a fixed point, intersecting constraints as new ones are
/// discovered. It does **not** backtrack: if two packages demand genuinely
/// incompatible ranges, pub would search for an older combination that works,
/// whereas this reports the conflict. For the common case — where a compatible
/// set exists without backtracking — it agrees with pub.
///
/// Prereleases are skipped unless the constraint can only be satisfied by one,
/// matching pub's own preference for stable versions.
class ConstraintResolver {
  ConstraintResolver(
    this._ecosystem, {
    this.maxPackages = 200,
    this.maxRounds = 12,
  });

  /// The ecosystem whose registry publishes the versions, and whose dialect
  /// the constraints are written in. Resolution itself is the same algorithm
  /// either way — highest version satisfying every constraint, stable
  /// preferred — because both ecosystems here are semver.
  final Ecosystem _ecosystem;

  /// Stops runaway traversal of a pathological dependency graph.
  final int maxPackages;

  /// Bounds the fixed-point loop; each round re-resolves packages whose
  /// constraint tightened.
  final int maxRounds;

  final _versionCache = <String, List<PackageVersion>>{};

  /// Resolves [direct] (name -> constraint string) and everything they pull in.
  ///
  /// Entries whose constraint cannot be parsed — git, path and sdk
  /// dependencies — are skipped, since pub.dev has no versions for them.
  Future<ResolutionOutcome> resolve(
    Map<String, String> direct, {
    Map<String, String> dev = const {},
  }) async {
    final constraints = <String, VersionConstraint>{};
    final requiredBy = <String, Set<String>>{};
    final directNames = <String>{};

    void seed(Map<String, String> deps) {
      for (final entry in deps.entries) {
        final parsed = _parseConstraint(entry.value);
        if (parsed == null) continue;
        constraints[entry.key] = parsed;
        (requiredBy[entry.key] ??= <String>{}).add('root');
        directNames.add(entry.key);
      }
    }

    seed(direct);
    seed(dev);

    final resolved = <String, ResolvedPackage>{};
    final failed = <String, ResolutionConflict>{};
    var pending = constraints.keys.toSet();

    for (var round = 0; round < maxRounds && pending.isNotEmpty; round++) {
      final next = <String>{};

      for (final name in pending) {
        if (resolved.length >= maxPackages) break;

        final constraint = constraints[name]!;
        final versions = await _versionsOf(name);

        if (versions.isEmpty) {
          resolved.remove(name);
          failed[name] = ResolutionConflict(
            package: name,
            constraint: constraint,
            requiredBy: (requiredBy[name] ?? {}).toList()..sort(),
            reason: 'no such package on pub.dev',
          );
          continue;
        }

        final best = _best(versions, constraint);
        if (best == null) {
          resolved.remove(name);
          failed[name] = ResolutionConflict(
            package: name,
            constraint: constraint,
            requiredBy: (requiredBy[name] ?? {}).toList()..sort(),
            reason: 'no published version satisfies this',
          );
          continue;
        }
        failed.remove(name);

        // Already at this version under the same constraint: nothing to redo.
        final existing = resolved[name];
        if (existing != null && existing.version == best.version) continue;

        resolved[name] = ResolvedPackage(
          name: name,
          version: best.version,
          constraint: constraint,
          isDirect: directNames.contains(name),
          dependencies: best.dependencies.keys.toList(),
        );

        // Fold this version's requirements into the accumulated constraints;
        // anything that tightens has to be resolved again.
        for (final dep in best.dependencies.entries) {
          final declared = _parseConstraint(dep.value);
          if (declared == null) continue;

          (requiredBy[dep.key] ??= <String>{}).add(name);

          final current = constraints[dep.key];
          final merged =
              current == null ? declared : current.intersect(declared);

          if (current == null || merged != current) {
            constraints[dep.key] = merged;
            next.add(dep.key);
          }
        }
      }

      pending = next;
    }

    return ResolutionOutcome(
      packages: resolved,
      conflicts: failed.values.toList()
        ..sort((a, b) => a.package.compareTo(b.package)),
    );
  }

  /// Highest version satisfying [constraint], preferring stable releases.
  PackageVersion? _best(
    List<PackageVersion> versions,
    VersionConstraint constraint,
  ) {
    final allowed =
        versions.where((v) => constraint.allows(v.version)).toList();
    if (allowed.isEmpty) return null;

    final stable = allowed.where((v) => !v.version.isPreRelease).toList();
    final candidates = stable.isNotEmpty ? stable : allowed;

    candidates.sort((a, b) => a.version.compareTo(b.version));
    return candidates.last;
  }

  Future<List<PackageVersion>> _versionsOf(String package) async {
    final cached = _versionCache[package];
    if (cached != null) return cached;
    final versions = await _ecosystem.registry.versions(package);
    _versionCache[package] = versions;
    return versions;
  }

  VersionConstraint? _parseConstraint(String raw) =>
      _ecosystem.parseConstraint(raw);
}
