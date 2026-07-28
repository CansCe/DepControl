import 'package:shared/shared.dart';
import 'package:test/test.dart';

PackageLicense _license(
  String? spdxId,
  LicenseCategory category, {
  LicenseSource source = LicenseSource.installedVersion,
  String? readFromVersion,
}) =>
    PackageLicense(
      spdxId: spdxId,
      category: category,
      source: source,
      readFromVersion: readFromVersion,
    );

DepNode _node(
  String name, {
  required DepKind kind,
  PackageLicense? license,
  String installed = '1.0.0',
  List<String> dependencies = const [],
}) =>
    DepNode(
      name: name,
      kind: kind,
      installed: installed,
      license: license,
      dependencies: dependencies,
    );

DepReport _report(List<DepNode> nodes) => DepReport(
      projectId: 'p1',
      generatedAt: DateTime.utc(2026, 7, 28),
      nodes: nodes,
    );

void main() {
  group('what ships', () {
    // A GPL code generator and a GPL runtime library are entirely different
    // problems, and the graph is the only thing that can tell them apart.
    test('walks the graph out from the regular direct dependencies', () {
      final report = _report([
        _node('http', kind: DepKind.direct, dependencies: ['async']),
        _node('async', kind: DepKind.transitive),
        _node('test', kind: DepKind.dev, dependencies: ['coverage']),
        _node('coverage', kind: DepKind.transitive),
      ]);

      expect(report.devOnlyPackages, {'test', 'coverage'});
    });

    // The one that a "kind == dev" check gets wrong: a package a dev dependency
    // pulls in is marked transitive, not dev, and it still does not ship.
    test('reaches a transitive package that only a dev dependency pulls in',
        () {
      final report = _report([
        _node('build_runner', kind: DepKind.dev, dependencies: ['glob']),
        _node('glob', kind: DepKind.transitive),
      ]);

      expect(report.devOnlyPackages, contains('glob'));
    });

    test('does not exempt a package both a dev and a real dependency reach', () {
      final report = _report([
        _node('http', kind: DepKind.direct, dependencies: ['meta']),
        _node('test', kind: DepKind.dev, dependencies: ['meta']),
        _node('meta', kind: DepKind.transitive),
      ]);

      expect(report.devOnlyPackages, {'test'});
    });
  });

  group('findings', () {
    final report = _report([
      _node(
        'permissive_pkg',
        kind: DepKind.direct,
        license: _license('MIT', LicenseCategory.permissive),
      ),
      _node(
        'copyleft_pkg',
        kind: DepKind.direct,
        license: _license('AGPL-3.0-only', LicenseCategory.networkCopyleft),
      ),
      _node(
        'weak_pkg',
        kind: DepKind.direct,
        license: _license('MPL-2.0', LicenseCategory.weakCopyleft),
      ),
    ]);

    test('are ordered worst first', () {
      final licenses = LicenseReport.of(report, LicensePolicy.standard);

      expect(
        licenses.findings.map((f) => f.package),
        ['copyleft_pkg', 'weak_pkg', 'permissive_pkg'],
      );
      expect(licenses.counts.keys.first, LicenseRule.forbidden);
    });

    test('carry the reason the rule was reached', () {
      final licenses = LicenseReport.of(report, LicensePolicy.standard);
      final finding =
          licenses.findings.firstWhere((f) => f.package == 'copyleft_pkg');

      expect(finding.rule, LicenseRule.forbidden);
      expect(finding.reason, contains('network copyleft'));
    });

    test('include everything, not only the problems', () {
      final licenses = LicenseReport.of(report, LicensePolicy.standard);

      expect(licenses.findings, hasLength(3));
      expect(licenses.flagged.map((f) => f.package),
          ['copyleft_pkg', 'weak_pkg']);
      expect(licenses.forbidden.single.package, 'copyleft_pkg');
      expect(licenses.isClean, isFalse);
    });

    test('inventory the licenses in use, commonest first', () {
      final licenses = LicenseReport.of(
        _report([
          _node('a',
              kind: DepKind.direct,
              license: _license('MIT', LicenseCategory.permissive)),
          _node('b',
              kind: DepKind.direct,
              license: _license('MIT', LicenseCategory.permissive)),
          _node('c',
              kind: DepKind.direct,
              license: _license('ISC', LicenseCategory.permissive)),
        ]),
        LicensePolicy.standard,
      );

      expect(licenses.licenseCounts, {'MIT': 2, 'ISC': 1});
    });

    test('name the readings taken from another version', () {
      final licenses = LicenseReport.of(
        _report([
          _node(
            'old_pin',
            kind: DepKind.direct,
            installed: '0.1.0',
            license: _license(
              'MIT',
              LicenseCategory.permissive,
              source: LicenseSource.latestRelease,
              readFromVersion: '3.0.0',
            ),
          ),
        ]),
        LicensePolicy.standard,
      );

      expect(licenses.inferredFromOtherVersion.single.package, 'old_pin');
    });
  });

  // Judging a package nobody could check would be inventing a result. Two
  // different reasons land here, and each has a different next step.
  group('packages that could not be checked', () {
    final licenses = LicenseReport.of(
      _report([
        _node('scanned',
            kind: DepKind.direct,
            license: _license('MIT', LicenseCategory.permissive)),
        // A report generated before license scanning existed.
        _node('never_scanned', kind: DepKind.direct, installed: '2.4.0'),
        // Not a pub.dev package at all, so there is no analysis to be missing.
        _node(
          'flutter',
          kind: DepKind.direct,
          installed: '0.0.0',
          license: const PackageLicense.notFromPubDev('the SDK'),
        ),
      ]),
      LicensePolicy.standard,
    );

    test('are listed rather than judged', () {
      expect(
        licenses.unchecked.map((u) => u.package),
        ['flutter', 'never_scanned'],
      );
      expect(licenses.findings.map((f) => f.package), ['scanned']);
    });

    // An SDK dependency is not a finding a reviewer can act on, and putting it
    // in the review pile buries the ones they can.
    test('stay out of the counts and the flagged list', () {
      expect(licenses.flagged, isEmpty);
      expect(licenses.counts, {LicenseRule.allowed: 1});
    });

    test('each say why, since the next step differs', () {
      final byName = {for (final u in licenses.unchecked) u.package: u.reason};

      expect(byName['flutter'], contains('the SDK'));
      expect(byName['never_scanned'], contains('Re-analyze'));
    });

    test('stop the report calling itself clean', () {
      expect(licenses.isClean, isFalse);
    });
  });

  group('the CSV manifest', () {
    late String csv;

    setUp(() {
      csv = LicenseReport.of(
        _report([
          _node(
            'copyleft_pkg',
            kind: DepKind.direct,
            installed: '2.0.0',
            license: _license('GPL-3.0-only', LicenseCategory.strongCopyleft),
          ),
          // Its reason contains a comma, which is what forces the quoting.
          _node(
            'network_pkg',
            kind: DepKind.direct,
            installed: '1.1.0',
            license:
                _license('AGPL-3.0-only', LicenseCategory.networkCopyleft),
          ),
          _node(
            'permissive_pkg',
            kind: DepKind.direct,
            license: _license('MIT', LicenseCategory.permissive),
          ),
          _node('never_scanned', kind: DepKind.direct, installed: '2.4.0'),
        ]),
        LicensePolicy.standard,
      ).toCsv();
    });

    test('starts with a header and lists every dependency', () {
      final lines = csv.split('\r\n');
      expect(lines.first, startsWith('package,version,license,category,policy'));
      expect(lines, hasLength(5));
      expect(lines[1], startsWith('copyleft_pkg,2.0.0,GPL-3.0-only'));
    });

    // Reasons are prose, and some of them contain a comma. An unquoted one
    // shifts every later column in that row by one.
    test('quotes fields holding a separator', () {
      final row = csv
          .split('\r\n')
          .firstWhere((line) => line.startsWith('network_pkg'));

      expect(row, contains('"'));
      expect(row, contains('counts as distribution, so'));
      // The quoted field is one field: the row still has the header's column
      // count once quoted sections are set aside.
      expect(
        row.replaceAll(RegExp('"[^"]*"'), '').split(',').length,
        csv.split('\r\n').first.split(',').length,
      );
    });

    // A reviewer filtering the spreadsheet must not be able to hide the rows
    // nobody checked by filtering on "not forbidden".
    test('keeps the unchecked packages in the same table', () {
      expect(csv, contains('never_scanned,2.4.0,not checked'));
    });
  });

  test('round-trips through JSON', () {
    final original = LicenseReport.of(
      _report([
        _node('copyleft_pkg',
            kind: DepKind.direct,
            license:
                _license('GPL-3.0-only', LicenseCategory.strongCopyleft)),
        _node('never_scanned', kind: DepKind.transitive),
      ]),
      const LicensePolicy(licenses: {'MIT': LicenseRule.allowed}),
    );

    final restored = LicenseReport.fromJson(original.toJson());

    expect(restored.projectId, original.projectId);
    expect(restored.generatedAt, original.generatedAt);
    expect(
      restored.unchecked.map((u) => (u.package, u.version, u.reason)),
      original.unchecked.map((u) => (u.package, u.version, u.reason)),
    );
    expect(restored.policy.licenses, {'MIT': LicenseRule.allowed});

    final finding = restored.findings.single;
    expect(finding.package, 'copyleft_pkg');
    expect(finding.rule, LicenseRule.forbidden);
    expect(finding.license.spdxId, 'GPL-3.0-only');
    expect(finding.reason, isNotEmpty);
  });
}
