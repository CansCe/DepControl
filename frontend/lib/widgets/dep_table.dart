import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import '../theme.dart';
import 'dep_kind_badge.dart';
import 'dep_status_chip.dart';

/// Below this width a five-column table only has room for two of them, so the
/// rest of each row is invisible. The compact layout stacks instead.
const _compactBreakpoint = 600.0;

/// A project's dependencies, as a sortable table on wide screens and a stacked
/// list on narrow ones.
class DepTable extends StatefulWidget {
  const DepTable({
    super.key,
    required this.nodes,
    this.onSelect,
    this.showCurrency = true,
  });

  /// Whether to show how each version compares to the newest published one.
  ///
  /// False for an archived project, where the report is a snapshot of what was
  /// depended on. "Outdated" against today's pub.dev would be a comparison
  /// nobody asked for and could not act on without restoring the project.
  final bool showCurrency;

  final List<DepNode> nodes;

  /// Called when a row is tapped, e.g. to explain why the package is present.
  final void Function(DepNode node)? onSelect;

  @override
  State<DepTable> createState() => _DepTableState();
}

class _DepTableState extends State<DepTable> {
  /// How many rows are on screen before the reader asks for more.
  ///
  /// The table sits inside the report's one scroll view, so nothing about it is
  /// lazy — every row it holds is a built widget whether or not it is anywhere
  /// near the viewport. At a few dozen packages that is free; on a monorepo
  /// resolving fourteen hundred it is several thousand widgets rebuilt on every
  /// frame of every scroll, which is what makes a large project feel broken.
  ///
  /// A hundred is more than fits on any screen this runs on, so the first page
  /// is never visibly short, and the filter above means someone looking for one
  /// package never has to page at all.
  static const _pageSize = 100;

  int _sortColumn = 0;
  bool _ascending = true;

  final _searchController = TextEditingController();
  String _query = '';
  int _shown = _pageSize;

  /// [DepTable.nodes], filtered and sorted. Held rather than recomputed,
  /// because sorting a few thousand nodes per build is its own tax.
  late List<DepNode> _rows;

  @override
  void initState() {
    super.initState();
    _rebuildRows();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant DepTable old) {
    super.didUpdateWidget(old);
    if (old.nodes != widget.nodes) {
      _rebuildRows();
      _shown = _pageSize;
    }
  }

  void _rebuildRows() {
    final query = _query.trim().toLowerCase();
    _rows = query.isEmpty
        ? [...widget.nodes]
        : widget.nodes
            .where((n) => n.name.toLowerCase().contains(query))
            .toList();
    _applySort();
  }

  void _search(String value) {
    setState(() {
      _query = value;
      // Back to the first page: the point of narrowing the list is to see the
      // top of the narrowed one.
      _shown = _pageSize;
      _rebuildRows();
    });
  }

  void _showMore() => setState(() => _shown += _pageSize);

  void _showAll() => setState(() => _shown = _rows.length);

  /// The rows actually built this frame.
  List<DepNode> get _page =>
      _rows.length <= _shown ? _rows : _rows.sublist(0, _shown);

  int get _remaining => _rows.length - _page.length;

  void _sortBy(int column, Comparable Function(DepNode) key) {
    setState(() {
      if (_sortColumn == column) {
        _ascending = !_ascending;
      } else {
        _sortColumn = column;
        _ascending = true;
      }
      _applySort(key: key);
    });
  }

  static const _allColumnLabels = [
    'Package',
    'Kind',
    'Installed',
    'Size',
    'Latest',
    'Status',
  ];

  /// The last two columns are the comparison against pub.dev, which an
  /// archived project does not make.
  ///
  /// Size sits before them rather than at the end so that it survives: what a
  /// package weighed is a fact about the snapshot, like its advisories and its
  /// license, not a comparison with what the registry is serving today.
  List<String> get _columnLabels => widget.showCurrency
      ? _allColumnLabels
      : _allColumnLabels.take(4).toList();

  Comparable Function(DepNode) _keyForColumn(int column) => switch (column) {
        1 => (n) => n.kind.name,
        2 => (n) => n.installed,
        // Unmeasured sorts below every measured package rather than beside the
        // small ones — "nobody looked" is not "weighs nothing".
        3 => (n) => n.size?.bytes ?? -1,
        4 => (n) => n.latest ?? '',
        5 => (n) => n.status.index,
        _ => (n) => n.name,
      };

  void _applySort({Comparable Function(DepNode)? key}) {
    final k = key ?? _keyForColumn(_sortColumn);
    _rows.sort((a, b) {
      final cmp = k(a).compareTo(k(b));
      return _ascending ? cmp : -cmp;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth < _compactBreakpoint
          ? _buildCompact(context)
          : _buildTable(context),
    );
  }

  // --- narrow ---------------------------------------------------------------

  Widget _buildCompact(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SearchField(controller: _searchController, onChanged: _search),
        const SizedBox(height: 8),
        // Sorting still has to be reachable without column headers to tap.
        Row(
          children: [
            Expanded(child: _CountLine(shown: _page.length, total: _rows.length)),
            TextButton.icon(
              onPressed: () => _pickSort(context),
              icon: Icon(
                _ascending ? Icons.arrow_upward : Icons.arrow_downward,
                size: 14,
              ),
              label: Text(_columnLabels[_sortColumn]),
            ),
          ],
        ),
        const Divider(height: 1),
        if (_rows.isEmpty)
          const _NoMatches()
        else
          for (final node in _page) ...[
            _CompactRow(
              node: node,
              onTap: widget.onSelect,
              showCurrency: widget.showCurrency,
            ),
            const Divider(height: 1),
          ],
        _MoreRows(
          remaining: _remaining,
          pageSize: _pageSize,
          onMore: _showMore,
          onAll: _showAll,
        ),
      ],
    );
  }

  Future<void> _pickSort(BuildContext context) async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < _columnLabels.length; i++)
              ListTile(
                title: Text(_columnLabels[i]),
                trailing: i == _sortColumn
                    ? Icon(_ascending ? Icons.arrow_upward : Icons.arrow_downward)
                    : null,
                onTap: () => Navigator.of(context).pop(i),
              ),
          ],
        ),
      ),
    );
    if (selected != null) _sortBy(selected, _keyForColumn(selected));
  }

  // --- wide -----------------------------------------------------------------

  Widget _buildTable(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _SearchField(
                controller: _searchController,
                onChanged: _search,
              ),
            ),
            const SizedBox(width: 14),
            _CountLine(shown: _page.length, total: _rows.length),
          ],
        ),
        const SizedBox(height: 6),
        if (_rows.isEmpty)
          const _NoMatches()
        else
          _table(context, theme),
        _MoreRows(
          remaining: _remaining,
          pageSize: _pageSize,
          onMore: _showMore,
          onAll: _showAll,
        ),
      ],
    );
  }

  Widget _table(BuildContext context, ThemeData theme) {
    final surfaces = Surfaces.of(context);

    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      child: SizedBox(
        width: double.infinity,
        child: DataTable(
          sortColumnIndex: _sortColumn,
          sortAscending: _ascending,
          columns: [
            for (final label in _columnLabels)
              DataColumn(
                label: Text(label),
                onSort: (c, _) => _sortBy(c, _keyForColumn(c)),
              ),
          ],
          rows: [
            for (final n in _page)
              DataRow(
                // Per-cell onTap rather than onSelectChanged: the latter turns
                // DataTable into a selectable one, adding a checkbox column and
                // a "select all" header. With onSelectAll unset, that header
                // invokes onSelectChanged for every row at once — which here
                // would try to open a sheet per dependency.
                cells: [
                  for (final cell in <Widget>[
                    Text(
                      n.name,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w500),
                    ),
                    Text(
                      n.kind.name,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: surfaces.muted),
                    ),
                    // Versions are machine-assigned, so they are set like it —
                    // and a monospaced column lets the eye compare `1.2.0`
                    // against `1.10.0` on the digit rather than on the width.
                    Text(n.installed,
                        style: monoOf(context, theme.textTheme.bodyMedium)),
                    _SizeCell(size: n.size),
                    if (widget.showCurrency) ...[
                      Text(
                        n.latest ?? '—',
                        style: monoOf(
                          context,
                          theme.textTheme.bodyMedium,
                          color: n.latest == null ? surfaces.muted : null,
                        ),
                      ),
                      DepStatusChip(status: n.status),
                    ],
                  ])
                    DataCell(
                      cell,
                      onTap: widget.onSelect == null
                          ? null
                          : () => widget.onSelect!(n),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// One package's weight, or a dash where nothing was measured.
///
/// The dash is doing real work: npm publishes `unpackedSize` only for versions
/// released since it began recording it, so a tree full of small old packages
/// is largely dashes, and printing `0 B` there would understate the tree in the
/// one direction this column exists to expose.
///
/// The scale is in the tooltip rather than in the cell. It is the same for
/// every row of a single-ecosystem report, which is nearly all of them, and
/// repeating `compressed` down a column costs more width than it returns.
class _SizeCell extends StatelessWidget {
  const _SizeCell({required this.size});

  final PackageSize? size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final measured = size;

    if (measured == null) {
      return Tooltip(
        message: 'The registry publishes no size for this version.',
        child: Text(
          '—',
          style: mono(theme.textTheme.bodyMedium, color: Surfaces.of(context).muted),
        ),
      );
    }

    final files = measured.fileCount;
    return Tooltip(
      message: [
        measured.basis.caveat,
        if (files != null) '$files files.',
      ].join(' '),
      child: Text(
        measured.display,
        style: mono(theme.textTheme.bodyMedium),
      ),
    );
  }
}

/// Narrows the table by package name.
///
/// Earns its room on a list this long: a reader who came to check one package
/// would otherwise be paging through fourteen hundred rows to reach it, and
/// sorting only moves the haystack.
class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: mono(theme.textTheme.bodySmall),
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Filter packages',
        hintStyle: theme.textTheme.bodySmall?.copyWith(color: Surfaces.of(context).muted),
        prefixIcon: const Icon(Icons.search, size: 18),
        prefixIconConstraints: const BoxConstraints(minWidth: 36),
        contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close, size: 16),
                tooltip: 'Clear filter',
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              ),
      ),
    );
  }
}

/// `100 of 1444 packages` — or just the total when they are the same.
class _CountLine extends StatelessWidget {
  const _CountLine({required this.shown, required this.total});

  final int shown;
  final int total;

  @override
  Widget build(BuildContext context) {
    final noun = total == 1 ? 'package' : 'packages';
    return Text(
      shown == total ? '$total $noun' : '$shown of $total $noun',
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}

class _NoMatches extends StatelessWidget {
  const _NoMatches();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 22),
      child: Text(
        'No package here matches that.',
        textAlign: TextAlign.center,
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: Surfaces.of(context).muted),
      ),
    );
  }
}

/// The footer that admits the list is longer than what is on screen.
///
/// Says how many are being held back rather than only offering a button: a
/// truncated list that does not say it is truncated is a list that has quietly
/// answered "is this package here?" with the wrong answer.
class _MoreRows extends StatelessWidget {
  const _MoreRows({
    required this.remaining,
    required this.pageSize,
    required this.onMore,
    required this.onAll,
  });

  final int remaining;
  final int pageSize;
  final VoidCallback onMore;
  final VoidCallback onAll;

  @override
  Widget build(BuildContext context) {
    if (remaining <= 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final next = remaining < pageSize ? remaining : pageSize;

    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 10,
        children: [
          Text(
            '$remaining more not shown',
            style: theme.textTheme.bodySmall?.copyWith(color: Surfaces.of(context).muted),
          ),
          TextButton(onPressed: onMore, child: Text('Show $next more')),
          TextButton(onPressed: onAll, child: const Text('Show all')),
        ],
      ),
    );
  }
}

/// One dependency as a stacked row: name and kind, the version beneath, and the
/// status on the right.
class _CompactRow extends StatelessWidget {
  const _CompactRow({
    required this.node,
    this.onTap,
    this.showCurrency = true,
  });

  final DepNode node;
  final void Function(DepNode node)? onTap;
  final bool showCurrency;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: onTap == null ? null : () => onTap!(node),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      Text(
                        node.name,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w500),
                      ),
                      DepKindBadge(kind: node.kind),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Flexible(
                        child: showCurrency
                            ? _VersionLine(node: node)
                            : Text(
                                node.installed,
                                style: theme.textTheme.bodySmall,
                              ),
                      ),
                      // Only where there is one. A dash per row would fill a
                      // narrow layout with the absence of a measurement, which
                      // is worth a column on a wide table and not worth a line
                      // here.
                      if (node.size case final size?) ...[
                        Text(
                          '  ·  ${size.display}',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: Surfaces.of(context).muted),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (showCurrency) ...[
              const SizedBox(width: 10),
              DepStatusChip(status: node.status),
            ],
          ],
        ),
      ),
    );
  }
}

/// The installed version, and where it would move to.
///
/// When something newer exists the current version is de-emphasised and the
/// target highlighted, so the row reads as "this is where you are, this is
/// where you would go" without needing two columns.
class _VersionLine extends StatelessWidget {
  const _VersionLine({required this.node});

  final DepNode node;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surfaces = Surfaces.of(context);
    final small = theme.textTheme.bodySmall;
    final latest = node.latest;
    final movesTo = latest != null && latest != node.installed;

    if (!movesTo) {
      return Text(node.installed, style: monoOf(context, small));
    }

    // The target takes the colour of the field that would move, so the row says
    // how big the step is before the reader opens anything.
    final risk = assessUpgrade(node).risk;
    final target = switch (risk) {
      UpgradeRisk.breaking => surfaces.major,
      UpgradeRisk.minor || UpgradeRisk.patch => surfaces.minor,
      _ => surfaces.muted,
    };

    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: node.installed,
            style: monoOf(context, small, color: surfaces.muted),
          ),
          TextSpan(
            text: '  →  ',
            style: monoOf(context, small, color: surfaces.muted),
          ),
          TextSpan(
            text: latest,
            style:
                monoOf(context, small, color: target, weight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
