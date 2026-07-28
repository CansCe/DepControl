/// What happened to one public declaration between two versions.
enum ApiChangeKind {
  /// Gone in the newer version. Calling code referring to it will not compile.
  removed,

  /// Still there under a different signature.
  changed,

  /// New in the newer version. Never a reason an upgrade fails.
  added,
}

/// One difference in a package's public API.
class ApiChange {
  const ApiChange({
    required this.kind,
    required this.declaration,
    this.before,
    this.after,
  });

  final ApiChangeKind kind;

  /// Qualified name, e.g. `Client.send`, `class Pair` or `enum Style`.
  final String declaration;

  /// Signature in the older version, null when the declaration is new.
  final String? before;

  /// Signature in the newer version, null when it was removed.
  final String? after;

  factory ApiChange.fromJson(Map<String, dynamic> json) => ApiChange(
        kind: ApiChangeKind.values.byName(json['kind'] as String),
        declaration: json['declaration'] as String,
        before: json['before'] as String?,
        after: json['after'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'declaration': declaration,
        'before': before,
        'after': after,
      };
}

/// How a package's public API differs between two published versions.
///
/// This is the one question semver cannot answer: a major bump says the author
/// considers something breaking, but not whether the declarations your code
/// calls are still there. These changes are read out of the packages' own
/// sources.
///
/// Produced out of process by `tools/api_differ` and stored; the API only ever
/// serves diffs that tool already wrote. It deliberately lives outside this pub
/// workspace — parsing Dart needs an analyzer version this workspace cannot
/// resolve — so it cannot be depended on from here, and **this JSON shape is
/// the contract between the two**. `tools/api_differ` has a test pinning the
/// keys it emits, and [ApiDiff.fromJson] is tested against a recorded sample of
/// its output.
///
/// Note what this still does not know: whether the project actually uses any of
/// these declarations. It narrows "something might break" to "these specific
/// things changed", which is as far as published sources can take it.
class ApiDiff {
  const ApiDiff({
    required this.package,
    required this.from,
    required this.to,
    this.changes = const [],
    this.generatedAt,
  });

  final String package;
  final String from;
  final String to;
  final List<ApiChange> changes;

  /// When the comparison was made. Absent in the differ's own output — it is
  /// stamped on ingest, since only the store knows how old its copy is.
  final DateTime? generatedAt;

  /// Declarations that disappeared, the ones that stop calling code compiling.
  List<ApiChange> get removed =>
      changes.where((c) => c.kind == ApiChangeKind.removed).toList();

  /// Declarations that survived under a different signature.
  List<ApiChange> get changed =>
      changes.where((c) => c.kind == ApiChangeKind.changed).toList();

  List<ApiChange> get added =>
      changes.where((c) => c.kind == ApiChangeKind.added).toList();

  /// Whether anything here could stop existing code compiling. Additions alone
  /// are not worth showing.
  bool get hasBreakingChanges =>
      changes.any((c) => c.kind != ApiChangeKind.added);

  factory ApiDiff.fromJson(Map<String, dynamic> json) => ApiDiff(
        package: json['package'] as String,
        from: json['from'] as String,
        to: json['to'] as String,
        changes: ((json['changes'] as List?) ?? const [])
            .map((e) => ApiChange.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
        generatedAt: switch (json['generatedAt']) {
          final String at => DateTime.tryParse(at),
          _ => null,
        },
      );

  Map<String, dynamic> toJson() => {
        'package': package,
        'from': from,
        'to': to,
        'changes': changes.map((c) => c.toJson()).toList(),
        if (generatedAt != null)
          'generatedAt': generatedAt!.toUtc().toIso8601String(),
      };
}
