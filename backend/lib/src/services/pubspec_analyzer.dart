import 'package:pub_semver/pub_semver.dart';
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:shared/shared.dart';
import 'package:yaml/yaml.dart';

import 'constraint_resolver.dart';
import 'cvss.dart';
import 'git_fetcher.dart';
import 'pub_api_client.dart';

/// Turns fetched pubspec files into a [DepReport] enriched with pub.dev data.
class PubspecAnalyzer {
  PubspecAnalyzer(this._pub, {ConstraintResolver? resolver})
      : _resolver = resolver ?? ConstraintResolver(_pub);

  final PubApiClient _pub;
  final ConstraintResolver _resolver;

  /// Analyzes every pubspec in [repository] and merges them into one report.
  ///
  /// Packages are merged on **name and version**, not name alone. A repository
  /// can resolve the same package twice at different versions — a directory
  /// kept out of the pub workspace resolves independently — and collapsing
  /// those would either hide an advisory that applies to one of them or claim
  /// one against the other.
  Future<DepReport> analyzeRepository(
    String projectId,
    FetchedRepository repository,
  ) async {
    // One manifest is the common case, and merging machinery would only make
    // its result harder to read.
    if (repository.manifests.length == 1) {
      final report = await analyze(projectId, repository.primary.files);
      return DepReport(
        projectId: report.projectId,
        generatedAt: report.generatedAt,
        nodes: report.nodes,
        coverageNote: repository.discoveryNote,
      );
    }

    // name@version -> the node, plus every manifest it turned up in.
    final merged = <String, DepNode>{};
    final origins = <String, List<String>>{};

    for (final manifest in repository.manifests) {
      final report = await analyze(projectId, manifest.files);
      for (final node in report.nodes) {
        final where = origins.putIfAbsent(node.key, () => <String>[]);
        if (!where.contains(manifest.label)) where.add(manifest.label);

        // Merge the graph edges: the same version can be reached from
        // different packages in different manifests.
        final existing = merged[node.key];
        merged[node.key] = existing == null
            ? node
            : _mergeEdges(existing, node);
      }
    }

    final nodes = [
      for (final entry in merged.entries)
        entry.value.inManifests(origins[entry.key]!),
    ]..sort((a, b) {
        final byName = a.name.compareTo(b.name);
        return byName != 0 ? byName : a.installed.compareTo(b.installed);
      });

    return DepReport(
      projectId: projectId,
      generatedAt: DateTime.now().toUtc(),
      nodes: nodes,
      manifests: repository.manifests.map((m) => m.label).toList(),
      coverageNote: repository.discoveryNote,
    );
  }

  /// Keeps the union of two manifests' edges for the same package version, and
  /// the stronger of the two kinds — declared beats transitive, because a
  /// package the repository declares somewhere is one you can act on.
  static DepNode _mergeEdges(DepNode a, DepNode b) {
    final edges = {...a.dependencies, ...b.dependencies}.toList()..sort();
    final declared = a.kind != DepKind.transitive ? a : b;

    return DepNode(
      name: a.name,
      kind: declared.kind,
      installed: a.installed,
      constraint: a.constraint ?? b.constraint,
      latest: a.latest ?? b.latest,
      status: a.status,
      source: a.source,
      advisories: a.advisories,
      dependencies: edges,
    );
  }

  Future<DepReport> analyze(
    String projectId,
    FetchedPubspecs files,
  ) async {
    final pubspec = Pubspec.parse(files.pubspecYaml);
    final directNames = pubspec.dependencies.keys.toSet();
    final devNames = pubspec.devDependencies.keys.toSet();

    // A lockfile is authoritative. Without one, work out what `pub get` would
    // choose by resolving the declared constraints, so a repository that does
    // not commit its lockfile still gets real versions instead of "unknown".
    final locked = files.hasLock
        ? _parseLock(files.pubspecLock!)
        : <String, String>{};

    final resolved = files.hasLock
        ? const <String, ResolvedPackage>{}
        : (await _resolver.resolve(
            _hostedConstraints(pubspec.dependencies),
            dev: _hostedConstraints(pubspec.devDependencies),
          ))
            .packages;

    final names = <String>{
      ...directNames,
      ...devNames,
      ...locked.keys,
      ...resolved.keys,
    };

    // Each package needs two or three pub.dev requests. Done one at a time a
    // 50-package project takes tens of seconds, so run a bounded number in
    // parallel — bounded to stay a polite API client.
    final nodes = await _mapConcurrently(names.toList(), (name) async {
      final resolvedPackage = resolved[name];
      final installed = locked[name] ??
          resolvedPackage?.version.toString() ??
          '(unresolved)';

      final source = locked.containsKey(name)
          ? DepSource.lockfile
          : resolvedPackage != null
              ? DepSource.constraint
              : DepSource.unresolved;

      final constraint = _constraintString(pubspec, name);
      final kind = directNames.contains(name)
          ? DepKind.direct
          : devNames.contains(name)
              ? DepKind.dev
              : DepKind.transitive;

      final info = await _pub.info(name);

      // An advisory applies to specific versions. Only those affecting the
      // version actually in use are attached; without a resolved version we
      // cannot judge, so none are claimed.
      final current = _tryParseVersion(installed);
      final advisories = current == null
          ? const <DepAdvisory>[]
          : await _advisoriesFor(name, info.advisories, current);

      final status = _status(installed, info.latest, advisories);

      // Graph edges: this package's regular deps, kept only if they're also in
      // the project's set (so edges never dangle). The resolver already knows
      // them for the versions it picked; otherwise ask pub.dev, which it can
      // only answer for a real semver.
      final children = resolvedPackage != null
          ? resolvedPackage.dependencies.where(names.contains).toList()
          : current == null
              ? const <String>[]
              : (await _pub.dependencyNames(name, installed))
                  .where(names.contains)
                  .toList();

      return DepNode(
        name: name,
        kind: kind,
        installed: installed,
        constraint: constraint,
        latest: info.latest,
        status: status,
        source: source,
        advisories: advisories,
        dependencies: children,
      );
    });

    return DepReport(
      projectId: projectId,
      generatedAt: DateTime.now().toUtc(),
      nodes: nodes,
    );
  }

  /// Applies [task] to every item, running at most [concurrency] at a time and
  /// preserving input order.
  static Future<List<R>> _mapConcurrently<T, R>(
    List<T> items,
    Future<R> Function(T item) task, {
    int concurrency = 8,
  }) async {
    final results = List<R?>.filled(items.length, null);
    var next = 0;

    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= items.length) return;
        results[index] = await task(items[index]);
      }
    }

    await Future.wait([
      for (var i = 0; i < concurrency && i < items.length; i++) worker(),
    ]);
    return results.cast<R>();
  }

  /// Declared constraints for the hosted dependencies in [deps].
  ///
  /// Git, path and SDK dependencies are dropped: pub.dev publishes no versions
  /// for them, so there is nothing to resolve against.
  Map<String, String> _hostedConstraints(Map<String, Dependency> deps) {
    return {
      for (final entry in deps.entries)
        if (entry.value case final HostedDependency hosted)
          entry.key: hosted.version.toString(),
    };
  }

  String? _constraintString(Pubspec p, String name) {
    final dep = p.dependencies[name] ?? p.devDependencies[name];
    if (dep is HostedDependency) return dep.version.toString();
    return dep?.toString();
  }

  /// The advisories affecting [current], each carrying the version that fixes
  /// it.
  ///
  /// The fix usually comes straight from the advisory's own ranges. When it
  /// does not — pub.dev also publishes advisories that enumerate affected
  /// versions instead of describing ranges — the package's release history
  /// answers it: the lowest stable release above [current] the advisory does
  /// not cover. That costs one extra request, and only for a package that is
  /// actually vulnerable.
  Future<List<DepAdvisory>> _advisoriesFor(
    String package,
    List<Advisory> published,
    Version current,
  ) async {
    final applicable =
        published.where((a) => a.affects(current)).toList(growable: false);
    if (applicable.isEmpty) return const [];

    List<Version>? releasesAbove;
    final result = <DepAdvisory>[];

    for (final advisory in applicable) {
      var fixed = advisory.fixedVersionFor(current);
      if (fixed == null) {
        releasesAbove ??= await _stableReleasesAbove(package, current);
        for (final candidate in releasesAbove) {
          if (!advisory.affects(candidate)) {
            fixed = candidate;
            break;
          }
        }
      }

      final cvss = CvssV3.parse(advisory.cvssVector);
      result.add(
        DepAdvisory(
          id: advisory.id,
          aliases: advisory.aliases,
          summary: advisory.summary,
          fixedIn: fixed?.toString(),
          // Prefer the vector: it is a number anyone can recompute, and it
          // bands identically across every advisory. The database's own word
          // for it is the fallback when no vector was published.
          severity: cvss != null
              ? AdvisorySeverity.fromScore(cvss.baseScore)
              : AdvisorySeverity.fromName(advisory.databaseSeverity) ??
                  AdvisorySeverity.unknown,
          cvssScore: cvss?.baseScore,
          cvssVector: advisory.cvssVector,
        ),
      );
    }

    return result;
  }

  /// Stable releases newer than [current], lowest first — the order in which
  /// someone would rather take them.
  Future<List<Version>> _stableReleasesAbove(
    String package,
    Version current,
  ) async {
    final versions = await _pub.versions(package);
    return versions
        .map((v) => v.version)
        .where((v) => v > current && !v.isPreRelease)
        .toList()
      ..sort();
  }

  DepStatus _status(
    String installed,
    String? latest,
    List<DepAdvisory> advisories,
  ) {
    if (advisories.isNotEmpty) return DepStatus.vulnerable;
    if (latest == null) return DepStatus.unknown;
    final cur = _tryParseVersion(installed);
    final lat = _tryParseVersion(latest);
    if (cur == null || lat == null) return DepStatus.unknown;
    return cur < lat ? DepStatus.outdated : DepStatus.upToDate;
  }

  /// Parses a semver string, returning null instead of throwing.
  ///
  /// [Version.parse] throws a [FormatException] on anything non-semver, and
  /// `installed` is the sentinel `(unresolved)` for projects with no
  /// `pubspec.lock` — so parsing directly crashed the whole analysis for any
  /// repo that doesn't commit its lockfile. Such versions are simply unknown.
  static Version? _tryParseVersion(String text) {
    try {
      return Version.parse(text);
    } on FormatException {
      return null;
    }
  }

  /// Minimal pubspec.lock reader: package -> resolved version.
  Map<String, String> _parseLock(String lockContent) {
    final doc = loadYaml(lockContent) as YamlMap;
    final packages = doc['packages'] as YamlMap?;
    if (packages == null) return {};
    return {
      for (final entry in packages.entries)
        entry.key as String:
            (entry.value as YamlMap)['version'] as String? ?? '(unknown)',
    };
  }
}
