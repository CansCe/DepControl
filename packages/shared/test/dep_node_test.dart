import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  group('advisory parsing', () {
    test('reads the full advisory object', () {
      final node = DepNode.fromJson({
        'name': 'http',
        'kind': 'direct',
        'installed': '0.13.0',
        'status': 'vulnerable',
        'advisories': [
          {
            'id': 'GHSA-4rgh-jx4f-qfcq',
            'aliases': ['CVE-2020-35669'],
            'summary': 'header injection',
            'fixedIn': '0.13.3',
          },
        ],
      });

      final advisory = node.advisories.single;
      expect(advisory.id, 'GHSA-4rgh-jx4f-qfcq');
      expect(advisory.aliases, ['CVE-2020-35669']);
      expect(advisory.summary, 'header injection');
      expect(advisory.fixedIn, '0.13.3');
    });

    // Reports stored before advisories carried any detail are bare id strings
    // in the `dep_reports` jsonb. Dropping them would turn a stored report's
    // vulnerable packages into clean ones — the worst way for this to fail.
    test('still reads reports stored as bare ids', () {
      final node = DepNode.fromJson({
        'name': 'http',
        'kind': 'direct',
        'installed': '0.13.0',
        'status': 'vulnerable',
        'advisories': ['GHSA-4rgh-jx4f-qfcq'],
      });

      expect(node.advisories.single.id, 'GHSA-4rgh-jx4f-qfcq');
      expect(node.advisories.single.fixedIn, isNull);
      expect(node.status, DepStatus.vulnerable);
    });

    test('an absent list is empty, not an error', () {
      final node = DepNode.fromJson({
        'name': 'http',
        'kind': 'direct',
        'installed': '1.0.0',
      });

      expect(node.advisories, isEmpty);
    });

    test('round-trips through json', () {
      const node = DepNode(
        name: 'http',
        kind: DepKind.direct,
        installed: '0.13.0',
        status: DepStatus.vulnerable,
        advisories: [
          DepAdvisory(
            id: 'GHSA-4rgh-jx4f-qfcq',
            aliases: ['CVE-2020-35669'],
            summary: 'header injection',
            fixedIn: '0.13.3',
          ),
        ],
      );

      final restored = DepNode.fromJson(node.toJson());
      expect(restored.advisories.single.id, 'GHSA-4rgh-jx4f-qfcq');
      expect(restored.advisories.single.fixedIn, '0.13.3');
      expect(restored.advisories.single.aliases, ['CVE-2020-35669']);
    });
  });

  test('an advisory links to where it can be read', () {
    const advisory = DepAdvisory(id: 'GHSA-4rgh-jx4f-qfcq');
    expect(advisory.url, 'https://osv.dev/vulnerability/GHSA-4rgh-jx4f-qfcq');
  });
}
