/// Where a pairing session sits, from the web page that minted it.
enum CollectorSessionState {
  /// Minted, nobody has claimed it yet.
  waiting,

  /// A collector posted a bundle against this code. [CollectorSession.scanId]
  /// is set, and the page can hand off straight to the existing scan overlay.
  claimed,

  /// The code's fifteen minutes ran out before anyone used it.
  ///
  /// Distinct from [waiting] so the page can say the code died rather than
  /// going on describing itself as still open — the one genuinely misleading
  /// state this flow could be left in.
  expired;

  static CollectorSessionState parse(String? raw) =>
      CollectorSessionState.values.firstWhere(
        (s) => s.name == raw,
        orElse: () => CollectorSessionState.waiting,
      );
}

/// A one-shot grant to submit exactly one bundle for one user.
///
/// Not a credential that can read anything — see the disclosure note in the
/// README. The code itself travels only in the mint response
/// (`POST /collector/sessions`); everything read back through
/// `GET /collector/sessions/<id>` is this, and it never carries the code.
class CollectorSession {
  const CollectorSession({
    required this.id,
    required this.state,
    required this.expiresAt,
    this.projectId,
    this.scanId,
  });

  final String id;
  final CollectorSessionState state;
  final DateTime expiresAt;

  /// Set when this session re-uploads to an existing project rather than
  /// creating one. Mirrors the two ingest routes: null is `POST /projects`,
  /// set is `POST /projects/<id>/bundle`.
  final String? projectId;

  /// The scan the claim enqueued, once there is one. This is what lets the
  /// page that minted the code hand off to `ScanQueue.reattach` with nothing
  /// more to ask the server.
  final String? scanId;

  Map<String, dynamic> toJson() => {
        'id': id,
        'state': state.name,
        'expiresAt': expiresAt.toUtc().toIso8601String(),
        if (projectId != null) 'projectId': projectId,
        if (scanId != null) 'scanId': scanId,
      };

  factory CollectorSession.fromJson(Map<String, dynamic> json) =>
      CollectorSession(
        id: json['id'] as String? ?? '',
        state: CollectorSessionState.parse(json['state'] as String?),
        expiresAt: DateTime.tryParse(json['expiresAt'] as String? ?? '')
                ?.toUtc() ??
            DateTime.now().toUtc(),
        projectId: json['projectId'] as String?,
        scanId: json['scanId'] as String?,
      );
}
