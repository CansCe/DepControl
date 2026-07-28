import 'package:backend/src/services/license_catalog.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

/// Tag sets copied from pub.dev's `/score` responses, trimmed to the license
/// ones plus enough of the rest to prove they are ignored.
void main() {
  group('reading pub.dev tags', () {
    test('reads the SPDX id and its conventional spelling', () {
      final license = LicenseCatalog.read(
        const [
          'publisher:dart.dev',
          'sdk:dart',
          'license:bsd-3-clause',
          'license:fsf-libre',
          'license:osi-approved',
          'topic:http',
        ],
        source: LicenseSource.installedVersion,
        readFromVersion: '1.5.0',
      );

      expect(license!.spdxId, 'BSD-3-Clause');
      expect(license.category, LicenseCategory.permissive);
      expect(license.osiApproved, isTrue);
      expect(license.fsfLibre, isTrue);
      expect(license.readFromVersion, '1.5.0');
    });

    test('does not mistake the qualifier tags for a license', () {
      final license = LicenseCatalog.read(
        const ['license:osi-approved', 'license:fsf-libre'],
        source: LicenseSource.installedVersion,
      );

      expect(license!.spdxId, isNull);
      expect(license.category, LicenseCategory.unknown);
      expect(license.osiApproved, isTrue);
    });

    // The difference this class exists to preserve. `license:unknown` is a
    // result — pub.dev analysed the package and found nothing it could
    // identify. No license tags at all means there was no analysis to read, and
    // the caller should go and ask about a different version.
    test('separates "could not identify" from "nothing to read"', () {
      final unidentified = LicenseCatalog.read(
        const ['license:unknown'],
        source: LicenseSource.installedVersion,
      );
      expect(unidentified, isNotNull);
      expect(unidentified!.category, LicenseCategory.unknown);

      expect(
        LicenseCatalog.read(
          const ['sdk:dart', 'is:null-safe'],
          source: LicenseSource.installedVersion,
        ),
        isNull,
      );
      expect(
        LicenseCatalog.read(const [], source: LicenseSource.installedVersion),
        isNull,
      );
    });

    // Reporting an unrecognised license as permissive would be worse than
    // reporting nothing: it is the one error that gets a package shipped.
    test('reports a license it cannot classify without guessing at it', () {
      final license = LicenseCatalog.read(
        const ['license:zpl-2.1', 'license:osi-approved'],
        source: LicenseSource.installedVersion,
      );

      expect(license!.spdxId, 'zpl-2.1');
      expect(license.category, LicenseCategory.unknown);
      expect(license.osiApproved, isTrue);
    });
  });

  group('obligation families', () {
    void expectCategory(String tag, LicenseCategory category) {
      test('$tag is ${category.name}', () {
        final license = LicenseCatalog.read(
          ['license:$tag'],
          source: LicenseSource.installedVersion,
        );
        expect(license!.category, category);
      });
    }

    expectCategory('mit', LicenseCategory.permissive);
    expectCategory('apache-2.0', LicenseCategory.permissive);
    expectCategory('bsd-2-clause', LicenseCategory.permissive);
    expectCategory('unlicense', LicenseCategory.permissive);

    expectCategory('lgpl-3.0-or-later', LicenseCategory.weakCopyleft);
    expectCategory('mpl-2.0', LicenseCategory.weakCopyleft);
    expectCategory('epl-2.0', LicenseCategory.weakCopyleft);

    expectCategory('gpl-2.0-only', LicenseCategory.strongCopyleft);
    expectCategory('gpl-3.0-or-later', LicenseCategory.strongCopyleft);
    expectCategory('cc-by-sa-4.0', LicenseCategory.strongCopyleft);

    // The family that catches a hosted service, which never ships a binary and
    // so concluded it never distributes.
    expectCategory('agpl-3.0-or-later', LicenseCategory.networkCopyleft);
    expectCategory('eupl-1.2', LicenseCategory.networkCopyleft);

    expectCategory('busl-1.1', LicenseCategory.proprietary);
    expectCategory('sspl-1.0', LicenseCategory.proprietary);
    expectCategory('cc-by-nc-4.0', LicenseCategory.proprietary);

    // GPL and LGPL differ by one letter and by whether they reach your code.
    test('does not confuse LGPL with GPL', () {
      expect(LicenseCatalog.categoryFor('LGPL-3.0-only'),
          LicenseCategory.weakCopyleft);
      expect(LicenseCatalog.categoryFor('GPL-3.0-only'),
          LicenseCategory.strongCopyleft);
      expect(LicenseCatalog.categoryFor('AGPL-3.0-only'),
          LicenseCategory.networkCopyleft);
    });

    // SPDX deprecated the bare form and read it as "or later"; pub.dev still
    // publishes it.
    test('reads the deprecated bare form as SPDX did', () {
      final license = LicenseCatalog.read(
        const ['license:gpl-3.0'],
        source: LicenseSource.installedVersion,
      );
      expect(license!.spdxId, 'GPL-3.0-or-later');
    });

    test('matches an SPDX id case-insensitively', () {
      expect(LicenseCatalog.categoryFor('mit'), LicenseCategory.permissive);
      expect(LicenseCatalog.categoryFor('MIT'), LicenseCategory.permissive);
      expect(LicenseCatalog.categoryFor('Apache-2.0'),
          LicenseCategory.permissive);
      expect(LicenseCatalog.categoryFor('not-a-license'), isNull);
    });
  });
}
