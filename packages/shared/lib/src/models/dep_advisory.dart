/// How bad an advisory is, on the CVSS qualitative scale.
///
/// Ordered worst-first so `values.indexOf` sorts the way a reader wants to
/// read: the thing that could end your week goes at the top.
enum AdvisorySeverity {
  critical,
  high,
  medium,
  low,

  /// CVSS scores 0.0. Rare, but part of the scale, and not the same as
  /// [unknown].
  none,

  /// The advisory published neither a CVSS vector nor a band. Deliberately
  /// last: not knowing how bad something is must never sort it above a known
  /// critical.
  unknown;

  /// Whether this band clears [threshold] — "at least this bad".
  ///
  /// The bands are declared worst-first, so this is an index comparison that
  /// reads backwards. It lives here rather than at each call site because
  /// getting it the wrong way round silently drops critical alerts, which is a
  /// bug nothing observable would report.
  ///
  /// [unknown] clears every threshold. An advisory that published neither a
  /// vector nor a band is one nobody has assessed, and "we do not know how bad
  /// this is" is not a reason to stay quiet. It still *sorts* last, so it never
  /// displaces a known critical — but it is not filtered out, for the same
  /// reason it is never reported as low.
  bool atLeastAsBadAs(AdvisorySeverity threshold) =>
      this == AdvisorySeverity.unknown || index <= threshold.index;

  /// Bands a CVSS base score, per the CVSS v3 qualitative severity scale.
  static AdvisorySeverity fromScore(double score) {
    if (score >= 9.0) return AdvisorySeverity.critical;
    if (score >= 7.0) return AdvisorySeverity.high;
    if (score >= 4.0) return AdvisorySeverity.medium;
    if (score > 0.0) return AdvisorySeverity.low;
    return AdvisorySeverity.none;
  }

  /// Reads the band names used by the GitHub Advisory Database, which are the
  /// CVSS ones except that it calls medium "moderate".
  static AdvisorySeverity? fromName(String? name) =>
      switch (name?.toLowerCase()) {
        'critical' => AdvisorySeverity.critical,
        'high' => AdvisorySeverity.high,
        'moderate' || 'medium' => AdvisorySeverity.medium,
        'low' => AdvisorySeverity.low,
        'none' => AdvisorySeverity.none,
        _ => null,
      };

  /// Whether this is worth interrupting someone for.
  bool get isSevere =>
      this == AdvisorySeverity.critical || this == AdvisorySeverity.high;
}

/// A security advisory that applies to the version of a package in use.
///
/// Named for the report rather than the wire: the backend also has an
/// `Advisory` holding the raw OSV document pub.dev serves, with every affected
/// range for every version ever published. This is the part that survives the
/// question "does it affect *this* project", plus the one thing anyone actually
/// wants next — the version that fixes it.
class DepAdvisory {
  const DepAdvisory({
    required this.id,
    this.aliases = const [],
    this.summary,
    this.fixedIn,
    this.severity = AdvisorySeverity.unknown,
    this.cvssScore,
    this.cvssVector,
  });

  /// Primary identifier, e.g. `GHSA-4rgh-jx4f-qfcq`.
  final String id;

  /// Other identifiers for the same issue, e.g. `CVE-2020-35669`. Worth
  /// carrying because a CVE is what most other tooling will call it.
  final List<String> aliases;

  /// One-line description from the advisory. Not paraphrased.
  final String? summary;

  /// The lowest published version that resolves this advisory, when one is
  /// known.
  ///
  /// Null means no fix is published *or* the advisory named affected versions
  /// individually without saying what fixes them — so a null here is "we do not
  /// know", never "there is no fix".
  final String? fixedIn;

  /// How bad it is. [AdvisorySeverity.unknown] when the advisory published
  /// nothing to judge it by — which is not a claim that it is mild.
  final AdvisorySeverity severity;

  /// CVSS v3 base score, 0.0–10.0, when a vector was published.
  ///
  /// Null while [severity] is still known happens: some advisories carry only
  /// the database's own band and no vector.
  final double? cvssScore;

  /// The vector the score came from, e.g.
  /// `CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:C/C:L/I:L/A:N`.
  ///
  /// Kept so a score can be checked rather than taken on faith — it is the
  /// whole derivation, and it is one line.
  final String? cvssVector;

  /// Where to read the advisory. OSV carries every ecosystem's ids, including
  /// the GHSA ones pub.dev publishes.
  String get url => 'https://osv.dev/vulnerability/$id';

  factory DepAdvisory.fromJson(Map<String, dynamic> json) => DepAdvisory(
        id: json['id'] as String,
        aliases:
            ((json['aliases'] as List?) ?? const []).map((a) => '$a').toList(),
        summary: json['summary'] as String?,
        fixedIn: json['fixedIn'] as String?,
        // Reports stored before severity was scored have no field at all, and
        // must read as "not known" rather than as the first enum value.
        severity: AdvisorySeverity.values.asNameMap()[json['severity']] ??
            AdvisorySeverity.unknown,
        cvssScore: (json['cvssScore'] as num?)?.toDouble(),
        cvssVector: json['cvssVector'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'aliases': aliases,
        'summary': summary,
        'fixedIn': fixedIn,
        'severity': severity.name,
        'cvssScore': cvssScore,
        'cvssVector': cvssVector,
      };
}
