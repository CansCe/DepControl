import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import '../theme.dart';
import 'dep_kind_badge.dart';
import 'dep_status_chip.dart';

/// The dependency graph as an expanding tree, plus the two things that are
/// wrong with its shape: a package held at two versions, and a loop.
///
/// An indented tree rather than a node-link diagram. The whole graph drawn as
/// nodes and edges — ~150 packages, ~400 edges — is a cobweb at any layout, and
/// the questions people bring to it ("what does this pull in", "why is this
/// here twice") are answered by an outline they can walk. Branches expand one
/// at a time, so the depth on screen is the depth someone asked for.
///
/// Everything structural is drawn in ink and slate rather than in a colour of
/// its own. This app already spends three palettes — the semver triad, the
/// advisory ramp, the license verdicts — and each is only legible because it is
/// never borrowed for something else. Duplication and cycles are facts about
/// the shape of the graph, not judgements from any of those three, so they take
/// the chrome colour. Where a duplicate is *also* a security finding, the
/// advisory red says so, because at that point it is one.
class DependencyTree extends StatefulWidget {
  const DependencyTree({
    required this.report,
    this.onSelect,
    this.showCurrency = true,
    super.key,
  });

  final DepReport report;

  /// Called when a package is tapped, e.g. to explain why it is present.
  final void Function(DepNode node)? onSelect;

  /// Whether a version may be coloured by how it compares to pub.dev. False for
  /// an archived project, where that comparison is one the snapshot stepped
  /// away from — the tree then carries structure and advisories only.
  final bool showCurrency;

  @override
  State<DependencyTree> createState() => _DependencyTreeState();
}

class _DependencyTreeState extends State<DependencyTree> {
  late DependencyGraph _graph = DependencyGraph.of(widget.report);

  /// Which branches are open, keyed by the path that reaches them — the same
  /// package under two parents opens and closes independently, because those
  /// are two different questions.
  final _expanded = <String>{};

  @override
  void didUpdateWidget(covariant DependencyTree old) {
    super.didUpdateWidget(old);
    if (old.report != widget.report) {
      _graph = DependencyGraph.of(widget.report);
      _expanded.clear();
    }
  }

  void _toggle(String path) {
    setState(() {
      if (!_expanded.remove(path)) _expanded.add(path);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final roots = _graph.roots;

    if (roots.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'This report contains no dependency the project declares itself, so '
          'there is no root to grow a tree from.',
          style: theme.textTheme.bodySmall,
        ),
      );
    }

    final direct = roots.where((r) => r.kind == DepKind.direct).length;
    final dev = roots.length - direct;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '$direct direct and $dev dev ${dev == 1 ? 'dependency' : 'dependencies'}, '
          'expanding into ${widget.report.total} packages. '
          'Open a branch to see what it pulls in; tap a package for the rest.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 14),
        _Findings(graph: _graph),
        const SizedBox(height: 4),
        for (final root in roots)
          _Branch(
            node: root,
            graph: _graph,
            path: root.key,
            ancestors: {root.name},
            depth: 0,
            isExpanded: _expanded.contains,
            onToggle: _toggle,
            onSelect: widget.onSelect,
            showCurrency: widget.showCurrency,
          ),
      ],
    );
  }
}

/// One package and, when opened, what it pulls in.
class _Branch extends StatelessWidget {
  const _Branch({
    required this.node,
    required this.graph,
    required this.path,
    required this.ancestors,
    required this.depth,
    required this.isExpanded,
    required this.onToggle,
    required this.onSelect,
    required this.showCurrency,
  });

  final DepNode node;
  final DependencyGraph graph;

  /// Identifies this row's position, so expansion is per-branch.
  final String path;

  /// The names between the root and here — what a child has to avoid being for
  /// the walk to continue.
  final Set<String> ancestors;

  final int depth;
  final bool Function(String path) isExpanded;
  final void Function(String path) onToggle;
  final void Function(DepNode node)? onSelect;
  final bool showCurrency;

  @override
  Widget build(BuildContext context) {
    final children = graph.childrenOf(node);
    final open = isExpanded(path);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Row(
          node: node,
          graph: graph,
          isOpen: open,
          hasChildren: children.isNotEmpty,
          showKind: depth == 0,
          showCurrency: showCurrency,
          onToggle: children.isEmpty ? null : () => onToggle(path),
          onSelect: onSelect == null ? null : () => onSelect!(node),
        ),
        if (open)
          _Indent(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final edge in children)
                  _Child(
                    edge: edge,
                    graph: graph,
                    parentPath: path,
                    ancestors: ancestors,
                    depth: depth + 1,
                    isExpanded: isExpanded,
                    onToggle: onToggle,
                    onSelect: onSelect,
                    showCurrency: showCurrency,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One edge below an open branch: another branch, a loop that stops here, or a
/// name the report cannot pin to one version.
class _Child extends StatelessWidget {
  const _Child({
    required this.edge,
    required this.graph,
    required this.parentPath,
    required this.ancestors,
    required this.depth,
    required this.isExpanded,
    required this.onToggle,
    required this.onSelect,
    required this.showCurrency,
  });

  final DepEdge edge;
  final DependencyGraph graph;
  final String parentPath;
  final Set<String> ancestors;
  final int depth;
  final bool Function(String path) isExpanded;
  final void Function(String path) onToggle;
  final void Function(DepNode node)? onSelect;
  final bool showCurrency;

  @override
  Widget build(BuildContext context) {
    // The walk stops where it would repeat itself. Following the loop instead
    // would draw an infinitely deep tree, and the useful thing to say is that
    // it closes, not to keep drawing it.
    if (ancestors.contains(edge.name)) {
      return _LoopStop(name: edge.name);
    }

    // Two versions and nothing in the report says which this edge means. A tree
    // has to draw one subtree, so it draws none and says why.
    final node = edge.node;
    if (node == null) return _Unresolved(edge: edge);

    return _Branch(
      node: node,
      graph: graph,
      path: '$parentPath/${node.key}',
      ancestors: {...ancestors, node.name},
      depth: depth,
      isExpanded: isExpanded,
      onToggle: onToggle,
      onSelect: onSelect,
      showCurrency: showCurrency,
    );
  }
}

/// The row itself: a disclosure control, the package, its version, and whatever
/// is worth flagging about it.
class _Row extends StatelessWidget {
  const _Row({
    required this.node,
    required this.graph,
    required this.isOpen,
    required this.hasChildren,
    required this.showKind,
    required this.showCurrency,
    required this.onToggle,
    required this.onSelect,
  });

  final DepNode node;
  final DependencyGraph graph;
  final bool isOpen;
  final bool hasChildren;
  final bool showKind;
  final bool showCurrency;
  final VoidCallback? onToggle;
  final VoidCallback? onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDuplicated = graph.isDuplicated(node.name);
    final versionColor = node.advisories.isNotEmpty
        ? depStatusColor(DepStatus.vulnerable)
        : showCurrency
            ? depStatusColor(node.status)
            : Palette.slate;

    return Row(
      children: [
        SizedBox(
          width: 28,
          height: 30,
          child: hasChildren
              ? IconButton(
                  onPressed: onToggle,
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  splashRadius: 16,
                  tooltip: isOpen ? 'Collapse' : 'Expand',
                  icon: Icon(
                    isOpen ? Icons.expand_more : Icons.chevron_right,
                    color: Palette.slate,
                  ),
                )
              : Center(
                  child: Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Palette.slate.withValues(alpha: 0.5),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
        ),
        Expanded(
          child: InkWell(
            onTap: onSelect,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  Text(
                    node.name,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    node.installed,
                    style: mono(theme.textTheme.bodySmall, color: versionColor),
                  ),
                  if (showKind) DepKindBadge(kind: node.kind),
                  if (isDuplicated)
                    _Flag(
                      icon: Icons.call_split,
                      // The count is the point: this row is one of two, and
                      // whatever you do to it leaves the other one alone.
                      label: '${graph.versionsOf(node.name).length} versions',
                    ),
                  if (node.advisories.isNotEmpty)
                    _Flag(
                      icon: Icons.gpp_maybe_outlined,
                      label: node.advisories.length == 1
                          ? '1 advisory'
                          : '${node.advisories.length} advisories',
                      color: depStatusColor(DepStatus.vulnerable),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Where a branch closes back on something already above it.
class _LoopStop extends StatelessWidget {
  const _LoopStop({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 5, 4, 5),
      child: Row(
        children: [
          Icon(Icons.u_turn_left, size: 15, color: Palette.slate),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$name — already above this, so the branch closes here',
              style: theme.textTheme.bodySmall?.copyWith(color: Palette.slate),
            ),
          ),
        ],
      ),
    );
  }
}

/// An edge to a package the repository holds twice, where nothing records which
/// of the two this particular edge resolved to.
class _Unresolved extends StatelessWidget {
  const _Unresolved({required this.edge});

  final DepEdge edge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 5, 4, 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.call_split, size: 15, color: Palette.slate),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: edge.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  TextSpan(
                    text: ' — in this repository at '
                        '${[for (final c in edge.candidates) c.installed].join(' and ')}'
                        ', and which of them this edge means is not recorded.',
                  ),
                ],
              ),
              style: theme.textTheme.bodySmall?.copyWith(color: Palette.slate),
            ),
          ),
        ],
      ),
    );
  }
}

/// A small outlined flag beside a package name.
class _Flag extends StatelessWidget {
  const _Flag({required this.icon, required this.label, this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = color ?? Palette.ink;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.07),
        border: Border.all(color: tint.withValues(alpha: 0.28)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: tint),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: tint,
              fontSize: 10,
              height: 1.4,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// One level of nesting, with the rule that makes the level visible.
class _Indent extends StatelessWidget {
  const _Indent({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 13),
      child: Container(
        padding: const EdgeInsets.only(left: 10),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: Palette.ink.withValues(alpha: 0.12)),
          ),
        ),
        child: child,
      ),
    );
  }
}

/// What is wrong with the shape of the graph, before anyone opens a branch.
///
/// Stated up front because neither finding is something a reader would come
/// across by browsing: a duplicate is only visible if you happen to open both
/// branches, and a cycle is invisible by construction — the tree stops at it.
class _Findings extends StatelessWidget {
  const _Findings({required this.graph});

  final DependencyGraph graph;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final duplicates = graph.duplicates;
    final cycles = graph.cycles;
    final unreachable = graph.unreachable;

    if (duplicates.isEmpty && cycles.isEmpty && unreachable.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            const Icon(Icons.check, size: 15, color: Palette.patch),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'No package appears at two versions, and no dependency loops '
                'back on itself.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (duplicates.isNotEmpty) ...[
          _Panel(
            icon: Icons.call_split,
            title: duplicates.length == 1
                ? '1 package at two versions'
                : '${duplicates.length} packages at more than one version',
            accent: duplicates.any((d) => d.carriesAdvisory)
                ? depStatusColor(DepStatus.vulnerable)
                : Palette.ink,
            children: [
              for (final duplicate in duplicates)
                _Duplicate(duplicate: duplicate),
              const SizedBox(height: 4),
              Text(
                'pub resolves one version per package, so this can only come '
                'from pubspecs that resolved separately. They will not move '
                'together: upgrading one leaves the other where it is.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 10),
        ],
        if (cycles.isNotEmpty) ...[
          _Panel(
            icon: Icons.loop,
            title: cycles.length == 1
                ? '1 dependency loop'
                : '${cycles.length} dependency loops',
            accent: Palette.ink,
            children: [
              for (final cycle in cycles) _Cycle(cycle: cycle),
              const SizedBox(height: 4),
              Text(
                graph.spansManifests
                    // The merge is the analyzer's, and it is the right one for
                    // counting packages. It is the wrong one for asserting a
                    // loop, so the caveat travels with the finding.
                    ? 'Loops are traced through package names. This report '
                        'merges several pubspecs, and a package resolved twice '
                        'contributes both versions\' dependencies here — so a '
                        'loop may be an artefact of that merge rather than '
                        'something any single resolution contains.'
                    : 'A loop is not an error — pub resolves them — but it '
                        'means these packages have to be released together, '
                        'and the branches above stop where they close.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 10),
        ],
        if (unreachable.isNotEmpty) ...[
          _Panel(
            icon: Icons.link_off,
            title: '${unreachable.length} '
                '${unreachable.length == 1 ? 'package sits' : 'packages sit'} '
                'outside the tree',
            accent: Palette.ink,
            children: [
              Text(
                [for (final node in unreachable.take(12)) node.name].join(', ') +
                    (unreachable.length > 12
                        ? ', and ${unreachable.length - 12} more'
                        : ''),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 6),
              Text(
                graph.outsidePubDev.isEmpty
                    ? 'Nothing the project declares reaches these, so the tree '
                        'has nowhere to hang them. They are in the report, and '
                        'in the table below.'
                    : 'This report has '
                        '${graph.outsidePubDev.length} '
                        '${graph.outsidePubDev.length == 1 ? 'package' : 'packages'} '
                        'that do not come from pub.dev — '
                        '${[for (final n in graph.outsidePubDev.take(4)) n.name].join(', ')}'
                        '${graph.outsidePubDev.length > 4 ? ', and others' : ''}'
                        ' — and pub.dev is the only thing that could say what '
                        'they depend on. What they pull in is therefore in the '
                        'report with no edge holding it.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

/// One package held at several versions, and which pubspec holds which.
class _Duplicate extends StatelessWidget {
  const _Duplicate({required this.duplicate});

  final DuplicateVersions duplicate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            duplicate.package,
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          for (final version in duplicate.versions)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 2),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  Text(
                    version.installed,
                    style: mono(
                      theme.textTheme.bodySmall,
                      color: version.advisories.isNotEmpty
                          ? depStatusColor(DepStatus.vulnerable)
                          : Palette.ink,
                    ),
                  ),
                  if (version.manifests.isNotEmpty)
                    Text(
                      'from ${version.manifests.join(', ')}',
                      style: theme.textTheme.bodySmall,
                    ),
                  if (version.advisories.isNotEmpty)
                    Text(
                      version.advisories.length == 1
                          ? 'carries 1 advisory'
                          : 'carries ${version.advisories.length} advisories',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: depStatusColor(DepStatus.vulnerable),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// One loop, written out.
class _Cycle extends StatelessWidget {
  const _Cycle({required this.cycle});

  final DependencyCycle cycle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outside = cycle.membersOutsideLoop;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            cycle.isSelfReference
                ? '${cycle.loop.single} depends on itself'
                : cycle.describe(),
            style: mono(theme.textTheme.bodyMedium, color: Palette.ink)
                .copyWith(fontWeight: FontWeight.w600),
          ),
          if (outside.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                outside.length == 1
                    ? 'Tangled with it: ${outside.single}.'
                    : 'Tangled with it: ${outside.join(', ')}.',
                style: theme.textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

/// An inset block for one finding.
class _Panel extends StatelessWidget {
  const _Panel({
    required this.icon,
    required this.title,
    required this.accent,
    required this.children,
  });

  final IconData icon;
  final String title;
  final Color accent;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.04),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(color: accent),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}
