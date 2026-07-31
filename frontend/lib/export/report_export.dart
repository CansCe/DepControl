import 'dart:convert';

import 'package:shared/shared.dart';

/// A dependency report as a file somebody can open in something else.
///
/// Exists because a web page is where people expect to be able to take the
/// table away with them — into a spreadsheet for a meeting, into a diff against
/// last month's, into a ticket. The app build has no equivalent expectation and
/// no obvious place to put the file, so this is offered on the browser only.
///
/// Two formats rather than one, because they are read by different things. CSV
/// is for a person with a spreadsheet: one row per package, flattened, lossy on
/// purpose. JSON is the report as the API served it, which is what a script
/// wants and what round-trips.
class ReportExport {
  const ReportExport._();

  /// The report, flattened to one row per package.
  ///
  /// Lossy and deliberately so: a dependency's advisories and manifests are
  /// lists, and a spreadsheet cell is not. They are joined with spaces rather
  /// than commas so the CSV stays readable when a reader splits on commas
  /// despite the quoting.
  static String toCsv(DepReport report) {
    final graph = DependencyGraph.of(report);

    final rows = <List<String>>[
      const [
        'ecosystem',
        'package',
        'installed',
        'kind',
        'constraint',
        'latest',
        'status',
        'version_source',
        'license',
        'license_category',
        // Two columns, not one: the number is meaningless without the scale it
        // was measured on, and npm's installed bytes are not pub.dev's
        // compressed ones.
        'size_bytes',
        'size_basis',
        'file_count',
        'reclaimable_bytes',
        'imported',
        'advisories',
        'manifests',
      ],
    ];

    for (final node in report.nodes) {
      // Only meaningful for something the project declares — dropping a
      // transitive package is not an available move.
      final reclaimable = node.kind == DepKind.transitive
          ? ''
          : _reclaimableFor(graph, node);

      rows.add([
        node.ecosystem,
        node.name,
        node.installed,
        node.kind.name,
        node.constraint ?? '',
        node.latest ?? '',
        node.status.name,
        node.source.name,
        node.license?.spdxId ?? '',
        node.license?.category.name ?? '',
        node.size?.bytes.toString() ?? '',
        node.size?.basis.name ?? '',
        node.size?.fileCount?.toString() ?? '',
        reclaimable,
        // Three states, and the empty one is not "false": a report whose source
        // was never read has not measured this, and a spreadsheet showing
        // `false` there would claim a finding nobody made.
        switch (node.imported) { null => '', final v => v.toString() },
        [for (final a in node.advisories) a.id].join(' '),
        node.manifests.join(' '),
      ]);
    }

    return rows.map(_csvRow).join('\r\n');
  }

  /// What dropping this declared package would free, on its own scale.
  ///
  /// Blank where nothing was measured, rather than `0` — the same distinction
  /// the rest of the report keeps between "nothing" and "nobody looked".
  static String _reclaimableFor(DependencyGraph graph, DepNode node) {
    final tally = graph.reclaimableFrom([node.name]);
    if (tally.isEmpty) return '';
    // One basis per package, since a package belongs to one registry and so
    // does everything it exclusively pulls in.
    final basis = node.size?.basis ?? tally.bases.first;
    return tally.bytesOn(basis).toString();
  }

  /// The report as the API served it, indented so a diff of two of them reads.
  static String toJson(DepReport report) =>
      const JsonEncoder.withIndent('  ').convert(report.toJson());

  /// A filename that sorts by project and then by date.
  ///
  /// The date is the report's own `generatedAt`, not today: two exports of one
  /// unchanged report are the same file, and an export of an archived project
  /// is named for when it was captured rather than when it was downloaded.
  static String filename(
    Project project,
    DepReport report, {
    required String extension,
  }) {
    final when = report.generatedAt.toUtc().toIso8601String().split('T').first;
    return '${_slug(project.name)}-deps-$when.$extension';
  }

  /// Reduces a project name to something every filesystem accepts.
  static String _slug(String name) {
    final cleaned = name
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9]+'), '-')
        .replaceAll(RegExp('^-+|-+\$'), '');
    return cleaned.isEmpty ? 'project' : cleaned;
  }

  static String _csvRow(List<String> cells) => cells.map(_csvCell).join(',');

  /// RFC 4180 quoting.
  ///
  /// Not theoretical for this data: npm licenses are frequently SPDX
  /// *expressions* like `(MIT OR Apache-2.0)`, and a comma inside one would
  /// otherwise shift every column after it by one — silently, and only on the
  /// rows where a human most needs the license to be right.
  static String _csvCell(String value) {
    if (!value.contains(RegExp('[",\r\n]'))) return value;
    return '"${value.replaceAll('"', '""')}"';
  }
}
