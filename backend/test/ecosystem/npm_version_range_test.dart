import 'package:backend/src/ecosystem/npm/npm_version_range.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

void main() {
  /// Whether [range] admits [version] — the only question the resolver asks.
  ///
  /// Asserting on admitted versions rather than on the constructed
  /// [VersionConstraint] keeps the tests about npm's semantics rather than
  /// about how `pub_semver` chose to render an equivalent range.
  bool allows(String range, String version) {
    final parsed = parseNpmRange(range);
    if (parsed == null) {
      fail('"$range" did not parse');
    }
    return parsed.allows(Version.parse(version));
  }

  group('caret', () {
    test('at or above 1.0.0 it is a major bound', () {
      expect(allows('^1.2.3', '1.2.3'), isTrue);
      expect(allows('^1.2.3', '1.9.9'), isTrue);
      expect(allows('^1.2.3', '1.2.2'), isFalse);
      expect(allows('^1.2.3', '2.0.0'), isFalse);
    });

    test('below 1.0.0 it stops at the minor', () {
      expect(allows('^0.2.3', '0.2.9'), isTrue);
      expect(allows('^0.2.3', '0.3.0'), isFalse);
    });

    test('^0.0.3 admits nothing but 0.0.3', () {
      // The one npm range pub_semver reads differently. pub takes `^0.0.3` as
      // `>=0.0.3 <0.1.0` and so admits 0.0.4; npm does not, because the
      // leftmost non-zero component is the patch. Delegating to
      // VersionConstraint.parse here would let a resolution land on a release
      // the manifest excludes and then report it as installed.
      expect(allows('^0.0.3', '0.0.3'), isTrue);
      expect(allows('^0.0.3', '0.0.4'), isFalse);
      expect(VersionConstraint.parse('^0.0.3').allows(Version.parse('0.0.4')),
          isTrue);
    });

    test('partial carets take the unstated component as the bound', () {
      expect(allows('^1.2', '1.9.0'), isTrue);
      expect(allows('^1.2', '2.0.0'), isFalse);
      expect(allows('^0', '0.9.9'), isTrue);
      expect(allows('^0', '1.0.0'), isFalse);
      expect(allows('^0.0', '0.0.9'), isTrue);
      expect(allows('^0.0', '0.1.0'), isFalse);
    });
  });

  group('tilde', () {
    test('with a minor stated it is a patch bound', () {
      expect(allows('~1.2.3', '1.2.9'), isTrue);
      expect(allows('~1.2.3', '1.3.0'), isFalse);
      expect(allows('~1.2.3', '1.2.2'), isFalse);
    });

    test('without one it is a minor bound', () {
      expect(allows('~1', '1.9.9'), isTrue);
      expect(allows('~1', '2.0.0'), isFalse);
    });

    test('~1.2 stops at 1.3.0', () {
      expect(allows('~1.2', '1.2.9'), isTrue);
      expect(allows('~1.2', '1.3.0'), isFalse);
    });
  });

  group('wildcards and partials', () {
    test('1.2.x is the 1.2 line', () {
      expect(allows('1.2.x', '1.2.0'), isTrue);
      expect(allows('1.2.x', '1.2.9'), isTrue);
      expect(allows('1.2.x', '1.3.0'), isFalse);
    });

    test('1.x is the 1 line', () {
      expect(allows('1.x', '1.9.9'), isTrue);
      expect(allows('1.x', '2.0.0'), isFalse);
    });

    test('a bare partial is the same as a wildcard', () {
      expect(allows('1.2', '1.2.7'), isTrue);
      expect(allows('1.2', '1.3.0'), isFalse);
      expect(allows('1', '1.9.9'), isTrue);
      expect(allows('1', '2.0.0'), isFalse);
    });

    test('* and an empty range admit anything', () {
      expect(allows('*', '4.17.21'), isTrue);
      expect(allows('', '0.0.1'), isTrue);
      expect(allows('x', '9.9.9'), isTrue);
    });

    test('latest is a dist-tag, not a range, and is not refused', () {
      // It turns up in published manifests. Reporting a dependency nobody has
      // a problem with as unresolvable would be a worse answer than "any".
      expect(allows('latest', '1.0.0'), isTrue);
    });
  });

  group('comparators', () {
    test('inclusive and exclusive bounds', () {
      expect(allows('>=1.2.3', '1.2.3'), isTrue);
      expect(allows('>1.2.3', '1.2.3'), isFalse);
      expect(allows('<=1.2.3', '1.2.3'), isTrue);
      expect(allows('<1.2.3', '1.2.3'), isFalse);
    });

    test('a conjunction has to satisfy every part', () {
      expect(allows('>=1.0.0 <2.0.0', '1.5.0'), isTrue);
      expect(allows('>=1.0.0 <2.0.0', '2.0.0'), isFalse);
      expect(allows('>=1.0.0 <2.0.0', '0.9.0'), isFalse);
    });

    test('a partial bound clears the whole line for >', () {
      // `>1.2` has to get past all of 1.2, so 1.2.9 does not satisfy it.
      expect(allows('>1.2', '1.2.9'), isFalse);
      expect(allows('>1.2', '1.3.0'), isTrue);
      // `>=1.2` starts at the bottom of the line instead.
      expect(allows('>=1.2', '1.2.0'), isTrue);
    });

    test('v and = prefixes are noise', () {
      expect(allows('v1.2.3', '1.2.3'), isTrue);
      expect(allows('=1.2.3', '1.2.3'), isTrue);
      expect(allows('>=v1.0.0', '1.0.0'), isTrue);
    });

    test('an exact version admits only itself', () {
      expect(allows('1.2.3', '1.2.3'), isTrue);
      expect(allows('1.2.3', '1.2.4'), isFalse);
    });
  });

  group('unions', () {
    test('either side will do', () {
      expect(allows('^1.0.0 || ^2.0.0', '1.5.0'), isTrue);
      expect(allows('^1.0.0 || ^2.0.0', '2.5.0'), isTrue);
      expect(allows('^1.0.0 || ^2.0.0', '3.0.0'), isFalse);
    });

    test('an unreadable alternative makes the whole union unreadable', () {
      // Dropping it would narrow the constraint, and a narrower constraint
      // rejects versions the manifest allows.
      expect(parseNpmRange('^1.0.0 || not-a-range'), isNull);
    });
  });

  group('hyphen ranges', () {
    test('are inclusive at both ends when fully stated', () {
      expect(allows('1.2.3 - 2.3.4', '1.2.3'), isTrue);
      expect(allows('1.2.3 - 2.3.4', '2.3.4'), isTrue);
      expect(allows('1.2.3 - 2.3.4', '2.3.5'), isFalse);
      expect(allows('1.2.3 - 2.3.4', '1.2.2'), isFalse);
    });

    test('a partial upper bound covers its whole line', () {
      expect(allows('1.2.3 - 2.3', '2.3.9'), isTrue);
      expect(allows('1.2.3 - 2.3', '2.4.0'), isFalse);
    });

    test('a hyphen without spaces is a pre-release, not a range', () {
      expect(allows('1.2.3-beta.1', '1.2.3-beta.1'), isTrue);
    });
  });

  group('what it will not read', () {
    test('a git url is not a range', () {
      expect(parseNpmRange('git+https://github.com/acme/thing.git'), isNull);
    });

    test('a file path is not a range', () {
      expect(parseNpmRange('file:../local'), isNull);
    });

    test('nonsense is not a range', () {
      expect(parseNpmRange('not-a-version'), isNull);
      expect(parseNpmRange('1.2.3.4'), isNull);
    });
  });

  test('pre-release ordering survives translation', () {
    // The numbers alone cannot reconstruct a pre-release, and pre-releases
    // order below their release.
    expect(allows('>=1.2.3-beta.1', '1.2.3-beta.2'), isTrue);
    expect(allows('>=1.2.3-beta.1', '1.2.3'), isTrue);
    expect(allows('>=1.2.3-beta.2', '1.2.3-beta.1'), isFalse);
  });
}
