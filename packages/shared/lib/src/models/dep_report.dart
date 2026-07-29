import 'dep_advisory.dart';
import 'dep_node.dart';

/// The result of inspecting a project's dependencies (Phase 1).
class DepReport {
  const DepReport({
    required this.projectId,
    required this.generatedAt,
    required this.nodes,
    this.manifests = const [],
    this.coverageNote,
  });

  final String projectId;
  final DateTime generatedAt;

  /// The repository's pubspec directories that this report covers, root first
  /// (the root is the empty string). Empty for a single-package repository.
  final List<String> manifests;

  /// Set when the report knowingly covers less than the whole repository —
  /// discovery was unavailable, or there were more pubspecs than it will read.
  ///
  /// Surfaced rather than swallowed: a dependency count that quietly omits half
  /// a monorepo is worse than one that says what it missed.
  final String? coverageNote;

  /// Flat list of every resolved dependency. Graph edges live on each node's
  /// [DepNode.dependencies].
  final List<DepNode> nodes;

  int get total => nodes.length;
  int get outdated =>
      nodes.where((n) => n.status == DepStatus.outdated).length;
  int get vulnerable =>
      nodes.where((n) => n.status == DepStatus.vulnerable).length;

  /// How many advisories fall in each band, worst first and skipping bands
  /// with none.
  ///
  /// Counts advisories rather than packages: one package carrying a critical
  /// and a low is two different pieces of news, and collapsing them to a single
  /// "vulnerable package" hides the one that matters.
  Map<AdvisorySeverity, int> get advisoryCounts {
    final counts = <AdvisorySeverity, int>{};
    for (final node in nodes) {
      for (final advisory in node.advisories) {
        counts.update(advisory.severity, (n) => n + 1, ifAbsent: () => 1);
      }
    }

    return {
      for (final severity in AdvisorySeverity.values)
        if (counts[severity] != null) severity: counts[severity]!,
    };
  }

  /// The worst advisory anywhere in the report, or null when there are none.
  AdvisorySeverity? get worstSeverity {
    final counted = advisoryCounts.keys;
    return counted.isEmpty ? null : counted.first;
  }

  /// Packages carrying at least one advisory, worst first, then by name.
  ///
  /// Ordering is the whole value of a list like this: the reader deals with the
  /// top of it and runs out of time somewhere further down.
  List<DepNode> get affectedNodes {
    final affected =
        nodes.where((n) => n.advisories.isNotEmpty).toList(growable: false);

    int rank(DepNode node) => node.advisories
        .map((a) => AdvisorySeverity.values.indexOf(a.severity))
        .reduce((a, b) => a < b ? a : b);

    return affected.toList()
      ..sort((a, b) {
        final bySeverity = rank(a).compareTo(rank(b));
        return bySeverity != 0 ? bySeverity : a.name.compareTo(b.name);
      });
  }

  /// Packages nothing you ship depends on — reachable only through dev
  /// dependencies.
  ///
  /// Computed by walking the graph out from the *regular* direct dependencies:
  /// whatever that walk does not reach is not linked into the built artefact.
  /// The distinction matters to license compliance, where a GPL code generator
  /// and a GPL runtime library are entirely different problems. It says nothing
  /// about security, where a compromised build tool is a real one.
  ///
  /// Names rather than `name@version` keys, because the graph's edges are
  /// names. Where a repository resolves one package at two versions the walk
  /// follows the union of their edges, which over-reaches — and over-reaching
  /// here means calling something shipped that might not be, so a package is
  /// checked rather than quietly exempted.
  Set<String> get devOnlyPackages {
    final edges = <String, List<String>>{};
    for (final node in nodes) {
      (edges[node.name] ??= <String>[]).addAll(node.dependencies);
    }

    final shipped = <String>{
      for (final node in nodes)
        if (node.kind == DepKind.direct) node.name,
    };

    final queue = shipped.toList();
    while (queue.isNotEmpty) {
      for (final child in edges[queue.removeLast()] ?? const <String>[]) {
        if (shipped.add(child)) queue.add(child);
      }
    }

    return {
      for (final node in nodes)
        if (!shipped.contains(node.name)) node.name,
    };
  }

  /// Whether this report knows anything about what the project's source
  /// imports. False for a scan that could only reach the manifests, where both
  /// import findings below are silent rather than empty.
  bool get scannedImports => nodes.any((n) => n.imported != null);

  /// Packages the source imports without any pubspec declaring them, worst
  /// first by name.
  ///
  /// These resolve today only because another dependency happens to pull them
  /// in. Nothing warns when that stops being true — the build simply fails, at
  /// whatever unrelated moment somebody upgrades the package in the middle.
  List<DepNode> get undeclaredImports => nodes
      .where((n) => n.kind == DepKind.transitive && n.imported == true)
      .toList()
    ..sort((a, b) => a.name.compareTo(b.name));

  /// Declared dependencies no source file imports.
  ///
  /// Worth deleting: each one is a package whose advisories somebody has to
  /// read, whose version constrains the resolution of everything else, and
  /// which buys nothing. Packages that are used *without* being imported are
  /// excluded — see [usedWithoutImporting] for what that means and why the
  /// exclusion has to exist.
  List<DepNode> get unimportedDeclarations => nodes
      .where(
        (n) =>
            n.kind != DepKind.transitive &&
            n.imported == false &&
            !usedWithoutImporting(n.name),
      )
      .toList()
    ..sort((a, b) => a.name.compareTo(b.name));

  /// Whether [package] is the kind of dependency a project uses without ever
  /// importing it, and so cannot be called unused on the evidence of its
  /// imports alone.
  ///
  /// Three sorts qualify:
  ///
  /// * lint rule sets, pulled in by `analysis_options.yaml` — though the
  ///   scanner reads `include:` lines too, so these are only reached when a
  ///   project configures them somewhere else;
  /// * build tooling, which runs as a command rather than being called;
  /// * code generators, whose *output* is what the project imports. The `_gen`
  ///   suffixes catch the ones nobody thought to list here, which is most of
  ///   them — the ecosystem's naming convention is doing real work.
  ///
  /// The list is a judgement and will be wrong at the edges. It errs towards
  /// staying quiet: a package wrongly excluded costs a suggestion nobody was
  /// obliged to take, and a package wrongly named unused costs the reader's
  /// trust in every other line of the report.
  static bool usedWithoutImporting(String package) =>
      _usedWithoutImporting.contains(package) ||
      package.endsWith('_generator') ||
      package.endsWith('_builder') ||
      package.endsWith('_gen');

  static const _usedWithoutImporting = {
    // Lint rule sets.
    'lints',
    'flutter_lints',
    'very_good_analysis',
    'dart_flutter_team_lints',
    // Build and release tooling, invoked from the command line.
    'build_runner',
    'build_web_compilers',
    'build_test',
    'dart_frog_cli',
    'melos',
    'pana',
    'coverage',
    'flutter_launcher_icons',
    'flutter_native_splash',
    // Generators whose output, not whose API, is what gets imported.
    'json_serializable',
    'freezed',
    'drift_dev',
  };

  factory DepReport.fromJson(Map<String, dynamic> json) {
    return DepReport(
      projectId: json['projectId'] as String,
      generatedAt: DateTime.parse(json['generatedAt'] as String),
      nodes: (json['nodes'] as List)
          .map((e) => DepNode.fromJson(e as Map<String, dynamic>))
          .toList(),
      manifests: (json['manifests'] as List?)?.cast<String>() ?? const [],
      coverageNote: json['coverageNote'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'projectId': projectId,
        'generatedAt': generatedAt.toIso8601String(),
        'nodes': nodes.map((n) => n.toJson()).toList(),
        if (manifests.isNotEmpty) 'manifests': manifests,
        if (coverageNote != null) 'coverageNote': coverageNote,
      };
}
