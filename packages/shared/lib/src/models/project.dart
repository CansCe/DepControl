/// Where a project's manifests come from.
///
/// Two answers, and the difference is not cosmetic: a [git] project can be
/// re-read whenever the server likes, and a [local] one cannot be read again
/// without the person who collected it. That decides what a refresh means, what
/// freshness means, and which of the two the server is allowed to go and fetch.
enum ProjectSource {
  /// Fetched from a public forge by URL. What every project was before the
  /// local collector existed.
  git,

  /// Uploaded as a bundle by `depcontrol collect`, from a repository this
  /// server cannot reach — Azure DevOps, GitHub Enterprise, an internal GitLab,
  /// or anything behind a VPN.
  local;

  static ProjectSource parse(String? raw) => ProjectSource.values.firstWhere(
        (s) => s.name == raw,
        orElse: () => ProjectSource.git,
      );
}

/// A tracked project, ingested from a Git URL or from a collected bundle.
class Project {
  const Project({
    required this.id,
    required this.name,
    this.gitUrl,
    this.source = ProjectSource.git,
    this.ownerId,
    this.ref = 'HEAD',
    this.addedAt,
    this.lastCheckedAt,
    this.bundleCollectedAt,
    this.archivedAt,
  });

  /// Server-assigned identifier.
  final String id;

  /// The Git URL the manifests were fetched from, or null for a [source] of
  /// [ProjectSource.local].
  ///
  /// Nullable rather than an empty string, because "there is no URL" is a fact
  /// about this project and not a missing value. A local project's repository
  /// exists somewhere this server has never been told about and never will be —
  /// deliberately, since a URL is the one thing about a private repository that
  /// would let a hosted service try to reach it.
  final String? gitUrl;

  final ProjectSource source;

  /// Package name from the fetched manifest, or from the bundle's root package.
  final String name;

  /// Supabase user id (JWT `sub`) of the user who added this project.
  ///
  /// Null only for projects constructed client-side before the server assigns
  /// ownership; every persisted project has one.
  final String? ownerId;

  /// Branch, tag, or commit fetched. Defaults to the repo's default branch, and
  /// means nothing for a local project.
  final String ref;

  final DateTime? addedAt;

  /// Last time the server looked, which for a local project means last time it
  /// re-queried the registries rather than last time it read the repository.
  final DateTime? lastCheckedAt;

  /// When the bundle behind a local project was collected, **by the clock of
  /// the machine that collected it**.
  ///
  /// This is a local project's real freshness and it is not the same claim
  /// [lastCheckedAt] makes. The server can re-query advisories nightly against
  /// stored versions, so a local project's *advisories* stay current while its
  /// *dependencies* are as old as the last time somebody ran `collect`. A UI
  /// that showed only the server's timestamp would present a six-month-old
  /// dependency list as though it were checked this morning — which is the one
  /// genuinely misleading thing this feature could do.
  ///
  /// Self-reported, so a timestamp in the future says the clock is wrong, not
  /// that the bundle is fresh.
  final DateTime? bundleCollectedAt;

  /// When this project was archived, or null while it is active.
  ///
  /// Archiving keeps the project and its report and takes it out of the way;
  /// it is the reversible half of "stop showing me this". Deleting is the other
  /// half and keeps nothing.
  final DateTime? archivedAt;

  bool get isArchived => archivedAt != null;

  /// Whether this project's repository is one the server can go and read.
  bool get isLocal => source == ProjectSource.local;

  Project copyWith({
    String? name,
    String? ref,
    DateTime? lastCheckedAt,
    DateTime? bundleCollectedAt,
    DateTime? archivedAt,
    bool clearArchivedAt = false,
  }) {
    return Project(
      id: id,
      gitUrl: gitUrl,
      source: source,
      name: name ?? this.name,
      ownerId: ownerId,
      ref: ref ?? this.ref,
      addedAt: addedAt,
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
      bundleCollectedAt: bundleCollectedAt ?? this.bundleCollectedAt,
      archivedAt: clearArchivedAt ? null : (archivedAt ?? this.archivedAt),
    );
  }

  factory Project.fromJson(Map<String, dynamic> json) {
    final gitUrl = json['gitUrl'] as String?;
    return Project(
      id: json['id'] as String,
      gitUrl: gitUrl,
      // Absent on every project stored before local ones existed, and every one
      // of those was fetched from a URL. Read from the URL rather than defaulted
      // blindly, so a row that somehow has neither is not called a git project.
      source: json['source'] == null
          ? (gitUrl == null ? ProjectSource.local : ProjectSource.git)
          : ProjectSource.parse(json['source'] as String?),
      name: json['name'] as String,
      ownerId: json['ownerId'] as String?,
      ref: (json['ref'] as String?) ?? 'HEAD',
      addedAt: _parseDate(json['addedAt']),
      lastCheckedAt: _parseDate(json['lastCheckedAt']),
      bundleCollectedAt: _parseDate(json['bundleCollectedAt']),
      archivedAt: _parseDate(json['archivedAt']),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'gitUrl': gitUrl,
        'source': source.name,
        'name': name,
        'ownerId': ownerId,
        'ref': ref,
        'addedAt': addedAt?.toIso8601String(),
        'lastCheckedAt': lastCheckedAt?.toIso8601String(),
        'bundleCollectedAt': bundleCollectedAt?.toIso8601String(),
        'archivedAt': archivedAt?.toIso8601String(),
      };
}

DateTime? _parseDate(Object? v) =>
    v is String ? DateTime.tryParse(v) : null;
