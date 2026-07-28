import 'package_license.dart';

/// What a company has decided about a license.
///
/// Three values rather than two, because a binary allow/deny forces every
/// weak-copyleft package into one of two wrong answers: banned outright, or
/// waved through with nobody having looked. [review] is the honest third state,
/// and it is where most real policies put MPL and LGPL.
enum LicenseRule {
  /// Cleared for use. Appears in the manifest and nowhere else.
  allowed,

  /// Usable, but somebody has to look before it ships.
  review,

  /// Not usable under this policy.
  forbidden;

  /// Worst first, so a report can sort by `severity` the way the security one
  /// does.
  int get severity => switch (this) {
        LicenseRule.forbidden => 0,
        LicenseRule.review => 1,
        LicenseRule.allowed => 2,
      };

  String get label => switch (this) {
        LicenseRule.allowed => 'Allowed',
        LicenseRule.review => 'Needs review',
        LicenseRule.forbidden => 'Forbidden',
      };
}

/// The verdict on one package, and the sentence that justifies it.
///
/// A compliance finding without its reasoning is unusable: the reader's next
/// step is either to fix the dependency or to fix the policy, and which one
/// depends entirely on *why* it was flagged.
typedef LicenseDecision = ({LicenseRule rule, String reason});

/// A company's rules about which licenses its code may depend on.
///
/// Written primarily against [LicenseCategory] rather than against individual
/// licenses, because that is how policies are actually decided — the question
/// is "can this oblige us to publish our source", not "how do we feel about
/// BSD-2-Clause as distinct from BSD-3-Clause". Individual licenses can still
/// be named in [licenses] for the exceptions every policy accumulates.
class LicensePolicy {
  const LicensePolicy({
    this.categories = const {},
    this.licenses = const {},
    this.checkDevDependencies = false,
  });

  /// The default policy, applied until someone edits it.
  ///
  /// Deliberately opinionated rather than permissive: a compliance feature
  /// whose out-of-the-box answer is "everything is fine" has told you nothing.
  /// It bans the copyleft families that can reach your own source, asks for a
  /// human on the ones that only reach the package itself, and treats an
  /// unidentified license as needing review — because a missing license grant
  /// is a question, not a clearance.
  static const standard = LicensePolicy(
    categories: {
      LicenseCategory.permissive: LicenseRule.allowed,
      LicenseCategory.weakCopyleft: LicenseRule.review,
      LicenseCategory.strongCopyleft: LicenseRule.forbidden,
      LicenseCategory.networkCopyleft: LicenseRule.forbidden,
      LicenseCategory.proprietary: LicenseRule.forbidden,
      LicenseCategory.unknown: LicenseRule.review,
    },
  );

  /// The rule for each license family. Families absent here fall back to
  /// [standard], so a stored policy that predates a new category still has an
  /// answer for it rather than silently allowing it.
  final Map<LicenseCategory, LicenseRule> categories;

  /// Rules for named licenses, keyed by SPDX identifier. These override
  /// [categories] — this is where "we have signed a deal, MongoDB's SSPL is
  /// fine for us" lives, and equally where "no GPL-2.0-only, but 3.0 is fine"
  /// lives.
  ///
  /// Matched case-insensitively; SPDX identifiers are conventionally cased but
  /// nobody types them that way.
  final Map<String, LicenseRule> licenses;

  /// Whether dev-only dependencies are checked.
  ///
  /// Off by default. A GPL test runner or code generator is not linked into
  /// what you ship, and flagging it produces exactly the kind of noise that
  /// gets a compliance report ignored. Turn it on if you redistribute your
  /// toolchain.
  final bool checkDevDependencies;

  /// This policy's rule for [category], falling back to the standard policy for
  /// families this policy has no entry for.
  LicenseRule ruleForCategory(LicenseCategory category) =>
      categories[category] ??
      LicensePolicy.standard.categories[category] ??
      LicenseRule.review;

  /// The verdict on [license], with the reason it was reached.
  ///
  /// [devOnly] says the package is reachable only through dev dependencies —
  /// nothing that ships depends on it.
  LicenseDecision decide(PackageLicense? license, {bool devOnly = false}) {
    if (devOnly && !checkDevDependencies) {
      return (
        rule: LicenseRule.allowed,
        reason: 'Nothing you ship depends on this — it is reachable only '
            'through dev dependencies, which this policy does not check.',
      );
    }

    final spdxId = license?.spdxId;
    if (spdxId != null) {
      final named = _namedRule(spdxId);
      if (named != null) {
        return (
          rule: named,
          reason: 'Your policy names $spdxId explicitly: '
              '${named.label.toLowerCase()}.',
        );
      }
    }

    final category = license?.category ?? LicenseCategory.unknown;
    final rule = ruleForCategory(category);

    if (category == LicenseCategory.unknown) {
      return (
        rule: rule,
        // Two different unknowns. pub.dev naming a license this build has no
        // category for is a gap in the catalog, and the reader can close it by
        // naming the license in the policy. pub.dev naming none at all is a
        // gap in the package, and the reader cannot close it from here.
        reason: spdxId != null
            ? 'pub.dev reports $spdxId, which this build has no obligation '
                'category for. Name it in your policy once you have decided '
                'how you treat it.'
            : 'pub.dev could not identify a license for this package. Code '
                'with no identifiable grant is not licensed to you by default.',
      );
    }

    return (
      rule: rule,
      reason: '$spdxId is ${category.label.toLowerCase()}. '
          '${category.obligation}',
    );
  }

  /// Case-insensitive lookup in [licenses].
  LicenseRule? _namedRule(String spdxId) {
    final wanted = spdxId.toLowerCase();
    for (final entry in licenses.entries) {
      if (entry.key.toLowerCase() == wanted) return entry.value;
    }
    return null;
  }

  LicensePolicy copyWith({
    Map<LicenseCategory, LicenseRule>? categories,
    Map<String, LicenseRule>? licenses,
    bool? checkDevDependencies,
  }) =>
      LicensePolicy(
        categories: categories ?? this.categories,
        licenses: licenses ?? this.licenses,
        checkDevDependencies:
            checkDevDependencies ?? this.checkDevDependencies,
      );

  /// Reads a policy, ignoring entries it does not recognise.
  ///
  /// A policy arriving with a category or rule this build has never heard of is
  /// a policy written against a newer version of this app. Dropping the unknown
  /// entry leaves the rest of the policy working, and the fallback in
  /// [ruleForCategory] means the dropped family is still judged rather than
  /// waved through.
  factory LicensePolicy.fromJson(Map<String, dynamic> json) => LicensePolicy(
        categories: {
          for (final entry
              in ((json['categories'] as Map?) ?? const {}).entries)
            if (LicenseCategory.values.asNameMap()[entry.key]
                case final category?)
              if (LicenseRule.values.asNameMap()['${entry.value}']
                  case final rule?)
                category: rule,
        },
        licenses: {
          for (final entry in ((json['licenses'] as Map?) ?? const {}).entries)
            if (LicenseRule.values.asNameMap()['${entry.value}']
                case final rule?)
              '${entry.key}': rule,
        },
        checkDevDependencies: json['checkDevDependencies'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'categories': {
          for (final entry in categories.entries) entry.key.name: entry.value.name,
        },
        'licenses': {
          for (final entry in licenses.entries) entry.key: entry.value.name,
        },
        'checkDevDependencies': checkDevDependencies,
      };
}
