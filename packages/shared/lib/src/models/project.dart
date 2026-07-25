/// A tracked project, ingested from a Git URL.
class Project {
  const Project({
    required this.id,
    required this.gitUrl,
    required this.name,
    this.ref = 'HEAD',
    this.addedAt,
    this.lastCheckedAt,
  });

  /// Server-assigned identifier.
  final String id;

  /// The Git URL the pubspec files were fetched from.
  final String gitUrl;

  /// Package name from the fetched `pubspec.yaml`.
  final String name;

  /// Branch, tag, or commit fetched. Defaults to the repo's default branch.
  final String ref;

  final DateTime? addedAt;

  /// Last time pub.dev latest-versions were re-checked (Phase 3 drift).
  final DateTime? lastCheckedAt;

  Project copyWith({
    String? name,
    String? ref,
    DateTime? lastCheckedAt,
  }) {
    return Project(
      id: id,
      gitUrl: gitUrl,
      name: name ?? this.name,
      ref: ref ?? this.ref,
      addedAt: addedAt,
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
    );
  }

  factory Project.fromJson(Map<String, dynamic> json) {
    return Project(
      id: json['id'] as String,
      gitUrl: json['gitUrl'] as String,
      name: json['name'] as String,
      ref: (json['ref'] as String?) ?? 'HEAD',
      addedAt: _parseDate(json['addedAt']),
      lastCheckedAt: _parseDate(json['lastCheckedAt']),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'gitUrl': gitUrl,
        'name': name,
        'ref': ref,
        'addedAt': addedAt?.toIso8601String(),
        'lastCheckedAt': lastCheckedAt?.toIso8601String(),
      };
}

DateTime? _parseDate(Object? v) =>
    v is String ? DateTime.tryParse(v) : null;
