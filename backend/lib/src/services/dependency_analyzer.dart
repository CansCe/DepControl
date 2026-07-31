import 'package:pub_semver/pub_semver.dart';
import 'package:shared/shared.dart';

import '../ecosystem/ecosystems.dart';
import 'constraint_resolver.dart';
import 'cvss.dart';
import 'git_fetcher.dart';
import 'scan_progress_store.dart';

/// Turns fetched manifests into a [DepReport] enriched with registry data.
///
/// Knows nothing about pub.dev, `pubspec.yaml` or Dart. Everything specific to
/// an ecosystem — the file names, the manifest syntax, the registry protocol,
/// the constraint dialect — is reached through [Ecosystem]; what is left is the
/// part that is the same for all of them, which turns out to be most of it.
class DependencyAnalyzer {
  DependencyAnalyzer(this._ecosystems, {Map<String, ConstraintResolver>? resolvers})
      : _resolvers = resolvers ??
            {
              for (final ecosystem in _ecosystems.all)
                ecosystem.id: ConstraintResolver(ecosystem),
            };

  final Ecosystems _ecosystems;

  /// One resolver per ecosystem: each caches the versions it has fetched, and
  /// those caches must not be shared across registries.
  final Map<String, ConstraintResolver> _resolvers;

  /// Analyzes every manifest in [repository] and merges them into one report.
  ///
  /// Packages are merged on **name and version**, not name alone. A repository
  /// can resolve the same package twice at different versions — a directory
  /// kept out of the pub workspace resolves independently — and collapsing
  /// those would either hide an advisory that applies to one of them or claim
  /// one against the other.
  ///
  /// With more than one ecosystem in play the key carries the ecosystem too:
  /// npm and pub.dev both publish packages called `path` and `stack_trace`,
  /// and they are unrelated software.
  /// [progress] is told what is happening as it happens, for a client watching
  /// a scan it cannot otherwise see inside. Defaults to a sink that discards
  /// everything, so nothing pays for it unless someone is looking.
  Future<DepReport> analyzeRepository(
    String projectId,
    FetchedRepository repository, {
    ScanProgressSink progress = ScanProgressSink.none,
  }) async {
    progress
      ..manifestsTotal(repository.manifests.length)
      ..phase(ScanPhase.analyzing);

    // One manifest is the common case, and merging machinery would only make
    // its result harder to read.
    if (repository.manifests.length == 1) {
      final report = await analyze(
        projectId,
        repository.primary.files,
        ecosystem: repository.primary.ecosystem,
        imported: repository.primary.importedPackages,
        progress: progress,
      );
      return DepReport(
        projectId: report.projectId,
        generatedAt: report.generatedAt,
        nodes: report.nodes,
        coverageNote: repository.discoveryNote,
      );
    }

    // ecosystem:name@version -> the node, plus every manifest it turned up in.
    final merged = <String, DepNode>{};
    final origins = <String, List<String>>{};

    for (final manifest in repository.manifests) {
      final label = repository.labelOf(manifest);
      final report = await analyze(
        projectId,
        manifest.files,
        ecosystem: manifest.ecosystem,
        imported: manifest.importedPackages,
        progress: progress,
      );
      for (final node in report.nodes) {
        final where = origins.putIfAbsent(node.key, () => <String>[]);
        if (!where.contains(label)) where.add(label);

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
        final byEcosystem = a.ecosystem.compareTo(b.ecosystem);
        if (byEcosystem != 0) return byEcosystem;
        final byName = a.name.compareTo(b.name);
        return byName != 0 ? byName : a.installed.compareTo(b.installed);
      });

    return DepReport(
      projectId: projectId,
      generatedAt: DateTime.now().toUtc(),
      nodes: nodes,
      manifests: [
        for (final manifest in repository.manifests)
          repository.labelOf(manifest),
      ],
      coverageNote: repository.discoveryNote,
    );
  }

  /// Keeps the union of two manifests' edges for the same package version, and
  /// the stronger of the two kinds — declared beats transitive, because a
  /// package the repository declares somewhere is one you can act on.
  static DepNode _mergeEdges(DepNode a, DepNode b) {
    final edges = {...a.dependencies, ...b.dependencies}.toList()..sort();
    final declared = a.kind != DepKind.transitive ? a : b;

    // One package in a monorepo importing something is enough for the
    // repository to depend on it, so any `true` wins. A manifest whose source
    // was never scanned contributes nothing either way rather than a `false`.
    final imported = switch ((a.imported, b.imported)) {
      (null, final other) || (final other, null) => other,
      (final x?, final y?) => x || y,
    };

    return DepNode(
      imported: imported,
      name: a.name,
      // Both sides share a [DepNode.key], which carries the ecosystem, so
      // there is nothing to reconcile here.
      ecosystem: a.ecosystem,
      kind: declared.kind,
      installed: a.installed,
      constraint: a.constraint ?? b.constraint,
      latest: a.latest ?? b.latest,
      status: a.status,
      source: a.source,
      advisories: a.advisories,
      // Same package at the same version, so both readings describe the same
      // published archive; either will do.
      license: a.license ?? b.license,
      // Likewise a fact about the published archive, not about the manifest
      // that reached it — so one manifest measuring it is enough.
      size: a.size ?? b.size,
      dependencies: edges,
    );
  }

  /// Analyzes one manifest.
  ///
  /// [imported] is the set of packages that manifest's own source reaches for,
  /// or null when the source was not read. It is passed down to each node
  /// verbatim: whether a package being absent from it is worth reporting is a
  /// question for [DepReport], which has the whole picture.
  Future<DepReport> analyze(
    String projectId,
    ManifestFiles files, {
    String ecosystem = DepNode.defaultEcosystem,
    Set<String>? imported,
    ScanProgressSink progress = ScanProgressSink.none,
  }) async {
    final eco = _ecosystems.require(ecosystem);
    final registry = eco.registry;
    final resolver = _resolvers[ecosystem] ?? ConstraintResolver(eco);

    final parsed = eco.parse(files);
    final directNames = parsed.dependencies.keys.toSet();
    final devNames = parsed.devDependencies.keys.toSet();
    final locked = parsed.locked;

    // Where each package comes from, which decides whether the registry has
    // anything to say about it at all.
    final origins = parsed.origins;

    // A lockfile is authoritative. Without one, work out what an install would
    // choose by resolving the declared constraints, so a repository that does
    // not commit its lockfile still gets real versions instead of "unknown".
    //
    // Called out as its own phase because it is not free — resolving a
    // constraint set means fetching every candidate version — and a client
    // watching a repository with no lockfile would otherwise see the package
    // count sit at zero for a while with nothing said about why.
    if (!parsed.hasLock) progress.phase(ScanPhase.resolving);
    final resolved = parsed.hasLock
        ? const <String, ResolvedPackage>{}
        : (await resolver.resolve(
            parsed.registryConstraints(parsed.dependencies),
            dev: parsed.registryConstraints(parsed.devDependencies),
          ))
            .packages;

    final names = <String>{
      ...directNames,
      ...devNames,
      ...locked.keys,
      ...resolved.keys,
    };

    // The denominator, at last: this manifest's share of the work is now known.
    progress
      ..phase(ScanPhase.analyzing)
      ..manifestStarted(names.length);

    // Each package needs two or three registry requests. Done one at a time a
    // 50-package project takes tens of seconds, so run a bounded number in
    // parallel — bounded to stay a polite API client.
    final nodes = await _mapConcurrently(names.toList(), onDone: progress, (
      name,
    ) async {
      final resolvedPackage = resolved[name];
      final installed = locked[name]?.version ??
          resolvedPackage?.version.toString() ??
          '(unresolved)';

      final source = locked.containsKey(name)
          ? DepSource.lockfile
          : resolvedPackage != null
              ? DepSource.constraint
              : DepSource.unresolved;

      final constraint = parsed.declarationOf(name)?.constraint;
      final kind = directNames.contains(name)
          ? DepKind.direct
          : devNames.contains(name)
              ? DepKind.dev
              : DepKind.transitive;

      // Null when no source was read, so the node says "not checked" rather
      // than "not imported".
      final usedInSource = imported?.contains(name);

      // A package that does not come from the registry is not asked about
      // there. pub.dev serves packages under some of these names — `flutter`
      // and `sky_engine` are both discontinued placeholders with a few dozen
      // downloads a month — and answering with one of those would report a
      // latest version, an advisory set and a license belonging to entirely
      // different software. npm, with no namespacing and a far larger surface,
      // is worse.
      if (origins[name] case final origin?) {
        return DepNode(
          name: name,
          ecosystem: ecosystem,
          kind: kind,
          installed: installed,
          constraint: constraint,
          source: source,
          imported: usedInSource,
          license: PackageLicense.notFromPubDev(origin),
          dependencies: resolvedPackage?.dependencies
                  .where(names.contains)
                  .toList() ??
              const [],
        );
      }

      // A name the registry could not serve is not a request worth making.
      // Manifests are fetched off the internet, so this is validation rather
      // than escaping.
      if (!registry.isValidPackageName(name)) {
        return DepNode(
          name: name,
          ecosystem: ecosystem,
          kind: kind,
          installed: installed,
          constraint: constraint,
          source: source,
          imported: usedInSource,
          dependencies: const [],
        );
      }

      final info = await registry.info(name);

      // An advisory applies to specific versions. Only those affecting the
      // version actually in use are attached; without a resolved version we
      // cannot judge, so none are claimed.
      final current = _tryParseVersion(installed);
      final advisories = current == null
          ? const <DepAdvisory>[]
          : await _advisoriesFor(registry, name, info.advisories, current);

      final status = _status(installed, info.latest, advisories);
      final license = await registry.licenseFor(name, installed, info.latest);

      // Null wherever the registry publishes no size, which is most npm
      // releases and every pub.dev archive that cannot be reached. The node
      // then says nothing about its weight rather than claiming none.
      final size = current == null
          ? null
          : await registry.sizeOf(name, installed);

      // Graph edges: this package's regular deps, kept only if they're also in
      // the project's set (so edges never dangle). The resolver already knows
      // them for the versions it picked; otherwise ask the registry, which it
      // can only answer for a real semver.
      final children = resolvedPackage != null
          ? resolvedPackage.dependencies.where(names.contains).toList()
          : current == null
              ? const <String>[]
              : (await registry.dependencyNames(name, installed))
                  .where(names.contains)
                  .toList();

      return DepNode(
        name: name,
        ecosystem: ecosystem,
        kind: kind,
        installed: installed,
        constraint: constraint,
        latest: info.latest,
        status: status,
        source: source,
        imported: usedInSource,
        advisories: advisories,
        license: license,
        size: size,
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
  ///
  /// [onDone] is told as each item lands. This loop is where a large scan spends
  /// nearly all of its time — two or three registry round trips per package —
  /// so it is the only place a progress count means anything.
  static Future<List<R>> _mapConcurrently<T, R>(
    List<T> items,
    Future<R> Function(T item) task, {
    int concurrency = 8,
    ScanProgressSink onDone = ScanProgressSink.none,
  }) async {
    final results = List<R?>.filled(items.length, null);
    var next = 0;

    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= items.length) return;
        results[index] = await task(items[index]);
        onDone.packageDone();
      }
    }

    await Future.wait([
      for (var i = 0; i < concurrency && i < items.length; i++) worker(),
    ]);
    return results.cast<R>();
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
    PackageRegistry registry,
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
        releasesAbove ??=
            await _stableReleasesAbove(registry, package, current);
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
    PackageRegistry registry,
    String package,
    Version current,
  ) async {
    final versions = await registry.versions(package);
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
}
