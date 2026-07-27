import 'package:shared/shared.dart';
import 'package:test/test.dart';

DepNode node({
  required String installed,
  String? latest,
  String? constraint,
  String name = 'demo',
}) =>
    DepNode(
      name: name,
      kind: DepKind.direct,
      installed: installed,
      latest: latest,
      constraint: constraint,
    );

void main() {
  group('risk level', () {
    test('a patch bump is a patch', () {
      final result = assessUpgrade(
        node(installed: '1.2.0', latest: '1.2.5', constraint: '^1.0.0'),
      );
      expect(result.risk, UpgradeRisk.patch);
    });

    test('a minor bump is additive', () {
      final result = assessUpgrade(
        node(installed: '1.2.0', latest: '1.5.0', constraint: '^1.0.0'),
      );
      expect(result.risk, UpgradeRisk.minor);
    });

    test('a major bump is breaking', () {
      final result = assessUpgrade(
        node(installed: '1.2.0', latest: '2.0.0', constraint: '^1.0.0'),
      );
      expect(result.risk, UpgradeRisk.breaking);
      expect(result.needsAttention, isTrue);
    });

    // Pub treats 0.x specially: the minor component carries breaking changes,
    // so ^0.13.0 allows 0.13.x only.
    test('a pre-1.0 minor bump is breaking, not minor', () {
      final result = assessUpgrade(
        node(installed: '0.13.0', latest: '0.14.0', constraint: '^0.13.0'),
      );
      expect(result.risk, UpgradeRisk.breaking);
      expect(result.summary, contains('pre-1.0'));
    });

    test('a pre-1.0 patch bump stays a patch', () {
      final result = assessUpgrade(
        node(installed: '0.13.0', latest: '0.13.4', constraint: '^0.13.0'),
      );
      expect(result.risk, UpgradeRisk.patch);
    });

    test('already latest reports nothing to do', () {
      final result = assessUpgrade(
        node(installed: '2.0.0', latest: '2.0.0', constraint: '^2.0.0'),
      );
      expect(result.risk, UpgradeRisk.none);
      expect(result.needsAttention, isFalse);
    });

    test('an installed version ahead of latest is not an upgrade', () {
      final result = assessUpgrade(
        node(installed: '3.0.0', latest: '2.0.0', constraint: 'any'),
      );
      expect(result.risk, UpgradeRisk.none);
    });
  });

  group('unknown versions', () {
    test('an unresolved version cannot be assessed', () {
      final result = assessUpgrade(
        node(installed: '(unresolved)', latest: '1.0.0'),
      );
      expect(result.risk, UpgradeRisk.unknown);
      expect(result.changelogUrl, isNull);
    });

    test('no latest version cannot be assessed', () {
      final result = assessUpgrade(node(installed: '1.0.0'));
      expect(result.risk, UpgradeRisk.unknown);
    });
  });

  group('constraint awareness', () {
    // The distinction that matters: can this happen on the next resolve, or
    // does a human have to edit pubspec.yaml?
    test('recognises a latest already allowed by the constraint', () {
      final result = assessUpgrade(
        node(installed: '1.2.0', latest: '1.9.0', constraint: '^1.0.0'),
      );
      expect(result.withinConstraint, isTrue);
      expect(result.summary, contains('constraint'));
    });

    test('recognises a latest the constraint excludes', () {
      final result = assessUpgrade(
        node(installed: '1.2.0', latest: '2.0.0', constraint: '^1.0.0'),
      );
      expect(result.withinConstraint, isFalse);
      expect(result.summary, contains('pubspec.yaml'));
    });

    test('a transitive package has no constraint of its own', () {
      final result = assessUpgrade(
        node(installed: '1.0.0', latest: '2.0.0'),
      );
      expect(result.withinConstraint, isFalse);
      expect(result.risk, UpgradeRisk.breaking);
    });

    test('an unparseable constraint is treated as not allowing', () {
      final result = assessUpgrade(
        node(installed: '1.0.0', latest: '1.1.0', constraint: 'git-thing'),
      );
      expect(result.withinConstraint, isFalse);
    });
  });

  group('changelog', () {
    test('points at the package changelog on pub.dev', () {
      final result = assessUpgrade(
        node(name: 'http', installed: '1.0.0', latest: '2.0.0'),
      );
      expect(result.changelogUrl, 'https://pub.dev/packages/http/changelog');
    });
  });
}
