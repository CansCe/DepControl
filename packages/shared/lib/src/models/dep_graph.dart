import 'dart:collection';

import 'package:pub_semver/pub_semver.dart';

import 'dep_node.dart';
import 'dep_report.dart';
import 'package_license.dart';

/// A report's nodes read as a graph: what pulls in what, which packages the
/// repository ended up with twice, and where the edges close a loop.
///
/// The edges are **names**, because a name is all a [DepNode] records — pub
/// resolves one version per package per resolution, so within a manifest a name
/// is unambiguous and nothing is lost. Where a repository has several pubspecs
/// it can hold two versions of one package, and then a name is not enough on
/// its own; [childrenOf] resolves that with `manifests` rather than guessing,
/// and says so when it cannot.
///
/// Nothing here fetches anything. Every answer comes out of the report as
/// stored, so it says exactly as much as the analysis that produced it did —
/// see [unreachable] for the one place that shows through.
class DependencyGraph {
  DependencyGraph._(this.nodes, this._byName, this._adjacency);

  factory DependencyGraph.of(DepReport report) =>
      DependencyGraph.fromNodes(report.nodes);

  factory DependencyGraph.fromNodes(List<DepNode> nodes) {
    final byName = <String, List<DepNode>>{};
    for (final node in nodes) {
      (byName[node.name] ??= <DepNode>[]).add(node);
    }
    for (final versions in byName.values) {
      versions.sort(_byVersion);
    }

    // Name-level adjacency, which for a package held at two versions is the
    // union of both versions' edges. That over-reaches in the same direction
    // the analyzer already chose when it merged them: an edge that exists in
    // one manifest's resolution is shown rather than dropped. [cycles] carries
    // the caveat that follows from it.
    final adjacency = <String, Set<String>>{};
    for (final node in nodes) {
      final out = adjacency[node.name] ??= <String>{};
      for (final child in node.dependencies) {
        // Edges to packages the report does not contain are dropped: the
        // analyzer already filters these, and a dangling edge would render as
        // a row with nothing behind it.
        if (byName.containsKey(child)) out.add(child);
      }
    }

    return DependencyGraph._(
      List.unmodifiable(nodes),
      byName,
      adjacency,
    );
  }

  /// Every node in the report, as given.
  final List<DepNode> nodes;

  final Map<String, List<DepNode>> _byName;
  final Map<String, Set<String>> _adjacency;

  /// The packages the repository declares — where a tree starts. Direct
  /// dependencies first, then dev ones, each alphabetical.
  late final List<DepNode> roots = () {
    final declared = [
      for (final node in nodes)
        if (node.kind != DepKind.transitive) node,
    ]..sort((a, b) {
        final byKind = a.kind.index.compareTo(b.kind.index);
        if (byKind != 0) return byKind;
        final byName = a.name.compareTo(b.name);
        return byName != 0 ? byName : a.installed.compareTo(b.installed);
      });
    return List<DepNode>.unmodifiable(declared);
  }();

  /// What [parent] pulls in, alphabetically.
  ///
  /// One [DepEdge] per name rather than per node, because an edge in this graph
  /// *is* a name. Where the repository holds that name at two versions the edge
  /// carries both, and the reader is told there are two rather than shown one
  /// picked by coin toss.
  List<DepEdge> childrenOf(DepNode parent) {
    final names = parent.dependencies.toSet().toList()..sort();
    final edges = <DepEdge>[];

    for (final name in names) {
      final candidates = _candidatesFor(name, parent);
      if (candidates.isNotEmpty) edges.add(DepEdge._(name, candidates));
    }

    return edges;
  }

  /// Which node(s) an edge to [name] can mean, given what pulls it in.
  ///
  /// Two versions of one package were resolved by two different pubspecs, and
  /// `manifests` records which. An edge from a parent resolved in one of them
  /// means the version resolved alongside it — that is a fact about how pub
  /// works, not an inference. Only when the manifests do not settle it does the
  /// edge stay ambiguous.
  List<DepNode> _candidatesFor(String name, DepNode parent) {
    final versions = _byName[name] ?? const <DepNode>[];
    if (versions.length < 2 || parent.manifests.isEmpty) return versions;

    final shared = [
      for (final version in versions)
        if (version.manifests.any(parent.manifests.contains)) version,
    ];
    return shared.isEmpty ? versions : shared;
  }

  /// Every version of [name] the report holds, lowest first.
  List<DepNode> versionsOf(String name) => _byName[name] ?? const <DepNode>[];

  /// Whether [name] is in the report at more than one version.
  bool isDuplicated(String name) => (_byName[name]?.length ?? 0) > 1;

  /// Packages the report holds at more than one version, alphabetically.
  ///
  /// In a single-pubspec repository this is always empty, and that is not a
  /// weakness of the check: pub resolves one version per package, so two would
  /// mean the lockfile disagreed with itself. It fills up for a repository with
  /// several pubspecs, where a directory outside the workspace resolves on its
  /// own and can land somewhere else entirely — which is worth knowing, because
  /// an advisory fixed in one of them is not fixed in the other.
  late final List<DuplicateVersions> duplicates = () {
    final names = _byName.keys.toList()..sort();
    return List<DuplicateVersions>.unmodifiable([
      for (final name in names)
        if (_byName[name]!.length > 1)
          DuplicateVersions._(name, List.unmodifiable(_byName[name]!)),
    ]);
  }();

  /// Loops in the graph — one per group of packages that can reach each other,
  /// shortest first.
  ///
  /// Found with Tarjan's strongly-connected components, so a group is reported
  /// once with a concrete loop through it rather than once per way round it.
  ///
  /// A cycle here is a statement about the *name* graph. Where the report
  /// covers several pubspecs, edges from two versions of one package are
  /// unioned, so a loop can be an artefact of that merge rather than something
  /// any single resolution contains — [spansManifests] is what tells a caller
  /// to say so.
  late final List<DependencyCycle> cycles = _findCycles();

  /// Packages nothing you declare can reach.
  ///
  /// Usually not a mystery: a package from the SDK, a path or a git dependency
  /// is not published on pub.dev, so nothing can be read about what *it*
  /// depends on, and its subtree arrives in the report with no edge holding it.
  /// [outsidePubDev] is the set that explains it. Reported rather than
  /// swallowed, because a tree that silently omits a tenth of the lockfile is
  /// worse than one that says which tenth.
  late final List<DepNode> unreachable = () {
    final reached = <String>{for (final root in roots) root.name};
    final queue = Queue<String>.of(reached);

    while (queue.isNotEmpty) {
      for (final child in _adjacency[queue.removeFirst()] ?? const <String>{}) {
        if (reached.add(child)) queue.add(child);
      }
    }

    final orphans = [
      for (final node in nodes)
        if (!reached.contains(node.name)) node,
    ]..sort((a, b) {
        final byName = a.name.compareTo(b.name);
        return byName != 0 ? byName : a.installed.compareTo(b.installed);
      });
    return List<DepNode>.unmodifiable(orphans);
  }();

  /// Packages that are not published on pub.dev — the SDK, a path or a git
  /// dependency — and so contribute no edges of their own.
  late final List<DepNode> outsidePubDev = List.unmodifiable([
    for (final node in nodes)
      if (node.license?.source == LicenseSource.notFromPubDev) node,
  ]);

  /// Whether this report merges several pubspecs, which is what makes a name
  /// able to mean two versions.
  late final bool spansManifests = nodes.any((n) => n.manifests.isNotEmpty);

  List<DependencyCycle> _findCycles() {
    // Tarjan, iterating names in sorted order so the same report always yields
    // the same components in the same order.
    final index = <String, int>{};
    final low = <String, int>{};
    final onStack = <String>{};
    final stack = <String>[];
    final components = <List<String>>[];
    var counter = 0;

    void connect(String node) {
      index[node] = counter;
      low[node] = counter;
      counter++;
      stack.add(node);
      onStack.add(node);

      for (final child in _sortedEdges(node)) {
        if (!index.containsKey(child)) {
          connect(child);
          low[node] = _min(low[node]!, low[child]!);
        } else if (onStack.contains(child)) {
          low[node] = _min(low[node]!, index[child]!);
        }
      }

      if (low[node] != index[node]) return;

      final component = <String>[];
      String popped;
      do {
        popped = stack.removeLast();
        onStack.remove(popped);
        component.add(popped);
      } while (popped != node);
      components.add(component);
    }

    for (final name in _adjacency.keys.toList()..sort()) {
      if (!index.containsKey(name)) connect(name);
    }

    final found = <DependencyCycle>[];
    for (final component in components) {
      final members = component.toList()..sort();

      if (component.length == 1) {
        // A single-node component is only a cycle if it points at itself.
        final only = component.single;
        if (!(_adjacency[only]?.contains(only) ?? false)) continue;
        found.add(
          DependencyCycle._(List.unmodifiable([only]), List.unmodifiable([only])),
        );
        continue;
      }

      found.add(
        DependencyCycle._(
          List.unmodifiable(_shortestLoop(members.first, members.toSet())),
          List.unmodifiable(members),
        ),
      );
    }

    found.sort((a, b) {
      final byLength = a.loop.length.compareTo(b.loop.length);
      return byLength != 0 ? byLength : a.loop.first.compareTo(b.loop.first);
    });
    return List.unmodifiable(found);
  }

  List<String> _sortedEdges(String node) =>
      (_adjacency[node] ?? const <String>{}).toList()..sort();

  /// The shortest loop through [start] within [members].
  ///
  /// A component says which packages are tangled; the loop is what someone can
  /// actually read, so it is worth the extra breadth-first walk to report the
  /// tightest one rather than whichever the depth-first search happened to take.
  List<String> _shortestLoop(String start, Set<String> members) {
    final parents = <String, String>{};
    final queue = Queue<String>()..add(start);
    final seen = <String>{start};

    while (queue.isNotEmpty) {
      final current = queue.removeFirst();

      for (final next in _sortedEdges(current)) {
        if (!members.contains(next)) continue;

        if (next == start) {
          final loop = <String>[current];
          var step = current;
          while (parents.containsKey(step)) {
            step = parents[step]!;
            loop.add(step);
          }
          return loop.reversed.toList();
        }

        if (seen.add(next)) {
          parents[next] = current;
          queue.add(next);
        }
      }
    }

    // Unreachable for a real component, where every member is on a loop.
    return [start];
  }

  static int _min(int a, int b) => a < b ? a : b;

  /// Orders two versions of one package, falling back to string order for the
  /// `(unresolved)` sentinel and anything else that is not semver.
  static int _byVersion(DepNode a, DepNode b) {
    final left = _tryParse(a.installed);
    final right = _tryParse(b.installed);
    if (left != null && right != null) return left.compareTo(right);
    return a.installed.compareTo(b.installed);
  }

  static Version? _tryParse(String text) {
    try {
      return Version.parse(text);
    } on FormatException {
      return null;
    }
  }
}

/// One edge out of a package: a name, and the node(s) that name can mean here.
class DepEdge {
  const DepEdge._(this.name, this.candidates);

  final String name;

  /// The version(s) this edge resolves to — one, except where a repository
  /// holds the package twice and its manifests do not say which is meant.
  final List<DepNode> candidates;

  /// The node this edge means, or null when the report cannot say which of two
  /// versions it is.
  DepNode? get node => candidates.length == 1 ? candidates.single : null;

  bool get isAmbiguous => candidates.length > 1;
}

/// One package the report holds at more than one version.
class DuplicateVersions {
  const DuplicateVersions._(this.package, this.versions);

  final String package;

  /// Every version of [package] in the report, lowest first.
  final List<DepNode> versions;

  /// The versions as strings, lowest first.
  List<String> get installed => [for (final v in versions) v.installed];

  /// Whether one of these versions carries an advisory.
  ///
  /// The case that makes duplication urgent rather than untidy: upgrading the
  /// copy you noticed leaves the other one exactly as vulnerable as it was.
  bool get carriesAdvisory => versions.any((v) => v.advisories.isNotEmpty);

  /// Whether the versions can be attributed to particular pubspecs — which
  /// they can whenever the report covers more than one.
  bool get isAttributed => versions.every((v) => v.manifests.isNotEmpty);
}

/// A loop in the dependency graph.
class DependencyCycle {
  const DependencyCycle._(this.loop, this.members);

  /// One loop, in order: `[a, b, c]` reads a → b → c → a.
  final List<String> loop;

  /// Every package that can reach every other in this group. Equal to [loop]
  /// for a simple cycle, larger where several loops share packages.
  final List<String> members;

  /// A package that depends on itself.
  bool get isSelfReference => loop.length == 1;

  /// Packages tangled together that this loop does not pass through.
  List<String> get membersOutsideLoop =>
      [for (final m in members) if (!loop.contains(m)) m];

  /// `a → b → c → a`.
  String describe() => [...loop, loop.first].join(' → ');
}
