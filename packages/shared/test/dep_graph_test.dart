import 'package:shared/shared.dart';
import 'package:test/test.dart';

DepNode node(
  String name, {
  DepKind kind = DepKind.transitive,
  List<String> deps = const [],
  String installed = '1.0.0',
  List<String> manifests = const [],
  List<DepAdvisory> advisories = const [],
  PackageLicense? license,
}) =>
    DepNode(
      name: name,
      kind: kind,
      installed: installed,
      dependencies: deps,
      manifests: manifests,
      advisories: advisories,
      license: license,
    );

void main() {
  group('roots', () {
    test('are what the project declares, direct before dev', () {
      final graph = DependencyGraph.fromNodes([
        node('yaml'),
        node('test', kind: DepKind.dev),
        node('http', kind: DepKind.direct),
        node('args', kind: DepKind.direct),
      ]);

      expect(
        [for (final root in graph.roots) root.name],
        ['args', 'http', 'test'],
      );
    });

    test('are empty when nothing is declared', () {
      expect(DependencyGraph.fromNodes([node('yaml')]).roots, isEmpty);
    });
  });

  group('childrenOf', () {
    test('resolves edges to nodes, alphabetically', () {
      final nodes = [
        node('http', kind: DepKind.direct, deps: ['meta', 'async']),
        node('async'),
        node('meta'),
      ];
      final graph = DependencyGraph.fromNodes(nodes);

      final children = graph.childrenOf(nodes.first);

      expect([for (final c in children) c.name], ['async', 'meta']);
      expect(children.every((c) => c.node != null), isTrue);
    });

    test('drops edges to packages the report does not contain', () {
      final nodes = [
        node('http', kind: DepKind.direct, deps: ['meta', 'ghost']),
        node('meta'),
      ];

      final children = DependencyGraph.fromNodes(nodes).childrenOf(nodes.first);

      expect([for (final c in children) c.name], ['meta']);
    });

    test('picks the version resolved in the same manifest as the parent', () {
      final parent = node(
        'http',
        kind: DepKind.direct,
        deps: ['meta'],
        manifests: ['tools/'],
      );
      final graph = DependencyGraph.fromNodes([
        parent,
        node('meta', installed: '1.9.0', manifests: ['.']),
        node('meta', installed: '1.16.0', manifests: ['tools/']),
      ]);

      final edge = graph.childrenOf(parent).single;

      expect(edge.isAmbiguous, isFalse);
      expect(edge.node!.installed, '1.16.0');
    });

    test('stays ambiguous when the manifests do not settle it', () {
      final parent = node(
        'http',
        kind: DepKind.direct,
        deps: ['meta'],
        manifests: ['apps/cli/'],
      );
      final graph = DependencyGraph.fromNodes([
        parent,
        node('meta', installed: '1.9.0', manifests: ['.']),
        node('meta', installed: '1.16.0', manifests: ['tools/']),
      ]);

      final edge = graph.childrenOf(parent).single;

      expect(edge.isAmbiguous, isTrue);
      expect(edge.node, isNull);
      expect([for (final c in edge.candidates) c.installed], ['1.9.0', '1.16.0']);
    });
  });

  group('duplicates', () {
    test('a single-pubspec report has none', () {
      final graph = DependencyGraph.fromNodes([
        node('http', kind: DepKind.direct, deps: ['meta']),
        node('meta'),
      ]);

      expect(graph.duplicates, isEmpty);
      expect(graph.isDuplicated('meta'), isFalse);
    });

    test('reports a package held at two versions, lowest first', () {
      final graph = DependencyGraph.fromNodes([
        node('meta', installed: '1.16.0', manifests: ['tools/']),
        node('meta', installed: '1.9.0', manifests: ['.']),
        node('http', kind: DepKind.direct, manifests: ['.']),
      ]);

      final duplicate = graph.duplicates.single;

      expect(duplicate.package, 'meta');
      expect(duplicate.installed, ['1.9.0', '1.16.0']);
      expect(duplicate.isAttributed, isTrue);
      expect(duplicate.carriesAdvisory, isFalse);
      expect(graph.isDuplicated('meta'), isTrue);
    });

    test('orders by version rather than by string', () {
      final graph = DependencyGraph.fromNodes([
        node('meta', installed: '1.10.0'),
        node('meta', installed: '1.9.0'),
      ]);

      expect(graph.duplicates.single.installed, ['1.9.0', '1.10.0']);
    });

    test('tolerates a version that is not semver', () {
      final graph = DependencyGraph.fromNodes([
        node('meta', installed: '(unresolved)'),
        node('meta', installed: '1.9.0'),
      ]);

      expect(graph.duplicates.single.versions, hasLength(2));
    });

    test('notices when one of the two versions is vulnerable', () {
      final graph = DependencyGraph.fromNodes([
        node('meta', installed: '1.9.0', advisories: [
          const DepAdvisory(id: 'GHSA-xxxx'),
        ]),
        node('meta', installed: '1.16.0'),
      ]);

      expect(graph.duplicates.single.carriesAdvisory, isTrue);
    });
  });

  group('cycles', () {
    test('an acyclic graph has none', () {
      final graph = DependencyGraph.fromNodes([
        node('http', kind: DepKind.direct, deps: ['meta', 'async']),
        node('async', deps: ['meta']),
        node('meta'),
      ]);

      expect(graph.cycles, isEmpty);
    });

    test('finds a two-package loop', () {
      final graph = DependencyGraph.fromNodes([
        node('a', kind: DepKind.direct, deps: ['b']),
        node('b', deps: ['a']),
      ]);

      final cycle = graph.cycles.single;

      expect(cycle.loop, ['a', 'b']);
      expect(cycle.describe(), 'a → b → a');
      expect(cycle.members, ['a', 'b']);
      expect(cycle.isSelfReference, isFalse);
    });

    test('reports one loop per tangle, not one per way round it', () {
      // a → b → c → a, and b → a directly as well.
      final graph = DependencyGraph.fromNodes([
        node('a', kind: DepKind.direct, deps: ['b']),
        node('b', deps: ['c', 'a']),
        node('c', deps: ['a']),
      ]);

      final cycle = graph.cycles.single;

      // The shortest loop through the group, with the rest of the group named.
      expect(cycle.loop, ['a', 'b']);
      expect(cycle.members, ['a', 'b', 'c']);
      expect(cycle.membersOutsideLoop, ['c']);
    });

    test('separate loops are reported separately, shortest first', () {
      final graph = DependencyGraph.fromNodes([
        node('root', kind: DepKind.direct, deps: ['a', 'x']),
        node('a', deps: ['b']),
        node('b', deps: ['c']),
        node('c', deps: ['a']),
        node('x', deps: ['y']),
        node('y', deps: ['x']),
      ]);

      expect(
        [for (final cycle in graph.cycles) cycle.loop],
        [
          ['x', 'y'],
          ['a', 'b', 'c'],
        ],
      );
    });

    test('finds a package that depends on itself', () {
      final graph = DependencyGraph.fromNodes([
        node('a', kind: DepKind.direct, deps: ['a']),
      ]);

      final cycle = graph.cycles.single;

      expect(cycle.isSelfReference, isTrue);
      expect(cycle.describe(), 'a → a');
    });

    test('a diamond is not a cycle', () {
      final graph = DependencyGraph.fromNodes([
        node('root', kind: DepKind.direct, deps: ['left', 'right']),
        node('left', deps: ['shared']),
        node('right', deps: ['shared']),
        node('shared'),
      ]);

      expect(graph.cycles, isEmpty);
    });
  });

  group('unreachable', () {
    test('is empty when everything hangs off something declared', () {
      final graph = DependencyGraph.fromNodes([
        node('http', kind: DepKind.direct, deps: ['meta']),
        node('meta'),
      ]);

      expect(graph.unreachable, isEmpty);
    });

    test('names packages nothing declared pulls in', () {
      // What a Flutter project looks like: the SDK package is declared but
      // publishes no dependency list, so what it pulls in has no edge holding
      // it.
      final graph = DependencyGraph.fromNodes([
        node(
          'flutter',
          kind: DepKind.direct,
          license: const PackageLicense.notFromPubDev('the SDK'),
        ),
        node('sky_engine'),
        node('characters'),
      ]);

      expect(
        [for (final orphan in graph.unreachable) orphan.name],
        ['characters', 'sky_engine'],
      );
      expect([for (final n in graph.outsidePubDev) n.name], ['flutter']);
    });
  });

  test('reads a report directly', () {
    final report = DepReport(
      projectId: 'p1',
      generatedAt: DateTime.utc(2026),
      nodes: [
        node('http', kind: DepKind.direct, deps: ['meta']),
        node('meta'),
      ],
    );

    final graph = DependencyGraph.of(report);

    expect(graph.roots.single.name, 'http');
    expect(graph.spansManifests, isFalse);
  });
}
