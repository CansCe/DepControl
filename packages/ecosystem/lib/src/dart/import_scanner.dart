/// Reads which packages a project's own source actually reaches for.
///
/// A pubspec says what a project is *allowed* to use. Only the source says what
/// it *does* use, and the gap between the two is where two ordinary bugs live:
///
/// * a declared dependency nothing imports — dead weight in the lockfile, and
///   one more package whose advisories somebody has to triage;
/// * an imported package nothing declares — it resolves today only because some
///   other dependency happens to pull it in, and stops resolving the moment
///   that one drops it. Nothing about the pubspec warns you first.
///
/// This is a scanner, not a parser. It reads directives, not programs: a regex
/// over comment-stripped source is enough to answer "which package names appear
/// in an import", and it costs a few microseconds per file instead of building
/// an element model for a whole repository.
class ImportScanner {
  const ImportScanner._();

  /// Package names imported or exported by [sources].
  ///
  /// [sources] is Dart source text; [optionsFiles] is `analysis_options.yaml`
  /// content, which references packages through `include:` rather than an
  /// import and is the only reason `lints` is not reported as unused by every
  /// project that uses it.
  static Set<String> scan(
    Iterable<String> sources, {
    Iterable<String> optionsFiles = const [],
  }) {
    final found = <String>{};
    for (final source in sources) {
      final code = _withoutBlockComments(source);
      for (final match in _directive.allMatches(code)) {
        found.add(match.group(1)!);
      }
      // Conditional imports name a second package inside `if (...)`, which the
      // directive pattern stops before: `import 'stub.dart'
      // if (dart.library.io) 'package:x/io.dart';` genuinely depends on `x`.
      for (final match in _conditional.allMatches(code)) {
        found.add(match.group(1)!);
      }
    }

    for (final options in optionsFiles) {
      for (final match in _include.allMatches(options)) {
        found.add(match.group(1)!);
      }
    }

    return found;
  }

  /// An `import` or `export` directive naming a `package:` URI.
  ///
  /// Anchored to the start of a line so a `//`-commented directive cannot
  /// match — which is why only block comments need stripping below.
  ///
  /// `part of 'package:...'` is not read: it always names the enclosing library
  /// and so can only ever report a package as depending on itself.
  static final _directive = RegExp(
    r'''^\s*(?:import|export)\s+['"]package:([a-z_][a-z0-9_]*)/''',
    multiLine: true,
  );

  /// The `if (...) 'package:x/y.dart'` half of a conditional import.
  static final _conditional = RegExp(
    r'''\)\s*['"]package:([a-z_][a-z0-9_]*)/''',
  );

  /// An `include: package:lints/recommended.yaml` line in analysis options.
  static final _include = RegExp(
    r'''^\s*include:\s*['"]?package:([a-z_][a-z0-9_]*)/''',
    multiLine: true,
  );

  /// A doc comment or licence header can contain an example import, and the
  /// line-anchored pattern above would happily match it inside a `/* */` block.
  ///
  /// Deliberately naive: a `/*` inside a string literal makes this drop code it
  /// should have kept, which costs at most a missed import in a file that also
  /// contains the real one somewhere else. The opposite mistake — claiming an
  /// import a project does not have — is the one that produces a wrong report.
  static String _withoutBlockComments(String source) =>
      source.contains('/*') ? source.replaceAll(_blockComment, '\n') : source;

  static final _blockComment = RegExp(r'/\*.*?\*/', dotAll: true);
}
