/// How a dependency is pulled into the project.
enum DepKind { direct, dev, transitive }

/// Whether a newer version exists / a security advisory applies.
enum DepStatus { upToDate, outdated, vulnerable, unknown }

/// A single resolved dependency in a project's tree.
class DepNode {
  const DepNode({
    required this.name,
    required this.kind,
    required this.installed,
    this.constraint,
    this.latest,
    this.status = DepStatus.unknown,
    this.advisories = const [],
    this.dependencies = const [],
  });

  final String name;
  final DepKind kind;

  /// Version currently locked in `pubspec.lock`.
  final String installed;

  /// The constraint from `pubspec.yaml` (null for purely transitive deps).
  final String? constraint;

  /// Latest version on pub.dev, if known.
  final String? latest;

  final DepStatus status;

  /// Security advisory ids affecting [installed], if any.
  final List<String> advisories;

  /// Direct children (names) in the dependency graph.
  final List<String> dependencies;

  factory DepNode.fromJson(Map<String, dynamic> json) {
    return DepNode(
      name: json['name'] as String,
      kind: DepKind.values.byName(json['kind'] as String),
      installed: json['installed'] as String,
      constraint: json['constraint'] as String?,
      latest: json['latest'] as String?,
      status: DepStatus.values.byName(
        (json['status'] as String?) ?? 'unknown',
      ),
      advisories: (json['advisories'] as List?)?.cast<String>() ?? const [],
      dependencies:
          (json['dependencies'] as List?)?.cast<String>() ?? const [],
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'kind': kind.name,
        'installed': installed,
        'constraint': constraint,
        'latest': latest,
        'status': status.name,
        'advisories': advisories,
        'dependencies': dependencies,
      };
}
