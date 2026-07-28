import 'dep_node.dart';
import 'dep_report.dart';
import 'license_policy.dart';
import 'package_license.dart';

/// One package's license, and what the policy says about it.
class LicenseFinding {
  const LicenseFinding({
    required this.package,
    required this.version,
    required this.kind,
    required this.license,
    required this.rule,
    required this.reason,
    this.devOnly = false,
    this.manifests = const [],
  });

  final String package;
  final String version;
  final DepKind kind;
  final PackageLicense license;

  /// The policy's verdict.
  final LicenseRule rule;

  /// Why [rule] was reached — the sentence a reviewer needs in order to decide
  /// whether to change the dependency or change the policy.
  final String reason;

  /// Reachable only through dev dependencies, so nothing that ships depends on
  /// it. Reported even when the policy exempts it, because "exempt" and "clean"
  /// are different findings.
  final bool devOnly;

  /// Which of the repository's pubspecs pull this package in, when there is
  /// more than one.
  final List<String> manifests;

  factory LicenseFinding.fromJson(Map<String, dynamic> json) => LicenseFinding(
        package: json['package'] as String,
        version: json['version'] as String,
        kind: DepKind.values.asNameMap()[json['kind']] ?? DepKind.transitive,
        license: PackageLicense.fromJson(
          (json['license'] as Map).cast<String, dynamic>(),
        ),
        rule: LicenseRule.values.asNameMap()[json['rule']] ??
            LicenseRule.review,
        reason: json['reason'] as String? ?? '',
        devOnly: json['devOnly'] as bool? ?? false,
        manifests: (json['manifests'] as List?)?.cast<String>() ?? const [],
      );

  Map<String, dynamic> toJson() => {
        'package': package,
        'version': version,
        'kind': kind.name,
        'license': license.toJson(),
        'rule': rule.name,
        'reason': reason,
        'devOnly': devOnly,
        if (manifests.isNotEmpty) 'manifests': manifests,
      };
}

/// A dependency the policy was not run against, and why not.
///
/// Kept apart from [LicenseFinding] rather than folded in as a verdict, because
/// "we could not check this" is not a finding about the package. Filing an
/// unchecked dependency under *needs review* buries the ones a human really
/// does have to look at — and for a package from the SDK or from your own
/// repository there is nothing for that human to do.
class UncheckedPackage {
  const UncheckedPackage({
    required this.package,
    required this.version,
    required this.reason,
  });

  final String package;
  final String version;

  /// Why it was not checked, phrased for the reader.
  final String reason;

  factory UncheckedPackage.fromJson(Map<String, dynamic> json) =>
      UncheckedPackage(
        package: json['package'] as String,
        version: json['version'] as String,
        reason: json['reason'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'package': package,
        'version': version,
        'reason': reason,
      };
}

/// Every dependency's license, judged against a policy — the artefact you hand
/// to whoever has to sign off on shipping.
///
/// Carries the [policy] it was evaluated under. A manifest that says "3
/// forbidden" without saying what was forbidden is not reviewable six months
/// later, and the policy is the half of that answer which is not in the list.
class LicenseReport {
  const LicenseReport({
    required this.projectId,
    required this.generatedAt,
    required this.policy,
    this.findings = const [],
    this.unchecked = const [],
  });

  final String projectId;
  final DateTime generatedAt;

  /// The rules applied. Stored with the result so the result can be re-read.
  final LicensePolicy policy;

  /// One per dependency, worst first, then by name.
  final List<LicenseFinding> findings;

  /// Dependencies the policy was not run against, and why not — packages from
  /// a report generated before license scanning existed, and packages that do
  /// not come from pub.dev at all.
  ///
  /// Listed rather than judged: presenting a package nobody checked as either
  /// clean or unidentified would be inventing a result.
  final List<UncheckedPackage> unchecked;

  /// Builds the report by running [policy] over every node in [report].
  factory LicenseReport.of(DepReport report, LicensePolicy policy) {
    final devOnly = report.devOnlyPackages;
    final findings = <LicenseFinding>[];
    final unchecked = <UncheckedPackage>[];

    for (final node in report.nodes) {
      final license = node.license;
      if (license == null || !license.isPublished) {
        unchecked.add(
          UncheckedPackage(
            package: node.name,
            version: node.installed,
            reason: license?.caveat ??
                'This report predates license scanning. Re-analyze the '
                    'project to include it.',
          ),
        );
        continue;
      }

      final isDevOnly = devOnly.contains(node.name);
      final decision = policy.decide(license, devOnly: isDevOnly);
      findings.add(
        LicenseFinding(
          package: node.name,
          version: node.installed,
          kind: node.kind,
          license: license,
          rule: decision.rule,
          reason: decision.reason,
          devOnly: isDevOnly,
          manifests: node.manifests,
        ),
      );
    }

    findings.sort((a, b) {
      final byRule = a.rule.severity.compareTo(b.rule.severity);
      if (byRule != 0) return byRule;
      final byName = a.package.compareTo(b.package);
      return byName != 0 ? byName : a.version.compareTo(b.version);
    });
    unchecked.sort((a, b) {
      final byName = a.package.compareTo(b.package);
      return byName != 0 ? byName : a.version.compareTo(b.version);
    });

    return LicenseReport(
      projectId: report.projectId,
      generatedAt: report.generatedAt,
      policy: policy,
      findings: findings,
      unchecked: unchecked,
    );
  }

  /// How many packages fall under each rule, worst first and skipping rules
  /// with none.
  Map<LicenseRule, int> get counts {
    final counts = <LicenseRule, int>{};
    for (final finding in findings) {
      counts.update(finding.rule, (n) => n + 1, ifAbsent: () => 1);
    }
    // Worst first, which is not the enum's declaration order — `allowed` is
    // declared first because it is the ordinary case, and it is the last thing
    // a reader wants at the top of a summary.
    final ordered = LicenseRule.values.toList()
      ..sort((a, b) => a.severity.compareTo(b.severity));
    return {
      for (final rule in ordered)
        if (counts[rule] != null) rule: counts[rule]!,
    };
  }

  /// Packages the policy will not clear on its own — forbidden first.
  List<LicenseFinding> get flagged =>
      findings.where((f) => f.rule != LicenseRule.allowed).toList();

  List<LicenseFinding> get forbidden =>
      findings.where((f) => f.rule == LicenseRule.forbidden).toList();

  /// Distinct licenses in use and how many packages carry each, commonest
  /// first. The inventory half of the manifest, as opposed to the verdict half.
  Map<String, int> get licenseCounts {
    final counts = <String, int>{};
    for (final finding in findings) {
      counts.update(
        finding.license.displayName,
        (n) => n + 1,
        ifAbsent: () => 1,
      );
    }
    final entries = counts.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        return byCount != 0 ? byCount : a.key.compareTo(b.key);
      });
    return {for (final e in entries) e.key: e.value};
  }

  /// Findings whose license was read from a release other than the installed
  /// one. Small in practice, and worth naming: it is the one part of the
  /// manifest that is inferred rather than read.
  List<LicenseFinding> get inferredFromOtherVersion => findings
      .where((f) => f.license.source == LicenseSource.latestRelease)
      .toList();

  bool get isClean => flagged.isEmpty && unchecked.isEmpty;

  /// The manifest as CSV — the format whoever reviews this will open it in.
  ///
  /// One row per dependency, including the allowed ones: a compliance manifest
  /// is an inventory first and an exception list second, and a reviewer needs
  /// to see that the permissive majority was actually examined.
  String toCsv() {
    final rows = <List<String>>[
      [
        'package',
        'version',
        'license',
        'category',
        'policy',
        'dependency',
        'ships',
        'osi_approved',
        'fsf_libre',
        'license_read_from',
        'manifests',
        'reason',
      ],
      for (final f in findings)
        [
          f.package,
          f.version,
          f.license.displayName,
          f.license.category.label,
          f.rule.label,
          f.kind.name,
          f.devOnly ? 'no' : 'yes',
          f.license.osiApproved ? 'yes' : 'no',
          f.license.fsfLibre ? 'yes' : 'no',
          switch (f.license.source) {
            LicenseSource.installedVersion => f.version,
            LicenseSource.latestRelease =>
              '${f.license.readFromVersion ?? 'latest'} (latest release)',
            LicenseSource.notFromPubDev => 'not on pub.dev',
            LicenseSource.undetermined => 'not published',
          },
          f.manifests.join(' '),
          f.reason,
        ],
      // Kept in the same table rather than a second one: a spreadsheet the
      // reviewer filters should not be able to hide the rows nobody checked.
      for (final entry in unchecked)
        [
          entry.package,
          entry.version,
          'not checked',
          '',
          'Not checked',
          '',
          '',
          '',
          '',
          '',
          '',
          entry.reason,
        ],
    ];

    return rows.map((row) => row.map(_csvField).join(',')).join('\r\n');
  }

  /// Quotes a CSV field when it holds a separator, a quote, or a newline.
  /// Reasons are prose and contain commas in almost every row.
  static String _csvField(String value) {
    if (!value.contains(RegExp('[",\r\n]'))) return value;
    return '"${value.replaceAll('"', '""')}"';
  }

  factory LicenseReport.fromJson(Map<String, dynamic> json) => LicenseReport(
        projectId: json['projectId'] as String,
        generatedAt: DateTime.parse(json['generatedAt'] as String),
        policy: LicensePolicy.fromJson(
          ((json['policy'] as Map?) ?? const {}).cast<String, dynamic>(),
        ),
        findings: ((json['findings'] as List?) ?? const [])
            .map((e) => LicenseFinding.fromJson(e as Map<String, dynamic>))
            .toList(),
        unchecked: ((json['unchecked'] as List?) ?? const [])
            .map((e) => UncheckedPackage.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'projectId': projectId,
        'generatedAt': generatedAt.toIso8601String(),
        'policy': policy.toJson(),
        'findings': findings.map((f) => f.toJson()).toList(),
        if (unchecked.isNotEmpty)
          'unchecked': unchecked.map((u) => u.toJson()).toList(),
      };
}
