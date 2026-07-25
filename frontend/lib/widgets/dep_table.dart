import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import 'dep_status_chip.dart';

/// A sortable table of a project's dependencies.
class DepTable extends StatefulWidget {
  const DepTable({super.key, required this.nodes});

  final List<DepNode> nodes;

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
    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      child: SizedBox(
        width: double.infinity,
        child: DataTable(
          sortColumnIndex: _sortColumn,
          sortAscending: _ascending,
          columns: [
            DataColumn(
              label: const Text('Package'),
              onSort: (c, _) => _sortBy(c, _keyForColumn(c)),
            ),
            DataColumn(
              label: const Text('Kind'),
              onSort: (c, _) => _sortBy(c, _keyForColumn(c)),
            ),
            DataColumn(
              label: const Text('Installed'),
              onSort: (c, _) => _sortBy(c, _keyForColumn(c)),
            ),
            DataColumn(
              label: const Text('Latest'),
              onSort: (c, _) => _sortBy(c, _keyForColumn(c)),
            ),
            DataColumn(
              label: const Text('Status'),
              onSort: (c, _) => _sortBy(c, _keyForColumn(c)),
            ),
          ],
          rows: [
            for (final n in _rows)
              DataRow(
                cells: [
                  DataCell(Text(n.name)),
                  DataCell(Text(n.kind.name)),
                  DataCell(Text(n.installed)),
                  DataCell(Text(n.latest ?? '—')),
                  DataCell(DepStatusChip(status: n.status)),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
