import 'package:shared/shared.dart';

/// Reads pub.dev's license tags, and says what obligations each license family
/// carries.
///
/// pub.dev runs license detection over every published version and publishes
/// the result as analysis tags — `license:mit`, plus `license:osi-approved` and
/// `license:fsf-libre` where they apply, or `license:unknown` where detection
/// failed. Detection happens once, on pub.dev, from the package's own `LICENSE`
/// file; this class only interprets the answer.
///
/// The classification is the part that is this project's opinion rather than
/// pub.dev's, so it is written out in full and kept here where it can be read
/// and argued with. Two things it deliberately does *not* do:
///
/// * **Guess.** A license identifier that is not in the table below gets its
///   SPDX id reported and [LicenseCategory.unknown] as its family, which under
///   the standard policy means a human looks at it. Filing an unrecognised
///   license under "probably permissive" is how a compliance tool becomes worse
///   than no tool.
/// * **Give legal advice.** A category says what a license family generally
///   obliges. Whether an obligation binds a particular product is a question
///   about how that product is built and shipped, and this cannot see either.
abstract final class LicenseCatalog {
  /// The prefix pub.dev puts on all of these.
  static const _prefix = 'license:';

  /// Tag values that qualify a license rather than naming one.
  static const _osiApproved = 'osi-approved';
  static const _fsfLibre = 'fsf-libre';
  static const _unidentified = 'unknown';

  /// The license in [tags], or null when they carry none.
  ///
  /// Null and [LicenseCategory.unknown] are different answers and both are
  /// real. Null means pub.dev published no analysis for what was asked about —
  /// which happens for older versions, and is a cue to ask about a different
  /// one. `unknown` means pub.dev analysed the package and could not identify
  /// a license in it, which is a finding.
  static PackageLicense? read(
    Iterable<String> tags, {
    required LicenseSource source,
    String? readFromVersion,
  }) {
    final values = [
      for (final tag in tags)
        if (tag.startsWith(_prefix)) tag.substring(_prefix.length),
    ];
    if (values.isEmpty) return null;

    final osiApproved = values.contains(_osiApproved);
    final fsfLibre = values.contains(_fsfLibre);

    final identifier = values.firstWhere(
      (v) => v != _osiApproved && v != _fsfLibre && v != _unidentified,
      orElse: () => '',
    );

    if (identifier.isEmpty) {
      return PackageLicense(
        category: LicenseCategory.unknown,
        source: source,
        osiApproved: osiApproved,
        fsfLibre: fsfLibre,
        readFromVersion: readFromVersion,
      );
    }

    final known = _licenses[identifier];
    return PackageLicense(
      // pub.dev lowercases the identifier, and SPDX ids are conventionally
      // mixed case. Known ids get their conventional spelling back; an
      // unrecognised one is reported exactly as published rather than
      // reformatted into something that looks canonical and is not.
      spdxId: known?.spdx ?? identifier,
      category: known?.category ?? LicenseCategory.unknown,
      source: source,
      osiApproved: osiApproved,
      fsfLibre: fsfLibre,
      readFromVersion: readFromVersion,
    );
  }

  /// The family [spdxId] belongs to, or null if this table has never heard of
  /// it. Case-insensitive.
  static LicenseCategory? categoryFor(String spdxId) =>
      _licenses[spdxId.toLowerCase()]?.category;

  /// SPDX identifier (lowercased, as pub.dev publishes it) -> conventional
  /// spelling and obligation family.
  ///
  /// The `-only` / `-or-later` variants are listed separately because SPDX
  /// treats them as different licenses and a policy may too: `GPL-2.0-or-later`
  /// permits relicensing under GPL-3.0 and `GPL-2.0-only` does not. The bare
  /// `gpl-2.0` form is deprecated by SPDX but still appears, and is read as the
  /// `-or-later` reading SPDX itself gave it.
  static const _licenses = <String, ({String spdx, LicenseCategory category})>{
    // Permissive: attribution, and nothing that reaches your own source.
    '0bsd': (spdx: '0BSD', category: LicenseCategory.permissive),
    'afl-3.0': (spdx: 'AFL-3.0', category: LicenseCategory.permissive),
    'apache-2.0': (spdx: 'Apache-2.0', category: LicenseCategory.permissive),
    'bsd-2-clause': (
      spdx: 'BSD-2-Clause',
      category: LicenseCategory.permissive
    ),
    'bsd-3-clause': (
      spdx: 'BSD-3-Clause',
      category: LicenseCategory.permissive
    ),
    'bsd-3-clause-clear': (
      spdx: 'BSD-3-Clause-Clear',
      category: LicenseCategory.permissive
    ),
    'bsd-4-clause': (
      spdx: 'BSD-4-Clause',
      category: LicenseCategory.permissive
    ),
    'bsl-1.0': (spdx: 'BSL-1.0', category: LicenseCategory.permissive),
    'cc-by-3.0': (spdx: 'CC-BY-3.0', category: LicenseCategory.permissive),
    'cc-by-4.0': (spdx: 'CC-BY-4.0', category: LicenseCategory.permissive),
    'cc0-1.0': (spdx: 'CC0-1.0', category: LicenseCategory.permissive),
    'isc': (spdx: 'ISC', category: LicenseCategory.permissive),
    'mit': (spdx: 'MIT', category: LicenseCategory.permissive),
    'mit-0': (spdx: 'MIT-0', category: LicenseCategory.permissive),
    'ms-pl': (spdx: 'MS-PL', category: LicenseCategory.permissive),
    'ncsa': (spdx: 'NCSA', category: LicenseCategory.permissive),
    'postgresql': (spdx: 'PostgreSQL', category: LicenseCategory.permissive),
    'python-2.0': (spdx: 'Python-2.0', category: LicenseCategory.permissive),
    'unlicense': (spdx: 'Unlicense', category: LicenseCategory.permissive),
    'wtfpl': (spdx: 'WTFPL', category: LicenseCategory.permissive),
    'zlib': (spdx: 'Zlib', category: LicenseCategory.permissive),

    // Weak copyleft: publishing changes to the package itself, not to yours.
    'artistic-2.0': (
      spdx: 'Artistic-2.0',
      category: LicenseCategory.weakCopyleft
    ),
    'cddl-1.0': (spdx: 'CDDL-1.0', category: LicenseCategory.weakCopyleft),
    'cddl-1.1': (spdx: 'CDDL-1.1', category: LicenseCategory.weakCopyleft),
    'cpl-1.0': (spdx: 'CPL-1.0', category: LicenseCategory.weakCopyleft),
    'epl-1.0': (spdx: 'EPL-1.0', category: LicenseCategory.weakCopyleft),
    'epl-2.0': (spdx: 'EPL-2.0', category: LicenseCategory.weakCopyleft),
    'lgpl-2.0': (
      spdx: 'LGPL-2.0-or-later',
      category: LicenseCategory.weakCopyleft
    ),
    'lgpl-2.0-only': (
      spdx: 'LGPL-2.0-only',
      category: LicenseCategory.weakCopyleft
    ),
    'lgpl-2.0-or-later': (
      spdx: 'LGPL-2.0-or-later',
      category: LicenseCategory.weakCopyleft
    ),
    'lgpl-2.1': (
      spdx: 'LGPL-2.1-or-later',
      category: LicenseCategory.weakCopyleft
    ),
    'lgpl-2.1-only': (
      spdx: 'LGPL-2.1-only',
      category: LicenseCategory.weakCopyleft
    ),
    'lgpl-2.1-or-later': (
      spdx: 'LGPL-2.1-or-later',
      category: LicenseCategory.weakCopyleft
    ),
    'lgpl-3.0': (
      spdx: 'LGPL-3.0-or-later',
      category: LicenseCategory.weakCopyleft
    ),
    'lgpl-3.0-only': (
      spdx: 'LGPL-3.0-only',
      category: LicenseCategory.weakCopyleft
    ),
    'lgpl-3.0-or-later': (
      spdx: 'LGPL-3.0-or-later',
      category: LicenseCategory.weakCopyleft
    ),
    'mpl-1.1': (spdx: 'MPL-1.1', category: LicenseCategory.weakCopyleft),
    'mpl-2.0': (spdx: 'MPL-2.0', category: LicenseCategory.weakCopyleft),
    'ms-rl': (spdx: 'MS-RL', category: LicenseCategory.weakCopyleft),

    // Strong copyleft: distributing the combined work reaches your source.
    'cc-by-sa-3.0': (
      spdx: 'CC-BY-SA-3.0',
      category: LicenseCategory.strongCopyleft
    ),
    'cc-by-sa-4.0': (
      spdx: 'CC-BY-SA-4.0',
      category: LicenseCategory.strongCopyleft
    ),
    'eupl-1.1': (spdx: 'EUPL-1.1', category: LicenseCategory.strongCopyleft),
    'gpl-1.0-only': (
      spdx: 'GPL-1.0-only',
      category: LicenseCategory.strongCopyleft
    ),
    'gpl-1.0-or-later': (
      spdx: 'GPL-1.0-or-later',
      category: LicenseCategory.strongCopyleft
    ),
    'gpl-2.0': (
      spdx: 'GPL-2.0-or-later',
      category: LicenseCategory.strongCopyleft
    ),
    'gpl-2.0-only': (
      spdx: 'GPL-2.0-only',
      category: LicenseCategory.strongCopyleft
    ),
    'gpl-2.0-or-later': (
      spdx: 'GPL-2.0-or-later',
      category: LicenseCategory.strongCopyleft
    ),
    'gpl-3.0': (
      spdx: 'GPL-3.0-or-later',
      category: LicenseCategory.strongCopyleft
    ),
    'gpl-3.0-only': (
      spdx: 'GPL-3.0-only',
      category: LicenseCategory.strongCopyleft
    ),
    'gpl-3.0-or-later': (
      spdx: 'GPL-3.0-or-later',
      category: LicenseCategory.strongCopyleft
    ),
    'sleepycat': (spdx: 'Sleepycat', category: LicenseCategory.strongCopyleft),

    // Network copyleft: serving it to users counts as distributing it. The
    // family that catches teams who concluded "we never ship a binary".
    'agpl-3.0': (
      spdx: 'AGPL-3.0-or-later',
      category: LicenseCategory.networkCopyleft
    ),
    'agpl-3.0-only': (
      spdx: 'AGPL-3.0-only',
      category: LicenseCategory.networkCopyleft
    ),
    'agpl-3.0-or-later': (
      spdx: 'AGPL-3.0-or-later',
      category: LicenseCategory.networkCopyleft
    ),
    'eupl-1.2': (spdx: 'EUPL-1.2', category: LicenseCategory.networkCopyleft),
    'osl-3.0': (spdx: 'OSL-3.0', category: LicenseCategory.networkCopyleft),

    // Not open source. Source-available, non-commercial, or field-of-use
    // restricted — none of them approved by the OSI, whatever they look like.
    'busl-1.1': (spdx: 'BUSL-1.1', category: LicenseCategory.proprietary),
    'cc-by-nc-3.0': (
      spdx: 'CC-BY-NC-3.0',
      category: LicenseCategory.proprietary
    ),
    'cc-by-nc-4.0': (
      spdx: 'CC-BY-NC-4.0',
      category: LicenseCategory.proprietary
    ),
    'cc-by-nc-sa-4.0': (
      spdx: 'CC-BY-NC-SA-4.0',
      category: LicenseCategory.proprietary
    ),
    'cc-by-nd-4.0': (
      spdx: 'CC-BY-ND-4.0',
      category: LicenseCategory.proprietary
    ),
    'elastic-2.0': (spdx: 'Elastic-2.0', category: LicenseCategory.proprietary),
    'json': (spdx: 'JSON', category: LicenseCategory.proprietary),
    'sspl-1.0': (spdx: 'SSPL-1.0', category: LicenseCategory.proprietary),
  };
}
