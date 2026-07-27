import 'package:pub_semver/pub_semver.dart';

import 'pub_api_client.dart';

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

/// Works out which versions `pub get` would choose, for projects that have no
/// `pubspec.lock`.
///
/// This is an approximation, not a re-implementation of pub's solver. It picks
/// the highest version satisfying the accumulated constraint for each package
/// and iterates to a fixed point, intersecting constraints as new ones are
/// discovered. It does **not** backtrack: if two packages demand genuinely
/// incompatible ranges, pub would search for an older combination that works,
/// whereas this reports the conflict as unresolvable and moves on. For the
/// common case — where a compatible set exists without backtracking — it agrees
/// with pub.
///
/// Prereleases are skipped unless the constraint can only be satisfied by one,
/// matching pub's own preference for stable versions.
class ConstraintResolver {
  ConstraintResolver(this._pub, {this.maxPackages = 200, this.maxRounds = 12});

  final PubApiClient _pub;

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
  Future<Map<String, ResolvedPackage>> resolve(
    Map<String, String> direct, {
    Map<String, String> dev = const {},
  }) async {
    final constraints = <String, VersionConstraint>{};
    final directNames = <String>{};

    void seed(Map<String, String> deps) {
      for (final entry in deps.entries) {
        final parsed = _parseConstraint(entry.value);
        if (parsed == null) continue;
        constraints[entry.key] = parsed;
        directNames.add(entry.key);
      }
    }

    seed(direct);
    seed(dev);

    final resolved = <String, ResolvedPackage>{};
    var pending = constraints.keys.toSet();

    for (var round = 0; round < maxRounds && pending.isNotEmpty; round++) {
      final next = <String>{};

      for (final name in pending) {
        if (resolved.length >= maxPackages) break;

        final constraint = constraints[name]!;
        final versions = await _versionsOf(name);
        final best = _best(versions, constraint);

        // Unsatisfiable, or a package pub.dev doesn't serve.
        if (best == null) {
          resolved.remove(name);
          continue;
        }

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

    return resolved;
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
    final versions = await _pub.versions(package);
    _versionCache[package] = versions;
    return versions;
  }

  static VersionConstraint? _parseConstraint(String raw) {
    try {
      return VersionConstraint.parse(raw);
    } on FormatException {
      return null;
    }
  }
}
