/// A proposed change fed into the resolver (Phase 2).
class ResolutionRequest {
  const ResolutionRequest({
    required this.package,
    required this.targetConstraint,
  });

  final String package;

  /// e.g. `^2.0.0`, `any`, or a pinned `1.4.2`.
  final String targetConstraint;

  factory ResolutionRequest.fromJson(Map<String, dynamic> json) =>
      ResolutionRequest(
        package: json['package'] as String,
        targetConstraint: json['targetConstraint'] as String,
      );

  Map<String, dynamic> toJson() => {
        'package': package,
        'targetConstraint': targetConstraint,
      };
}

/// One package's before/after in a simulated resolution.
class VersionChange {
  const VersionChange({
    required this.package,
    required this.from,
    required this.to,
  });

  final String package;
  final String? from; // null => newly added
  final String? to; // null => removed

  factory VersionChange.fromJson(Map<String, dynamic> json) => VersionChange(
        package: json['package'] as String,
        from: json['from'] as String?,
        to: json['to'] as String?,
      );

  Map<String, dynamic> toJson() =>
      {'package': package, 'from': from, 'to': to};
}

/// Outcome of simulating a [ResolutionRequest].
class ResolutionResult {
  const ResolutionResult({
    required this.request,
    required this.success,
    this.changes = const [],
    this.conflict,
    this.rawOutput,
  });

  final ResolutionRequest request;

  /// Whether pub could resolve the proposed change.
  final bool success;

  /// Version deltas when [success] is true.
  final List<VersionChange> changes;

  /// Human-readable conflict explanation when [success] is false.
  final String? conflict;

  /// Raw resolver output, for debugging / display.
  final String? rawOutput;

  factory ResolutionResult.fromJson(Map<String, dynamic> json) =>
      ResolutionResult(
        request: ResolutionRequest.fromJson(
          json['request'] as Map<String, dynamic>,
        ),
        success: json['success'] as bool,
        changes: (json['changes'] as List?)
                ?.map((e) => VersionChange.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        conflict: json['conflict'] as String?,
        rawOutput: json['rawOutput'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'request': request.toJson(),
        'success': success,
        'changes': changes.map((c) => c.toJson()).toList(),
        'conflict': conflict,
        'rawOutput': rawOutput,
      };
}
