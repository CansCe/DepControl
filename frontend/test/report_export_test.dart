import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/export/report_export.dart';
import 'package:shared/shared.dart';

DepReport reportOf(List<DepNode> nodes) => DepReport(
      projectId: 'p1',
      generatedAt: DateTime.utc(2026, 3, 14, 9, 30),
      nodes: nodes,
    );

final project = Project(
  id: 'p1',
  gitUrl: 'https://github.com/acme/Widget Factory.git',
  name: 'Widget Factory',
  ownerId: 'u1',
);

/// The CSV split into rows and cells, for asserting on a column.
List<List<String>> parse(String csv) => [
      for (final line in const LineSplitter().convert(csv))
        _cells(line),
    ];

List<String> _cells(String line) {
  final out = <String>[];
  final buffer = StringBuffer();
  var quoted = false;

  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          buffer.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        buffer.write(c);
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == ',') {
      out.add(buffer.toString());
      buffer.clear();
    } else {
      buffer.write(c);
    }
  }
  out.add(buffer.toString());
  return out;
}

void main() {
  group('CSV', () {
    test('one header and one row per package', () {
      final csv = ReportExport.toCsv(reportOf(const [
        DepNode(name: 'http', kind: DepKind.direct, installed: '1.6.0'),
        DepNode(name: 'meta', kind: DepKind.transitive, installed: '1.16.0'),
      ]));

      final rows = parse(csv);
      expect(rows.first.first, 'ecosystem');
      expect(rows.length, 3);
      expect(rows[1][1], 'http');
      expect(rows[2][1], 'meta');
    });

    test('quotes a license expression rather than shifting every column', () {
      // Not theoretical: npm licenses are frequently SPDX expressions, and an
      // unquoted comma would move the columns after it by one — silently, and
      // only on the rows where a human most needs the license to be right.
      final csv = ReportExport.toCsv(reportOf(const [
        DepNode(
          name: 'lodash',
          kind: DepKind.direct,
          installed: '4.17.21',
          ecosystem: 'npm',
          license: PackageLicense(spdxId: '(MIT OR Apache-2.0), see LICENSE'),
        ),
      ]));

      final row = parse(csv)[1];
      expect(row[8], '(MIT OR Apache-2.0), see LICENSE');
      // Still the same number of columns as the header.
      expect(row.length, parse(csv).first.length);
    });

    test('escapes an embedded quote', () {
      final csv = ReportExport.toCsv(reportOf(const [
        DepNode(
          name: 'odd',
          kind: DepKind.direct,
          installed: '1.0.0',
          license: PackageLicense(spdxId: 'the "free" one'),
        ),
      ]));

      expect(csv, contains('"the ""free"" one"'));
      expect(parse(csv)[1][8], 'the "free" one');
    });

    test('carries the size and the scale it was measured on', () {
      final csv = ReportExport.toCsv(reportOf(const [
        DepNode(
          name: 'lodash',
          kind: DepKind.direct,
          installed: '4.17.21',
          ecosystem: 'npm',
          size: PackageSize(
            bytes: 1412415,
            basis: SizeBasis.unpacked,
            fileCount: 1054,
          ),
        ),
      ]));

      final row = parse(csv)[1];
      expect(row[10], '1412415');
      // The number is meaningless without this.
      expect(row[11], 'unpacked');
      expect(row[12], '1054');
    });

    test('an unmeasured package exports blank, not zero', () {
      final csv = ReportExport.toCsv(reportOf(const [
        DepNode(name: 'http', kind: DepKind.direct, installed: '1.6.0'),
      ]));

      final row = parse(csv)[1];
      expect(row[10], '');
      expect(row[11], '');
      expect(row[13], '');
    });

    test('reclaimable counts the tail, and only for declared packages', () {
      final csv = ReportExport.toCsv(reportOf(const [
        DepNode(
          name: 'build_runner',
          kind: DepKind.dev,
          installed: '2.0.0',
          dependencies: ['buried'],
          size: PackageSize(bytes: 40000, basis: SizeBasis.unpacked),
        ),
        DepNode(
          name: 'buried',
          kind: DepKind.transitive,
          installed: '1.0.0',
          size: PackageSize(bytes: 900000, basis: SizeBasis.unpacked),
        ),
      ]));

      final rows = parse(csv);
      // The 40 KB package costs the tree the best part of a megabyte.
      expect(rows[1][13], '940000');
      // Dropping a transitive package is not an available move, so the column
      // is blank rather than claiming a saving nobody can take.
      expect(rows[2][13], '');
    });

    test('an unscanned import exports blank, never false', () {
      // "Nobody looked" and "nothing uses it" are different claims, and a
      // spreadsheet showing `false` would make the first look like the second.
      final csv = ReportExport.toCsv(reportOf(const [
        DepNode(name: 'a', kind: DepKind.direct, installed: '1.0.0'),
        DepNode(
          name: 'b',
          kind: DepKind.direct,
          installed: '1.0.0',
          imported: false,
        ),
      ]));

      final rows = parse(csv);
      expect(rows[1][14], '');
      expect(rows[2][14], 'false');
    });

    test('lists advisories in one cell', () {
      final csv = ReportExport.toCsv(reportOf(const [
        DepNode(
          name: 'http',
          kind: DepKind.direct,
          installed: '1.0.0',
          advisories: [
            DepAdvisory(id: 'GHSA-aaaa'),
            DepAdvisory(id: 'GHSA-bbbb'),
          ],
        ),
      ]));

      expect(parse(csv)[1][15], 'GHSA-aaaa GHSA-bbbb');
    });

    test('an empty report is still a valid file with its header', () {
      final rows = parse(ReportExport.toCsv(reportOf(const [])));

      expect(rows.length, 1);
      expect(rows.first, contains('package'));
    });
  });

  group('JSON', () {
    test('round-trips through the report model', () {
      final report = reportOf(const [
        DepNode(
          name: 'http',
          kind: DepKind.direct,
          installed: '1.6.0',
          size: PackageSize(bytes: 46315, basis: SizeBasis.archive),
        ),
      ]);

      final read = DepReport.fromJson(
        jsonDecode(ReportExport.toJson(report)) as Map<String, dynamic>,
      );

      expect(read.nodes.single.name, 'http');
      expect(read.nodes.single.size?.bytes, 46315);
      expect(read.nodes.single.size?.basis, SizeBasis.archive);
    });
  });

  group('the filename', () {
    test('is safe for a filesystem and sorts by date', () {
      final name = ReportExport.filename(
        project,
        reportOf(const []),
        extension: 'csv',
      );

      expect(name, 'widget-factory-deps-2026-03-14.csv');
    });

    test('is named for when the report was captured, not for today', () {
      // Two exports of one unchanged report are the same file, and an archived
      // project's export is named for the snapshot rather than the download.
      final a = ReportExport.filename(project, reportOf(const []),
          extension: 'json');
      final b = ReportExport.filename(project, reportOf(const []),
          extension: 'json');

      expect(a, b);
    });

    test('a name with nothing usable in it still yields a file', () {
      final name = ReportExport.filename(
        Project(id: 'p', gitUrl: 'g', name: '???', ownerId: 'u'),
        reportOf(const []),
        extension: 'csv',
      );

      expect(name, 'project-deps-2026-03-14.csv');
    });
  });
}
