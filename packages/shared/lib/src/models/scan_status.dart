import 'scan_progress.dart';

/// Where a scan sits in the server's queue.
///
/// Distinct from [ScanProgress.phase], which says what the scan is *doing*.
/// The two answer different questions and only overlap at the end: a job in
/// [running] may be fetching, resolving, analyzing or saving, and the phase is
/// what a person watching wants to read. The state is what the queue reasons
/// about — which job to pick up next, and which one a machine died holding.
enum ScanJobState {
  /// Written down and waiting. Nothing has started, and nothing is lost if this
  /// machine goes away.
  queued,

  /// Claimed by a worker, which is expected to keep saying so.
  running,

  done,
  failed;

  bool get isFinished => this == done || this == failed;

  static ScanJobState parse(String? raw) => ScanJobState.values.firstWhere(
        (s) => s.name == raw,
        orElse: () => ScanJobState.queued,
      );
}

/// A scan as the server can describe it to whoever asked for one.
///
/// This is what `GET /scans/<id>` answers with, and it exists because a scan
/// stopped being a request. Once the work outlives the connection that asked
/// for it, the client needs three things it used to get from the response body:
/// whether the work is still going, how far it has got, and — for a scan that
/// created something — what it created.
class ScanStatus {
  const ScanStatus({
    required this.scanId,
    required this.state,
    required this.progress,
    this.gitUrl,
    this.projectId,
    this.error,
  });

  final String scanId;
  final ScanJobState state;

  /// What the scan is doing, or last said it was doing.
  final ScanProgress progress;

  /// What is being scanned.
  ///
  /// Here because a client re-attaching to a scan it did not start has nothing
  /// else to call it: an add has no project yet, so the repository URL is the
  /// only name the panel can show. Null only when read from an older server.
  final String? gitUrl;

  /// The project this scan produced or refreshed, once there is one.
  ///
  /// Null for an add that has not finished: a project is not created until its
  /// first report exists, so that a git URL nobody can clone does not leave an
  /// empty project behind.
  final String? projectId;

  /// Why the scan failed, when it did.
  ///
  /// Held here rather than read from [progress] because a job can fail without
  /// the scan ever reporting anything — one abandoned by a machine that died
  /// before it wrote a single phase.
  final String? error;

  bool get isFinished => state.isFinished;

  Map<String, dynamic> toJson() => {
        'scanId': scanId,
        'state': state.name,
        'progress': progress.toJson(),
        if (gitUrl != null) 'gitUrl': gitUrl,
        if (projectId != null) 'projectId': projectId,
        if (error != null) 'error': error,
      };

  factory ScanStatus.fromJson(Map<String, dynamic> json) {
    final raw = json['progress'];
    return ScanStatus(
      scanId: json['scanId'] as String? ?? '',
      state: ScanJobState.parse(json['state'] as String?),
      // Tolerates the older shape, where this route answered with a bare
      // ScanProgress and there was no job behind it.
      progress: ScanProgress.fromJson(
        raw is Map<String, dynamic> ? raw : json,
      ),
      gitUrl: json['gitUrl'] as String?,
      projectId: json['projectId'] as String?,
      error: json['error'] as String?,
    );
  }
}
