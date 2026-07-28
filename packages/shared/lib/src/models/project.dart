/// A tracked project, ingested from a Git URL.
class Project {
  const Project({
    required this.id,
    required this.gitUrl,
    required this.name,
    this.ownerId,
    this.ref = 'HEAD',
    this.addedAt,
    this.lastCheckedAt,
    this.archivedAt,
  });

  /// Server-assigned identifier.
  final String id;

  /// The Git URL the pubspec files were fetched from.
  final String gitUrl;

  /// Package name from the fetched `pubspec.yaml`.
  final String name;

  /// Supabase user id (JWT `sub`) of the user who added this project.
  ///
  /// Null only for projects constructed client-side before the server assigns
  /// ownership; every persisted project has one.
  final String? ownerId;

  /// Branch, tag, or commit fetched. Defaults to the repo's default branch.
  final String ref;

  final DateTime? addedAt;

  /// Last time pub.dev latest-versions were re-checked (Phase 3 drift).
  final DateTime? lastCheckedAt;

  /// When this project was archived, or null while it is active.
  ///
  /// Archiving keeps the project and its report and takes it out of the way;
  /// it is the reversible half of "stop showing me this". Deleting is the other
  /// half and keeps nothing.
  final DateTime? archivedAt;

  bool get isArchived => archivedAt != null;

  Project copyWith({
    String? name,
    String? ref,
    DateTime? lastCheckedAt,
    DateTime? archivedAt,
    bool clearArchivedAt = false,
  }) {
    return Project(
      id: id,
      gitUrl: gitUrl,
      name: name ?? this.name,
      ownerId: ownerId,
      ref: ref ?? this.ref,
      addedAt: addedAt,
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
      archivedAt: clearArchivedAt ? null : (archivedAt ?? this.archivedAt),
    );
  }

  factory Project.fromJson(Map<String, dynamic> json) {
    return Project(
      id: json['id'] as String,
      gitUrl: json['gitUrl'] as String,
      name: json['name'] as String,
      ownerId: json['ownerId'] as String?,
      ref: (json['ref'] as String?) ?? 'HEAD',
      addedAt: _parseDate(json['addedAt']),
      lastCheckedAt: _parseDate(json['lastCheckedAt']),
      archivedAt: _parseDate(json['archivedAt']),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'gitUrl': gitUrl,
        'name': name,
        'ownerId': ownerId,
        'ref': ref,
        'addedAt': addedAt?.toIso8601String(),
        'lastCheckedAt': lastCheckedAt?.toIso8601String(),
        'archivedAt': archivedAt?.toIso8601String(),
      };
}

DateTime? _parseDate(Object? v) =>
    v is String ? DateTime.tryParse(v) : null;
