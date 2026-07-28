import 'package:backend/src/services/cvss.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

/// Vectors with scores published by NVD/FIRST. If the arithmetic here drifts,
/// these say so — the whole point of a score is that it matches everyone
/// else's.
const _published = <String, double>{
  // The three advisories that currently apply to packages in this ecosystem.
  // http GHSA-4rgh-jx4f-qfcq — scope changed, the awkward branch of the formula.
  'CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:C/C:L/I:L/A:N': 6.1,
  // dio GHSA-9324-jv53-9cc8
  'CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:N/A:N': 7.5,
  // archive GHSA-9v85-q87q-g4vg
  'CVSS:3.1/AV:L/AC:L/PR:N/UI:R/S:U/C:H/I:H/A:H': 7.8,

  // The extremes of the scale.
  'CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:C/C:H/I:H/A:H': 10.0,
  'CVSS:3.1/AV:P/AC:H/PR:H/UI:R/S:U/C:N/I:N/A:N': 0.0,

  // Well-known real-world scores.
  'CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H': 9.8, // Log4Shell-shaped
  'CVSS:3.1/AV:N/AC:H/PR:N/UI:N/S:U/C:H/I:N/A:N': 5.9, // Heartbleed-shaped
  'CVSS:3.1/AV:L/AC:L/PR:L/UI:N/S:U/C:H/I:H/A:H':
      7.8, // local privilege escalation
  'CVSS:3.1/AV:N/AC:L/PR:L/UI:N/S:U/C:N/I:N/A:H': 6.5,
  'CVSS:3.0/AV:N/AC:L/PR:N/UI:R/S:C/C:L/I:L/A:N': 6.1, // 3.0 scores the same
};

void main() {
  group('base score', () {
    _published.forEach((vector, expected) {
      test('$vector is $expected', () {
        expect(CvssV3.parse(vector)!.baseScore, expected);
      });
    });

    // Scope-changed multiplies by 1.08 and can exceed 10 before clamping.
    test('never exceeds 10', () {
      final score =
          CvssV3.parse('CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:C/C:H/I:H/A:H')!
              .baseScore;
      expect(score, lessThanOrEqualTo(10.0));
    });

    test('scores nothing when there is no impact', () {
      final score =
          CvssV3.parse('CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:N')!
              .baseScore;
      expect(score, 0.0);
    });
  });

  group('parsing', () {
    test('rejects a vector from another CVSS version', () {
      expect(CvssV3.parse('AV:N/AC:L/Au:N/C:P/I:P/A:P'), isNull); // v2
      expect(
        CvssV3.parse('CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H'),
        isNull,
      );
    });

    test('rejects an incomplete vector', () {
      expect(CvssV3.parse('CVSS:3.1/AV:N/AC:L'), isNull);
      expect(CvssV3.parse('CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H'), isNull);
    });

    test('rejects unknown metric values', () {
      expect(
        CvssV3.parse('CVSS:3.1/AV:X/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H'),
        isNull,
      );
      expect(
        CvssV3.parse('CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:Q/C:H/I:H/A:H'),
        isNull,
      );
    });

    test('rejects junk without throwing', () {
      expect(CvssV3.parse(null), isNull);
      expect(CvssV3.parse(''), isNull);
      expect(CvssV3.parse('not a vector'), isNull);
      expect(CvssV3.parse('CVSS:3.1/AVN/AC:L'), isNull);
    });

    // Privileges Required is weighted differently when scope changes, so the
    // same PR value must not produce the same score across the two.
    test('weights privileges by scope', () {
      final unchanged =
          CvssV3.parse('CVSS:3.1/AV:N/AC:L/PR:L/UI:N/S:U/C:H/I:H/A:H')!;
      final changed =
          CvssV3.parse('CVSS:3.1/AV:N/AC:L/PR:L/UI:N/S:C/C:H/I:H/A:H')!;

      expect(unchanged.baseScore, 8.8);
      expect(changed.baseScore, 9.9);
    });
  });

  group('banding', () {
    test('maps scores onto the CVSS qualitative scale', () {
      expect(AdvisorySeverity.fromScore(0.0), AdvisorySeverity.none);
      expect(AdvisorySeverity.fromScore(0.1), AdvisorySeverity.low);
      expect(AdvisorySeverity.fromScore(3.9), AdvisorySeverity.low);
      expect(AdvisorySeverity.fromScore(4.0), AdvisorySeverity.medium);
      expect(AdvisorySeverity.fromScore(6.9), AdvisorySeverity.medium);
      expect(AdvisorySeverity.fromScore(7.0), AdvisorySeverity.high);
      expect(AdvisorySeverity.fromScore(8.9), AdvisorySeverity.high);
      expect(AdvisorySeverity.fromScore(9.0), AdvisorySeverity.critical);
      expect(AdvisorySeverity.fromScore(10.0), AdvisorySeverity.critical);
    });

    test('reads the database\'s own band, including GitHub\'s "moderate"', () {
      expect(AdvisorySeverity.fromName('CRITICAL'), AdvisorySeverity.critical);
      expect(AdvisorySeverity.fromName('High'), AdvisorySeverity.high);
      expect(AdvisorySeverity.fromName('MODERATE'), AdvisorySeverity.medium);
      expect(AdvisorySeverity.fromName('medium'), AdvisorySeverity.medium);
      expect(AdvisorySeverity.fromName('low'), AdvisorySeverity.low);
      expect(AdvisorySeverity.fromName('unheard-of'), isNull);
      expect(AdvisorySeverity.fromName(null), isNull);
    });

    // Sorting is by declaration order, and an unscored advisory must never
    // outrank a known critical one.
    test('orders worst first, with unknown last', () {
      expect(AdvisorySeverity.values.first, AdvisorySeverity.critical);
      expect(AdvisorySeverity.values.last, AdvisorySeverity.unknown);
      expect(
        AdvisorySeverity.values.indexOf(AdvisorySeverity.critical),
        lessThan(AdvisorySeverity.values.indexOf(AdvisorySeverity.low)),
      );
    });
  });
}
