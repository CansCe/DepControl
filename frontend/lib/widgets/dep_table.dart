import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

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
  int _sortColumn = 0;
  bool _ascending = true;

  late List<DepNode> _rows = [...widget.nodes];

  @override
  void didUpdateWidget(covariant DepTable old) {
    super.didUpdateWidget(old);
    if (old.nodes != widget.nodes) {
      _rows = [...widget.nodes];
      _applySort();
    }
  }

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
    'Latest',
    'Status',
  ];

  /// The last two columns are the comparison against pub.dev, which an
  /// archived project does not make.
  List<String> get _columnLabels => widget.showCurrency
      ? _allColumnLabels
      : _allColumnLabels.take(3).toList();

  Comparable Function(DepNode) _keyForColumn(int column) => switch (column) {
        1 => (n) => n.kind.name,
        2 => (n) => n.installed,
        3 => (n) => n.latest ?? '',
        4 => (n) => n.status.index,
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
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Sorting still has to be reachable without column headers to tap.
        Row(
          children: [
            Expanded(
              child: Text(
                '${_rows.length} packages',
                style: theme.textTheme.bodySmall,
              ),
            ),
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
        for (final node in _rows) ...[
          _CompactRow(
            node: node,
            onTap: widget.onSelect,
            showCurrency: widget.showCurrency,
          ),
          const Divider(height: 1),
        ],
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
            for (final n in _rows)
              DataRow(
                // Per-cell onTap rather than onSelectChanged: the latter turns
                // DataTable into a selectable one, adding a checkbox column and
                // a "select all" header. With onSelectAll unset, that header
                // invokes onSelectChanged for every row at once — which here
                // would try to open a sheet per dependency.
                cells: [
                  for (final cell in <Widget>[
                    Text(n.name),
                    Text(n.kind.name),
                    Text(n.installed),
                    if (widget.showCurrency) ...[
                      Text(n.latest ?? '—'),
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
                  if (showCurrency)
                    _VersionLine(node: node)
                  else
                    Text(node.installed, style: theme.textTheme.bodySmall),
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
    final small = theme.textTheme.bodySmall;
    final latest = node.latest;
    final movesTo = latest != null && latest != node.installed;

    if (!movesTo) {
      return Text(
        node.installed,
        style: small?.copyWith(color: theme.textTheme.bodyMedium?.color),
      );
    }

    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: node.installed,
            style: small?.copyWith(color: Colors.grey.withValues(alpha: 0.9)),
          ),
          TextSpan(
            text: '  →  ',
            style: small?.copyWith(color: Colors.grey.withValues(alpha: 0.9)),
          ),
          TextSpan(
            text: latest,
            style: small?.copyWith(
              color: Colors.green.shade700,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
