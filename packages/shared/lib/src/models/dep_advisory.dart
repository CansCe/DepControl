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

  /// Where to read the advisory. OSV carries every ecosystem's ids, including
  /// the GHSA ones pub.dev publishes.
  String get url => 'https://osv.dev/vulnerability/$id';

  factory DepAdvisory.fromJson(Map<String, dynamic> json) => DepAdvisory(
        id: json['id'] as String,
        aliases:
            ((json['aliases'] as List?) ?? const []).map((a) => '$a').toList(),
        summary: json['summary'] as String?,
        fixedIn: json['fixedIn'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'aliases': aliases,
        'summary': summary,
        'fixedIn': fixedIn,
      };
}
