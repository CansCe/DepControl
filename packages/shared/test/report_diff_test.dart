import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  DepNode node(
    String name, {
    String version = '1.0.0',
    String ecosystem = 'dart',
    DepKind kind = DepKind.direct,
    List<DepAdvisory> advisories = const [],
    String? license,
  }) =>
      DepNode(
        name: name,
        ecosystem: ecosystem,
        kind: kind,
        installed: version,
        advisories: advisories,
        license: license == null
            ? null
            : PackageLicense(
                spdxId: license,
                category: LicenseCategory.permissive,
                source: LicenseSource.installedVersion,
              ),
      );

  DepReport report(List<DepNode> nodes, {DateTime? at}) => DepReport(
        projectId: 'p1',
        generatedAt: at ?? DateTime.utc(2026, 1, 1),
        nodes: nodes,
      );

  ReportDiff diff(List<DepNode> before, List<DepNode> after) =>
      ReportDiff.between(
        report(before, at: DateTime.utc(2026, 1, 1)),
        report(after, at: DateTime.utc(2026, 2, 1)),
      );

  const critical = DepAdvisory(
    id: 'GHSA-critical',
    severity: AdvisorySeverity.critical,
  );
  const low = DepAdvisory(id: 'GHSA-low', severity: AdvisorySeverity.low);

  group('what moved', () {
    test('an unchanged report has no changes', () {
      final d = diff([node('http')], [node('http')]);
      expect(d.isEmpty, isTrue);
      expect(d.packages, isEmpty);
    });

    test('a package added', () {
      final d = diff([node('http')], [node('http'), node('yaml')]);

      final change = d.added.single;
      expect(change.name, 'yaml');
      expect(change.fromVersion, isNull);
      expect(change.toVersion, '1.0.0');
    });

    test('a package removed', () {
      final d = diff([node('http'), node('yaml')], [node('http')]);

      final change = d.removed.single;
      expect(change.name, 'yaml');
      expect(change.fromVersion, '1.0.0');
      expect(change.toVersion, isNull);
    });

    test('a version move records both ends', () {
      final d = diff(
        [node('http', version: '1.0.0')],
        [node('http', version: '1.1.0')],
      );

      final change = d.moved.single;
      expect(change.kind, ChangeKind.changed);
      expect(change.fromVersion, '1.0.0');
      expect(change.toVersion, '1.1.0');
      expect(change.isDowngrade, isFalse);
    });

    test('the diff carries both reports\' timestamps', () {
      final d = diff([node('http')], [node('http', version: '2.0.0')]);
      expect(d.fromGeneratedAt, DateTime.utc(2026, 1, 1));
      expect(d.toGeneratedAt, DateTime.utc(2026, 2, 1));
    });
  });

  group('how far it moved', () {
    VersionBump bumpOf(String from, String to, {String ecosystem = 'dart'}) =>
        diff(
          [node('x', version: from, ecosystem: ecosystem)],
          [node('x', version: to, ecosystem: ecosystem)],
        ).moved.single.bump;

    test('major, minor and patch above 1.0.0', () {
      expect(bumpOf('1.0.0', '2.0.0'), VersionBump.breaking);
      expect(bumpOf('1.0.0', '1.1.0'), VersionBump.minor);
      expect(bumpOf('1.0.0', '1.0.1'), VersionBump.patch);
    });

    test('below 1.0.0 a minor change is breaking in both ecosystems', () {
      expect(bumpOf('0.13.0', '0.14.0'), VersionBump.breaking);
      expect(bumpOf('0.13.0', '0.14.0', ecosystem: 'npm'), VersionBump.breaking);
    });

    test('at 0.0.x npm treats the patch as breaking and pub does not', () {
      // Not a quibble: it is why `^0.0.3` admits nothing but 0.0.3 on npm and
      // `>=0.0.3 <0.1.0` on pub. Calling an npm 0.0.3 -> 0.0.4 a bug-fix bump
      // would tell somebody a breaking change was routine.
      expect(bumpOf('0.0.3', '0.0.4'), VersionBump.patch);
      expect(bumpOf('0.0.3', '0.0.4', ecosystem: 'npm'), VersionBump.breaking);
    });

    test('a downgrade is flagged and keeps its magnitude', () {
      final change = diff(
        [node('x', version: '2.0.0')],
        [node('x', version: '1.0.0')],
      ).moved.single;

      expect(change.isDowngrade, isTrue);
      // A downgrade across a major boundary is as breaking as the upgrade was.
      expect(change.bump, VersionBump.breaking);
    });

    test('a version that cannot be read is incomparable, not patch', () {
      // `(unresolved)` is the sentinel for a project with no lockfile.
      expect(bumpOf('(unresolved)', '1.0.0'), VersionBump.incomparable);
      expect(bumpOf('1.0.0', '(unresolved)'), VersionBump.incomparable);
    });

    test('breakingMoves is what a major-bump notification asks for', () {
      final d = diff(
        [node('a', version: '1.0.0'), node('b', version: '1.0.0')],
        [node('a', version: '2.0.0'), node('b', version: '1.1.0')],
      );

      expect(d.breakingMoves.map((p) => p.name), ['a']);
    });
  });

  group('advisories', () {
    test('one newly published against an unchanged version', () {
      // The event a scheduled re-scan of an untouched project exists to catch.
      final d = diff(
        [node('http')],
        [node('http', advisories: [critical])],
      );

      final change = d.newlyVulnerable.single;
      expect(change.newAdvisories.single.id, 'GHSA-critical');
      expect(change.versionMoved, isFalse);
      expect(d.hasNewVulnerabilities, isTrue);
    });

    test('a package arriving vulnerable is a new vulnerability', () {
      final d = diff(
        [node('http')],
        [node('http'), node('evil', advisories: [critical])],
      );

      expect(d.newlyVulnerable.single.name, 'evil');
      expect(d.newlyVulnerable.single.kind, ChangeKind.added);
    });

    test('an advisory that stops applying is cleared, not "fixed"', () {
      // It can clear because the package moved to a fixed version, because it
      // left the project, or because the advisory was withdrawn — and a
      // withdrawal means nobody repaired anything.
      final d = diff(
        [node('http', version: '1.0.0', advisories: [critical])],
        [node('http', version: '1.0.1')],
      );

      final change = d.packages.single;
      expect(change.clearedAdvisories.single.id, 'GHSA-critical');
      expect(change.newAdvisories, isEmpty);
      expect(d.hasNewVulnerabilities, isFalse);
    });

    test('a removed package clears whatever it carried', () {
      final d = diff([node('http', advisories: [critical])], []);
      expect(d.removed.single.clearedAdvisories.single.id, 'GHSA-critical');
    });

    test('an advisory present on both sides is neither new nor cleared', () {
      final d = diff(
        [node('http', version: '1.0.0', advisories: [critical])],
        [node('http', version: '1.0.1', advisories: [critical])],
      );

      final change = d.packages.single;
      expect(change.newAdvisories, isEmpty);
      expect(change.clearedAdvisories, isEmpty);
      // It still moved, so it is still a change.
      expect(change.versionMoved, isTrue);
    });

    test('the worst new severity is what a threshold compares against', () {
      final d = diff(
        [node('a'), node('b')],
        [
          node('a', advisories: [low]),
          node('b', advisories: [critical]),
        ],
      );

      expect(d.worstNewSeverity, AdvisorySeverity.critical);
    });

    test('no new advisories means no severity, rather than a low one', () {
      final d = diff([node('a')], [node('a', version: '1.0.1')]);
      expect(d.worstNewSeverity, isNull);
    });

    test('newAdvisories pairs each one with its package', () {
      final d = diff(
        [node('a')],
        [
          node('a', advisories: [critical, low]),
        ],
      );

      expect(d.newAdvisories, hasLength(2));
      expect(d.newAdvisories.first.package.name, 'a');
      expect(
        d.newAdvisories.map((e) => e.advisory.id),
        containsAll(['GHSA-critical', 'GHSA-low']),
      );
    });
  });

  group('licenses', () {
    test('a relicensing on an unchanged version is reported', () {
      final d = diff(
        [node('http', license: 'MIT')],
        [node('http', license: 'AGPL-3.0')],
      );

      final change = d.relicensed.single;
      expect(change.fromLicense, 'MIT');
      expect(change.toLicense, 'AGPL-3.0');
    });

    test('a license change alongside a version move is not a relicensing', () {
      // The package became a different published artefact; that it also has a
      // different licence is part of the move rather than a separate event.
      final d = diff(
        [node('http', version: '1.0.0', license: 'MIT')],
        [node('http', version: '2.0.0', license: 'AGPL-3.0')],
      );

      expect(d.relicensed, isEmpty);
      expect(d.moved.single.toLicense, 'AGPL-3.0');
    });
  });

  group('ecosystems', () {
    test('the same name in two ecosystems is two packages', () {
      // Both registries publish `http`, by different people.
      final d = diff(
        [node('http', ecosystem: 'dart', version: '1.0.0')],
        [
          node('http', ecosystem: 'dart', version: '1.0.0'),
          node('http', ecosystem: 'npm', version: '0.0.1'),
        ],
      );

      expect(d.added.single.ecosystem, 'npm');
      expect(d.moved, isEmpty);
    });

    test('a package is not matched across ecosystems', () {
      final d = diff(
        [node('http', ecosystem: 'dart', version: '1.0.0')],
        [node('http', ecosystem: 'npm', version: '2.0.0')],
      );

      expect(d.added.single.ecosystem, 'npm');
      expect(d.removed.single.ecosystem, 'dart');
      expect(d.moved, isEmpty);
    });
  });

  group('a package resolved at two versions at once', () {
    test('differing versions are listed rather than paired into a move', () {
      // This repository's own case: the root lockfile has analyzer 12.1.0 and
      // tools/api_differ has 7.7.1. There is no single "it moved" to report.
      final d = diff(
        [node('analyzer', version: '7.7.1'), node('analyzer', version: '12.1.0')],
        [node('analyzer', version: '7.7.1'), node('analyzer', version: '13.0.0')],
      );

      expect(d.moved, isEmpty);
      expect(d.added.single.toVersion, '13.0.0');
      expect(d.removed.single.fromVersion, '12.1.0');
    });

    test('collapsing to one version reads as an addition and a removal', () {
      final d = diff(
        [node('analyzer', version: '7.7.1'), node('analyzer', version: '12.1.0')],
        [node('analyzer', version: '12.1.0')],
      );

      expect(d.removed.single.fromVersion, '7.7.1');
      expect(d.added, isEmpty);
    });
  });

  group('how it is reached', () {
    test('a direct dependency becoming transitive is a change', () {
      final d = diff(
        [node('meta', kind: DepKind.direct)],
        [node('meta', kind: DepKind.transitive)],
      );

      final change = d.packages.single;
      expect(change.kindMoved, isTrue);
      expect(change.fromKind, DepKind.direct);
      expect(change.toKind, DepKind.transitive);
    });
  });

  group('ordering', () {
    test('new advisories lead, worst band first, then breaking moves', () {
      final d = diff(
        [
          node('zebra', version: '1.0.0'),
          node('alpha', version: '1.0.0'),
          node('beta', version: '1.0.0'),
          node('gamma', version: '1.0.0'),
        ],
        [
          node('zebra', version: '1.0.0', advisories: [low]),
          node('alpha', version: '1.0.1'),
          node('beta', version: '1.0.0', advisories: [critical]),
          node('gamma', version: '2.0.0'),
        ],
      );

      expect(
        d.packages.map((p) => p.name),
        // critical, then low, then the breaking move, then the patch.
        ['beta', 'zebra', 'gamma', 'alpha'],
      );
    });
  });

  group('serialisation', () {
    test('round-trips everything a change carries', () {
      final d = diff(
        [node('http', version: '1.0.0', license: 'MIT', kind: DepKind.direct)],
        [
          node(
            'http',
            version: '2.0.0',
            license: 'AGPL-3.0',
            kind: DepKind.transitive,
            advisories: [critical],
          ),
        ],
      );

      final restored = ReportDiff.fromJson(d.toJson());
      final change = restored.packages.single;

      expect(restored.projectId, 'p1');
      expect(restored.fromGeneratedAt, DateTime.utc(2026, 1, 1));
      expect(restored.toGeneratedAt, DateTime.utc(2026, 2, 1));
      expect(change.name, 'http');
      expect(change.kind, ChangeKind.changed);
      expect(change.fromVersion, '1.0.0');
      expect(change.toVersion, '2.0.0');
      expect(change.bump, VersionBump.breaking);
      expect(change.newAdvisories.single.id, 'GHSA-critical');
      expect(change.fromLicense, 'MIT');
      expect(change.toLicense, 'AGPL-3.0');
      expect(change.fromKind, DepKind.direct);
      expect(change.toKind, DepKind.transitive);
    });

    test('a downgrade survives the round trip', () {
      final d = diff(
        [node('x', version: '2.0.0')],
        [node('x', version: '1.0.0')],
      );

      expect(ReportDiff.fromJson(d.toJson()).moved.single.isDowngrade, isTrue);
    });

    test('the ecosystem is omitted when it is the default and kept when not',
        () {
      final dart = diff([], [node('http')]).packages.single.toJson();
      expect(dart.containsKey('ecosystem'), isFalse);

      final npm =
          diff([], [node('http', ecosystem: 'npm')]).packages.single.toJson();
      expect(npm['ecosystem'], 'npm');
    });

    test('the summary is what a notification rule reads', () {
      final d = diff(
        [node('a', version: '1.0.0'), node('b')],
        [
          node('a', version: '2.0.0'),
          node('b', advisories: [critical]),
          node('c'),
        ],
      );

      final summary = d.toJson()['summary'] as Map<String, dynamic>;
      expect(summary['added'], 1);
      expect(summary['breaking'], 1);
      expect(summary['newlyVulnerable'], 1);
      expect(summary['worstNewSeverity'], 'critical');
    });
  });

  test('an empty report on either side still diffs', () {
    expect(diff([], [node('http')]).added, hasLength(1));
    expect(diff([node('http')], []).removed, hasLength(1));
    expect(diff([], []).isEmpty, isTrue);
  });
}
