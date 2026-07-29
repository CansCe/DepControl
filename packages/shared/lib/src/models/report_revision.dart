/// One entry in a project's report history: a distinct state its dependencies
/// were once in, and the window over which they were in it.
///
/// A revision is created when a scan finds something *different*, not every
/// time a scan runs. A daily re-scan of a project nobody is touching would
/// otherwise write 365 identical rows a year and bury the handful of moments
/// that mattered. So the history reads as "these are the times this changed",
/// which is the question anyone opens it to ask.
///
/// That is why there are two timestamps rather than one. [firstSeenAt] is when
/// this state was first observed and [lastSeenAt] when a scan last confirmed it
/// still held; collapsing them into a single "generated at" would make an
/// unchanged project look either stale or freshly changed, and both readings
/// are wrong.
///
/// Carries counts rather than the nodes themselves. A history list is read as a
/// list — twenty revisions of a 400-package project is a great deal of JSON to
/// send so that a screen can print three numbers per row. The full report is
/// fetched one revision at a time.
class ReportRevision {
  const ReportRevision({
    required this.id,
    required this.projectId,
    required this.firstSeenAt,
    required this.lastSeenAt,
    required this.digest,
    this.commitSha,
    this.total = 0,
    this.outdated = 0,
    this.vulnerable = 0,
  });

  /// Server-assigned identifier, and what a caller asks for to read the full
  /// report of this revision.
  final String id;

  final String projectId;

  /// When this dependency state was first observed.
  final DateTime firstSeenAt;

  /// When a scan last confirmed this state still held.
  ///
  /// Equal to [firstSeenAt] for a revision seen exactly once. Later than it
  /// means scans have run since and found nothing different — which is
  /// information, not noise: it is the difference between "unchanged for six
  /// months" and "nobody has looked in six months".
  final DateTime lastSeenAt;

  /// Digest of the report's contents, which is what decides whether a scan
  /// found a new revision or the same one again.
  ///
  /// Covers the resolved packages and the manifests the scan read. It is
  /// deliberately not a commit id: two commits can leave every dependency
  /// exactly where it was, and recording those as separate revisions would
  /// defeat the point.
  final String digest;

  /// The repository revision this report describes, where the forge told us.
  ///
  /// Null is ordinary rather than exceptional. A scan reads a ref — a branch
  /// name — and resolving that to a commit is a separate request to a
  /// rate-limited API, so it is only known when something already had to ask.
  /// Null means "not recorded", never "the default branch".
  final String? commitSha;

  final int total;
  final int outdated;
  final int vulnerable;

  /// Whether any scan has found this state more than once.
  bool get seenAgain => lastSeenAt.isAfter(firstSeenAt);

  factory ReportRevision.fromJson(Map<String, dynamic> json) {
    return ReportRevision(
      id: json['id'] as String,
      projectId: json['projectId'] as String,
      firstSeenAt: DateTime.parse(json['firstSeenAt'] as String),
      lastSeenAt: DateTime.parse(json['lastSeenAt'] as String),
      digest: json['digest'] as String,
      commitSha: json['commitSha'] as String?,
      total: (json['total'] as num?)?.toInt() ?? 0,
      outdated: (json['outdated'] as num?)?.toInt() ?? 0,
      vulnerable: (json['vulnerable'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'projectId': projectId,
        'firstSeenAt': firstSeenAt.toIso8601String(),
        'lastSeenAt': lastSeenAt.toIso8601String(),
        'digest': digest,
        if (commitSha != null) 'commitSha': commitSha,
        'total': total,
        'outdated': outdated,
        'vulnerable': vulnerable,
      };
}
