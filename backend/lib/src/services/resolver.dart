import 'dart:io';

import 'package:shared/shared.dart';

import 'git_fetcher.dart';

/// Simulates a dependency change by running pub's real resolver in a
/// sandboxed temp dir with `--dry-run` (Phase 2).
///
/// `--dry-run` reports what *would* change without writing files or executing
/// build hooks / `dart run`, which keeps arbitrary fetched pubspecs safe-ish.
/// Still run this inside a locked-down container.
class Resolver {
  const Resolver();

  Future<ResolutionResult> simulate(
    FetchedPubspecs files,
    ResolutionRequest request,
  ) async {
    final dir = await Directory.systemTemp.createTemp('depcontrol_resolve_');
    try {
      final patched = _applyChange(files.pubspecYaml, request);
      await File('${dir.path}/pubspec.yaml').writeAsString(patched);
      if (files.hasLock) {
        await File('${dir.path}/pubspec.lock')
            .writeAsString(files.pubspecLock!);
      }

      final result = await Process.run(
        'dart',
        ['pub', 'upgrade', '--dry-run'],
        workingDirectory: dir.path,
      );

      final out = '${result.stdout}\n${result.stderr}'.trim();
      if (result.exitCode == 0) {
        return ResolutionResult(
          request: request,
          success: true,
          changes: _parseChanges(out),
          rawOutput: out,
        );
      }
      return ResolutionResult(
        request: request,
        success: false,
        conflict: _extractConflict(out),
        rawOutput: out,
      );
    } finally {
      await dir.delete(recursive: true);
    }
  }

  /// Rewrites the target dependency's constraint in the raw yaml.
  /// TODO(phase2): use a yaml editor to preserve formatting robustly.
  String _applyChange(String yaml, ResolutionRequest req) {
    final line = RegExp('^(\\s+)${RegExp.escape(req.package)}:.*\$',
        multiLine: true);
    if (line.hasMatch(yaml)) {
      return yaml.replaceFirstMapped(
        line,
        (m) => '${m.group(1)}${req.package}: ${req.targetConstraint}',
      );
    }
    // Not present: append under dependencies (naive; Phase 2 hardens this).
    return yaml.replaceFirst(
      RegExp(r'^dependencies:\s*$', multiLine: true),
      'dependencies:\n  ${req.package}: ${req.targetConstraint}',
    );
  }

  /// Parses lines like `> http 1.2.0 (was 1.1.0)` from pub output.
  List<VersionChange> _parseChanges(String output) {
    final re = RegExp(
      r'^[>+~]\s+(\S+)\s+(\S+)(?:\s+\(was\s+(\S+)\))?',
      multiLine: true,
    );
    return re.allMatches(output).map((m) {
      return VersionChange(
        package: m.group(1)!,
        from: m.group(3),
        to: m.group(2),
      );
    }).toList();
  }

  String _extractConflict(String output) {
    final idx = output.indexOf('version solving failed');
    return idx >= 0 ? output.substring(idx) : output;
  }
}
