import 'package:ecosystem/ecosystem.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

void main() {
  group('four-part versions', () {
    test('the revision becomes build metadata', () {
      final version = NuGetVersion.tryParse('5.2.7.4000');

      expect(version, isNotNull);
      expect(version!.major, 5);
      expect(version.minor, 2);
      expect(version.patch, 7);
      // pub_semver reads a numeric build identifier as a number, which is what
      // makes revision 999 sort below revision 1000 rather than above it.
      expect(version.build, [4000]);
      expect(version.toString(), '5.2.7+4000');
    });

    test('this is what stops a NuGet report being silently empty', () {
      // The whole reason this file exists: every consumer of `installed` parses
      // it with a tolerant tryParse that returns null rather than throwing, so
      // an unnormalised four-part version does not fail — it produces a node
      // that is never outdated and never matched by an advisory.
      expect(() => Version.parse('5.2.7.4000'), throwsFormatException);
      expect(Version.parse(NuGetVersion.normalise('5.2.7.4000')!), isNotNull);
    });

    test('a zero revision is dropped, as NuGet drops it', () {
      expect(NuGetVersion.normalise('4.5.0.0'), '4.5.0');
      expect(NuGetVersion.tryParse('4.5.0.0')!.build, isEmpty);
    });

    test('the revision still orders, because pub_semver orders build', () {
      // The semver specification says build metadata is ignored in comparison.
      // pub_semver deliberately does not, which is the whole reason the
      // revision can live there: a project on 5.2.7.4000 is reported as behind
      // 5.2.7.5000, and 5.2.7 is below both.
      final plain = NuGetVersion.tryParse('5.2.7')!;
      final older = NuGetVersion.tryParse('5.2.7.4000')!;
      final newer = NuGetVersion.tryParse('5.2.7.5000')!;

      expect(plain < older, isTrue);
      expect(older < newer, isTrue);
    });

    test('a range written without a revision still admits one', () {
      // The direction that matters for advisories: an OSV range of
      // >=5.2.0 <5.3.0 must not miss a package whose version has a revision.
      final affected = VersionRange(
        min: Version(5, 2, 0),
        max: Version(5, 3, 0),
        includeMin: true,
      );

      expect(affected.allows(NuGetVersion.tryParse('5.2.7.4000')!), isTrue);
    });
  });

  group('three-part and shorter', () {
    test('an ordinary semver version is untouched', () {
      expect(NuGetVersion.normalise('13.0.3'), '13.0.3');
    });

    test('a partial version fills in the components it omits', () {
      expect(NuGetVersion.normalise('1'), '1.0.0');
      expect(NuGetVersion.normalise('1.2'), '1.2.0');
    });
  });

  group('pre-releases', () {
    test('are preserved', () {
      final version = NuGetVersion.tryParse('1.0.0-beta.1');

      expect(version!.preRelease, ['beta', 1]);
      expect(version.isPreRelease, isTrue);
      expect(NuGetVersion.normalise('1.0.0-beta.1'), '1.0.0-beta.1');
    });

    test('order below the release they precede', () {
      expect(
        NuGetVersion.tryParse('1.0.0-beta.1')! < NuGetVersion.tryParse('1.0.0')!,
        isTrue,
      );
    });

    test('survive a fourth component beside them', () {
      expect(NuGetVersion.normalise('1.0.0.5-rc1'), '1.0.0-rc1+5');
    });
  });

  group('what it will not read', () {
    test('five components is not a version', () {
      expect(NuGetVersion.tryParse('1.2.3.4.5'), isNull);
    });

    test('nor is a wildcard, a range, or nothing at all', () {
      expect(NuGetVersion.tryParse('1.*'), isNull);
      expect(NuGetVersion.tryParse('[1.0,2.0)'), isNull);
      expect(NuGetVersion.tryParse(''), isNull);
      expect(NuGetVersion.tryParse('   '), isNull);
    });

    test('nor a signed component, which int.tryParse would accept', () {
      expect(NuGetVersion.tryParse('1.-2.3'), isNull);
      expect(NuGetVersion.tryParse('1.+2.3'), isNull);
    });
  });

  group('writing a version back', () {
    test('a fourth component goes back where it came from', () {
      expect(NuGetVersion.format(NuGetVersion.tryParse('5.2.7.4000')!),
          '5.2.7.4000');
    });

    test('an ordinary version is written ordinarily', () {
      expect(NuGetVersion.format(Version.parse('13.0.3')), '13.0.3');
    });

    test('"at least" is the bracket form, which means it everywhere', () {
      expect(NuGetVersion.atLeast(Version.parse('1.2.3')), '[1.2.3,)');
      expect(
        NuGetVersion.atLeast(NuGetVersion.tryParse('5.2.7.4000')!),
        '[5.2.7.4000,)',
      );
    });
  });
}
