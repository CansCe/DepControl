/// What a license obliges you to do — the axis a company policy is written on.
///
/// Policies are almost never written per SPDX identifier: nobody has an opinion
/// about `BSD-2-Clause` that differs from their opinion about `MIT`. What they
/// have an opinion about is whether using a package can force them to publish
/// their own source, and under what trigger. These are those triggers.
enum LicenseCategory {
  /// Attribution, and little else: MIT, BSD, Apache-2.0, ISC.
  permissive,

  /// Copyleft scoped to the licensed files or library — LGPL, MPL-2.0, EPL.
  /// Modifying the package obliges you; linking against it generally does not.
  weakCopyleft,

  /// Copyleft over the whole combined work — the GPL family. Distributing
  /// something built on it obliges you to offer that thing's source too.
  strongCopyleft,

  /// Copyleft triggered by *use over a network*, not just distribution — AGPL.
  /// A hosted service never ships a binary, so this is the family that catches
  /// people who assumed "we don't distribute" was the end of the question.
  networkCopyleft,

  /// Not open source: source-available or all-rights-reserved terms such as
  /// BUSL-1.1, Elastic-2.0, SSPL-1.0. Whether these are usable at all is a
  /// question for a lawyer rather than for a policy default.
  proprietary,

  /// pub.dev found no license file, or one it could not identify.
  ///
  /// Not a mild finding. A work with no stated license grant is, by default,
  /// not licensed to you at all — so this is missing information about a
  /// possible problem rather than the absence of one.
  unknown;

  /// Short label for a UI or a report column.
  String get label => switch (this) {
        LicenseCategory.permissive => 'Permissive',
        LicenseCategory.weakCopyleft => 'Weak copyleft',
        LicenseCategory.strongCopyleft => 'Strong copyleft',
        LicenseCategory.networkCopyleft => 'Network copyleft',
        LicenseCategory.proprietary => 'Not open source',
        LicenseCategory.unknown => 'Unidentified',
      };

  /// One sentence on what this family asks of you, for a reader who is not a
  /// lawyer and is about to have to talk to one.
  String get obligation => switch (this) {
        LicenseCategory.permissive =>
          'Attribution. No obligation to publish your own source.',
        LicenseCategory.weakCopyleft =>
          'Changes to the package itself must be published. Your own code '
              'generally need not be.',
        LicenseCategory.strongCopyleft =>
          'Distributing a work built on this can oblige you to publish that '
              "work's source under the same terms.",
        LicenseCategory.networkCopyleft =>
          'Letting users reach it over a network counts as distribution, so a '
              'hosted service can be obliged to publish its source.',
        LicenseCategory.proprietary =>
          'Not an open-source grant. Read the terms before shipping anything '
              'that depends on it.',
        LicenseCategory.unknown =>
          'No license grant could be identified, which is not the same as '
              'permission having been given.',
      };

  /// Whether this family can reach your own code. The line a policy usually
  /// draws first.
  bool get isCopyleft =>
      this == LicenseCategory.weakCopyleft ||
      this == LicenseCategory.strongCopyleft ||
      this == LicenseCategory.networkCopyleft;
}

/// Which release of a package the license was actually read from.
///
/// pub.dev analyses a package per published version and eventually drops the
/// analysis for old ones, so the license of the version you have installed is
/// not always available. The alternative to recording this would be to quietly
/// present the current release's license as the installed release's, and a
/// relicensing is exactly the event a compliance report exists to catch.
enum LicenseSource {
  /// Read from pub.dev's analysis of the installed version. A fact.
  installedVersion,

  /// The installed version has no analysis on pub.dev, so this is the latest
  /// release's license. Almost always the same — but an inference, and reported
  /// as one.
  latestRelease,

  /// The package does not come from pub.dev at all — it is an SDK, path or git
  /// dependency — so there is no published analysis, and there never will be.
  ///
  /// Worth its own value rather than collapsing into [undetermined], because
  /// pub.dev *does* serve packages under some of these names and they are not
  /// the same software. `flutter` on pub.dev is a discontinued placeholder with
  /// eighty downloads a month; `sky_engine` likewise. Reading a license off one
  /// of those and printing it next to the SDK's name would be a fabricated
  /// answer that happens to look plausible.
  notFromPubDev,

  /// Neither could be read.
  undetermined,
}

/// The license of one published package version, as pub.dev identified it.
///
/// pub.dev runs license detection over each package's `LICENSE` file and
/// publishes the result as tags — `license:mit`, plus `license:osi-approved`
/// and `license:fsf-libre` where they apply. That detection is the same one
/// behind the license shown on every package page, so this reports what a
/// reviewer would see if they looked the package up by hand.
class PackageLicense {
  const PackageLicense({
    this.spdxId,
    this.category = LicenseCategory.unknown,
    this.source = LicenseSource.undetermined,
    this.osiApproved = false,
    this.fsfLibre = false,
    this.readFromVersion,
    this.origin,
  });

  /// Nothing could be established — the package has no analysis on pub.dev at
  /// all. Distinct from a detected [LicenseCategory.unknown], which means
  /// pub.dev looked and could not identify what it found.
  static const undetermined = PackageLicense();

  /// A package that is not published on pub.dev, so its license lives in its
  /// own source rather than in an analysis. [origin] names where it does come
  /// from, e.g. `the SDK`.
  const PackageLicense.notFromPubDev(String this.origin)
      : spdxId = null,
        category = LicenseCategory.unknown,
        source = LicenseSource.notFromPubDev,
        osiApproved = false,
        fsfLibre = false,
        readFromVersion = null;

  /// SPDX identifier, e.g. `MIT`, `BSD-3-Clause`, `AGPL-3.0-or-later`.
  ///
  /// Null when pub.dev could not identify the license, whether because the
  /// package ships none or because the text is not one it recognises.
  final String? spdxId;

  final LicenseCategory category;

  /// Whether [spdxId] describes the installed version or the latest release.
  final LicenseSource source;

  /// Approved by the Open Source Initiative, per pub.dev's `license:osi-approved`
  /// tag. Carried because some policies are written in exactly these terms.
  final bool osiApproved;

  /// Considered free software by the FSF, per `license:fsf-libre`.
  final bool fsfLibre;

  /// The version the license was read from. Equal to the installed version when
  /// [source] is [LicenseSource.installedVersion]; the latest release otherwise.
  final String? readFromVersion;

  /// Where a package that is not on pub.dev comes from instead — `the SDK`, `a
  /// path dependency`, `a git dependency`. Null for everything published.
  final String? origin;

  /// What to print where a license name goes.
  String get displayName => spdxId ?? 'Unidentified';

  /// Whether this reading describes the version in use rather than another one.
  bool get isForInstalledVersion => source == LicenseSource.installedVersion;

  /// Set when this reading needs a caveat next to it, phrased for the reader.
  String? get caveat => switch (source) {
        LicenseSource.installedVersion => null,
        LicenseSource.latestRelease => readFromVersion == null
            ? 'Read from the latest release, not the installed version — '
                'pub.dev no longer publishes an analysis for that version.'
            : 'Read from $readFromVersion, the latest release, because '
                'pub.dev no longer publishes an analysis for the installed '
                'version.',
        LicenseSource.notFromPubDev =>
          'Comes from ${origin ?? 'outside pub.dev'}, not from pub.dev, so its '
              'license is in its own source rather than in a published '
              'analysis.',
        LicenseSource.undetermined =>
          'pub.dev publishes no license analysis for this package.',
      };

  /// Whether this is a package a license could ever have been read for.
  ///
  /// False for an SDK, path or git dependency: there is no published analysis
  /// to be missing, so listing it as an unidentified license would be reporting
  /// a failure that never happened.
  bool get isPublished => source != LicenseSource.notFromPubDev;

  factory PackageLicense.fromJson(Map<String, dynamic> json) => PackageLicense(
        spdxId: json['spdxId'] as String?,
        category: LicenseCategory.values.asNameMap()[json['category']] ??
            LicenseCategory.unknown,
        source: LicenseSource.values.asNameMap()[json['source']] ??
            LicenseSource.undetermined,
        osiApproved: json['osiApproved'] as bool? ?? false,
        fsfLibre: json['fsfLibre'] as bool? ?? false,
        readFromVersion: json['readFromVersion'] as String?,
        origin: json['origin'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'spdxId': spdxId,
        'category': category.name,
        'source': source.name,
        'osiApproved': osiApproved,
        'fsfLibre': fsfLibre,
        'readFromVersion': readFromVersion,
        if (origin != null) 'origin': origin,
      };
}
