import 'package:shared/shared.dart';
import 'package:test/test.dart';

PackageLicense _license(String spdxId, LicenseCategory category) =>
    PackageLicense(
      spdxId: spdxId,
      category: category,
      source: LicenseSource.installedVersion,
    );

void main() {
  group('the standard policy', () {
    const policy = LicensePolicy.standard;

    test('clears permissive licenses', () {
      final decision =
          policy.decide(_license('MIT', LicenseCategory.permissive));
      expect(decision.rule, LicenseRule.allowed);
    });

    test('sends weak copyleft to a human rather than banning it', () {
      final decision =
          policy.decide(_license('MPL-2.0', LicenseCategory.weakCopyleft));
      expect(decision.rule, LicenseRule.review);
      expect(decision.reason, contains('weak copyleft'));
    });

    test('forbids the copyleft families that can reach your own source', () {
      expect(
        policy
            .decide(_license('GPL-3.0-only', LicenseCategory.strongCopyleft))
            .rule,
        LicenseRule.forbidden,
      );
      expect(
        policy
            .decide(
              _license('AGPL-3.0-or-later', LicenseCategory.networkCopyleft),
            )
            .rule,
        LicenseRule.forbidden,
      );
      expect(
        policy
            .decide(_license('BUSL-1.1', LicenseCategory.proprietary))
            .rule,
        LicenseRule.forbidden,
      );
    });

    // A package with no identifiable grant is not licensed to you. Reading that
    // as "fine" is the failure this whole feature exists to prevent.
    test('does not clear a package whose license could not be identified', () {
      const unidentified = PackageLicense(
        category: LicenseCategory.unknown,
        source: LicenseSource.installedVersion,
      );

      final decision = policy.decide(unidentified);
      expect(decision.rule, LicenseRule.review);
      expect(decision.reason, contains('could not identify'));
    });

    test('does not clear a package that was never scanned', () {
      expect(policy.decide(null).rule, LicenseRule.review);
    });

    // pub.dev naming a license this build has no category for is a different
    // problem from pub.dev naming none, and has a different fix.
    test('says which kind of unknown it is looking at', () {
      final decision = policy.decide(
        _license('ZPL-2.1', LicenseCategory.unknown),
      );
      expect(decision.rule, LicenseRule.review);
      expect(decision.reason, contains('ZPL-2.1'));
      expect(decision.reason, contains('Name it in your policy'));
    });
  });

  group('named licenses', () {
    test('override the family they belong to', () {
      const policy = LicensePolicy(licenses: {'GPL-3.0-only': LicenseRule.allowed});

      final decision =
          policy.decide(_license('GPL-3.0-only', LicenseCategory.strongCopyleft));
      expect(decision.rule, LicenseRule.allowed);
      expect(decision.reason, contains('names GPL-3.0-only explicitly'));
    });

    test('can ban one license out of an otherwise allowed family', () {
      const policy = LicensePolicy(licenses: {'WTFPL': LicenseRule.forbidden});

      expect(
        policy.decide(_license('WTFPL', LicenseCategory.permissive)).rule,
        LicenseRule.forbidden,
      );
      expect(
        policy.decide(_license('MIT', LicenseCategory.permissive)).rule,
        LicenseRule.allowed,
      );
    });

    // Nobody types SPDX identifiers with their conventional casing.
    test('are matched case-insensitively', () {
      const policy = LicensePolicy(licenses: {'agpl-3.0-or-later': LicenseRule.allowed});

      expect(
        policy
            .decide(
              _license('AGPL-3.0-or-later', LicenseCategory.networkCopyleft),
            )
            .rule,
        LicenseRule.allowed,
      );
    });
  });

  group('dev dependencies', () {
    final gpl = _license('GPL-3.0-only', LicenseCategory.strongCopyleft);

    test('are not checked by default', () {
      final decision = LicensePolicy.standard.decide(gpl, devOnly: true);
      expect(decision.rule, LicenseRule.allowed);
      expect(decision.reason, contains('Nothing you ship'));
    });

    test('are checked when the policy asks for it', () {
      const policy = LicensePolicy(
        categories: {LicenseCategory.strongCopyleft: LicenseRule.forbidden},
        checkDevDependencies: true,
      );
      expect(policy.decide(gpl, devOnly: true).rule, LicenseRule.forbidden);
    });

    test('exempt nothing that actually ships', () {
      expect(
        LicensePolicy.standard.decide(gpl, devOnly: false).rule,
        LicenseRule.forbidden,
      );
    });
  });

  group('serialization', () {
    test('round-trips', () {
      const policy = LicensePolicy(
        categories: {
          LicenseCategory.permissive: LicenseRule.allowed,
          LicenseCategory.weakCopyleft: LicenseRule.forbidden,
        },
        licenses: {'SSPL-1.0': LicenseRule.allowed},
        checkDevDependencies: true,
      );

      final restored = LicensePolicy.fromJson(policy.toJson());

      expect(restored.categories, policy.categories);
      expect(restored.licenses, policy.licenses);
      expect(restored.checkDevDependencies, isTrue);
    });

    // A policy written against a newer build must not take the rest of itself
    // down with the entry this build cannot read.
    test('drops entries it does not recognise and keeps the rest', () {
      final restored = LicensePolicy.fromJson({
        'categories': {
          'permissive': 'allowed',
          'someFutureFamily': 'allowed',
          'weakCopyleft': 'tolerated',
        },
        'licenses': {'MIT': 'allowed', 'ISC': 'maybe'},
      });

      expect(restored.categories, {LicenseCategory.permissive: LicenseRule.allowed});
      expect(restored.licenses, {'MIT': LicenseRule.allowed});
    });

    // The dropped family still has to be judged. Falling through to "allowed"
    // would let an unreadable policy clear a GPL dependency.
    test('still judges a family it has no stored rule for', () {
      const partial = LicensePolicy(
        categories: {LicenseCategory.permissive: LicenseRule.allowed},
      );

      expect(
        partial.ruleForCategory(LicenseCategory.networkCopyleft),
        LicenseRule.forbidden,
      );
      expect(
        partial.ruleForCategory(LicenseCategory.unknown),
        LicenseRule.review,
      );
    });

    test('reads an empty document as a policy that decides nothing itself', () {
      final empty = LicensePolicy.fromJson(const {});
      expect(empty.categories, isEmpty);
      expect(empty.licenses, isEmpty);
      expect(empty.checkDevDependencies, isFalse);
      // But still falls back to the standard rules rather than clearing.
      expect(
        empty.decide(_license('GPL-3.0-only', LicenseCategory.strongCopyleft)).rule,
        LicenseRule.forbidden,
      );
    });
  });
}
