import 'package:ecosystem/ecosystem.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

void main() {
  VersionConstraint? range(String text) => parseNuGetRange(text);
  bool allows(String text, String version) =>
      range(text)!.allows(NuGetVersion.tryParse(version)!);

  group('a bare version', () {
    test('is a minimum, not a pin', () {
      // The trap. Every other ecosystem here reads `1.0` as "exactly 1.0", and
      // NuGet reads it as "1.0 or anything above". Read as a pin, the report
      // would reject the version actually installed.
      expect(allows('1.0', '1.0.0'), isTrue);
      expect(allows('1.0', '2.5.0'), isTrue);
      expect(allows('1.0', '0.9.0'), isFalse);
    });

    test('with four components too', () {
      expect(allows('5.2.7.4000', '5.2.7.4000'), isTrue);
      expect(allows('5.2.7.4000', '5.3.0'), isTrue);
      expect(allows('5.2.7.4000', '5.2.6'), isFalse);
      // And the revision is a real lower bound, not decoration: 5.2.7 without
      // one is below 5.2.7.4000, exactly as NuGet orders them.
      expect(allows('5.2.7.4000', '5.2.7'), isFalse);
    });
  });

  group('brackets', () {
    test('[1.0] is the only exact form', () {
      expect(allows('[1.0]', '1.0.0'), isTrue);
      expect(allows('[1.0]', '1.0.1'), isFalse);
      expect(allows('[1.0]', '0.9.9'), isFalse);
    });

    test('[1.0,2.0) is inclusive below and exclusive above', () {
      expect(allows('[1.0,2.0)', '1.0.0'), isTrue);
      expect(allows('[1.0,2.0)', '1.9.9'), isTrue);
      expect(allows('[1.0,2.0)', '2.0.0'), isFalse);
      expect(allows('[1.0,2.0)', '0.9.9'), isFalse);
    });

    test('(1.0,2.0] is the mirror of it', () {
      expect(allows('(1.0,2.0]', '1.0.0'), isFalse);
      expect(allows('(1.0,2.0]', '1.0.1'), isTrue);
      expect(allows('(1.0,2.0]', '2.0.0'), isTrue);
      expect(allows('(1.0,2.0]', '2.0.1'), isFalse);
    });

    test('an open upper end has no upper end', () {
      expect(allows('[1.0,)', '1.0.0'), isTrue);
      expect(allows('[1.0,)', '99.0.0'), isTrue);
      expect(allows('[1.0,)', '0.9.0'), isFalse);
      expect(allows('(1.0,)', '1.0.0'), isFalse);
    });

    test('an open lower end has no lower end', () {
      expect(allows('(,2.0]', '0.0.1'), isTrue);
      expect(allows('(,2.0]', '2.0.0'), isTrue);
      expect(allows('(,2.0]', '2.0.1'), isFalse);
      expect(allows('(,2.0)', '2.0.0'), isFalse);
    });

    test('whitespace inside the brackets is noise', () {
      expect(allows('[1.0, 2.0)', '1.5.0'), isTrue);
    });
  });

  group('floating versions', () {
    test('* is anything', () {
      expect(range('*'), VersionConstraint.any);
    });

    test('1.* clears the major line', () {
      expect(allows('1.*', '1.0.0'), isTrue);
      expect(allows('1.*', '1.9.9'), isTrue);
      expect(allows('1.*', '2.0.0'), isFalse);
    });

    test('1.2.* clears the minor line', () {
      expect(allows('1.2.*', '1.2.0'), isTrue);
      expect(allows('1.2.*', '1.2.99'), isTrue);
      expect(allows('1.2.*', '1.3.0'), isFalse);
    });
  });

  group('what it will not read', () {
    test('(,) states nothing, and NuGet rejects it too', () {
      expect(range('(,)'), isNull);
    });

    test('(1.0) is not a range', () {
      expect(range('(1.0)'), isNull);
    });

    test('an unclosed bracket', () {
      expect(range('[1.0,2.0'), isNull);
      expect(range('1.0,2.0)'), isNull);
    });

    test('a floating pre-release selects, it does not bound', () {
      expect(range('1.0.0-*'), isNull);
    });

    test('nonsense, and nothing at all', () {
      expect(range('lots'), isNull);
      expect(range('[a,b)'), isNull);
      expect(range('  '), isNull);
      expect(range('[1.0,2.0,3.0)'), isNull);
    });
  });

  test('a four-part bound is normalised on the way in', () {
    expect(allows('[5.2.7.4000,6.0)', '5.2.7.4000'), isTrue);
    expect(allows('[5.2.7.4000,6.0)', '5.9.0'), isTrue);
    expect(allows('[5.2.7.4000,6.0)', '6.0.0'), isFalse);
  });
}
