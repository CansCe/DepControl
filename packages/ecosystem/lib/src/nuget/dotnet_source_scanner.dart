import '../ecosystem.dart';

/// Reads which packages a .NET project's own source reaches for.
///
/// **A namespace is not a package id**, and this is the one ecosystem here
/// where that gap is wide enough to change the answer. Dart and JavaScript both
/// name the package in the directive — `import 'package:http/http.dart'` says
/// `http` and nothing else. C# says `using Newtonsoft.Json.Linq;`, and the
/// package is `Newtonsoft.Json`.
///
/// So every dotted prefix of a namespace is reported, not just the whole of it:
/// `using Newtonsoft.Json.Linq;` yields `Newtonsoft`, `Newtonsoft.Json` and
/// `Newtonsoft.Json.Linq`. The convention that a package's id is the root of
/// its namespace holds across nearly all of NuGet, so the true package id is
/// one of those prefixes, and the extras match nothing.
///
/// That is deliberately the over-reporting direction. This set is used to
/// decide whether a declared dependency is unused, and both mistakes are not
/// equal: claiming a package is unused when the code uses it through a nested
/// namespace is a wrong answer someone acts on, while carrying a few prefixes
/// that match no package costs nothing. What it does mean is that a package
/// whose id *is* a prefix of an unrelated namespace can be reported as used
/// when it is not — `System.Text.Json` is the realistic case, and it is the
/// price of not accusing every project of shipping dead dependencies.
///
/// F# (`open`) and Visual Basic (`Imports`) are read too. Not for completeness:
/// an ecosystem whose scanner exists but reads none of a project's source
/// returns the *empty* set rather than null, and empty means "a scan ran and
/// found nothing", which reports every dependency of every F# project as
/// unused. A scanner that covers one language of three is worse than no
/// scanner at all.
class DotNetSourceScanner implements SourceScanner {
  const DotNetSourceScanner();

  @override
  Set<String> scan(
    Iterable<String> sources, {
    Iterable<String> auxiliary = const [],
  }) {
    final found = <String>{};
    for (final source in sources) {
      final code = _withoutBlockComments(source);
      for (final pattern in _directives) {
        for (final match in pattern.allMatches(code)) {
          _addPrefixes(found, match.group(1)!);
        }
      }
    }
    return found;
  }

  /// Every dotted prefix of [namespace], longest included.
  static void _addPrefixes(Set<String> into, String namespace) {
    final parts = namespace.split('.');
    final buffer = StringBuffer();
    for (final part in parts) {
      if (part.isEmpty) return; // `A..B` is not a namespace
      if (buffer.isNotEmpty) buffer.write('.');
      buffer.write(part);
      into.add(buffer.toString());
    }
  }

  /// C# `using X;`, `global using X;`, `using static X.Y;` and the alias form
  /// `using J = Newtonsoft.Json;` — the alias is discarded and the namespace it
  /// points at is what counts.
  ///
  /// Anchored to the start of a line so a `//`-commented directive cannot
  /// match, which is why only block comments are stripped below. `using (var x
  /// = ...)`, the statement, is excluded by requiring an identifier rather than
  /// a parenthesis after the keyword.
  static final _using = RegExp(
    r'''^\s*(?:global\s+)?using\s+(?:static\s+)?'''
    r'''(?:[A-Za-z_@][\w]*\s*=\s*)?'''
    r'''([A-Za-z_@][\w]*(?:\.[A-Za-z_@][\w]*)*)\s*;''',
    multiLine: true,
  );

  /// F#: `open Newtonsoft.Json`, with no terminator.
  static final _open = RegExp(
    r'''^\s*open\s+(?:type\s+)?([A-Za-z_][\w]*(?:\.[A-Za-z_][\w]*)*)\s*$''',
    multiLine: true,
  );

  /// Visual Basic: `Imports Newtonsoft.Json`, also unterminated.
  static final _imports = RegExp(
    r'''^\s*Imports\s+([A-Za-z_][\w]*(?:\.[A-Za-z_][\w]*)*)\s*$''',
    multiLine: true,
  );

  static final _directives = [_using, _open, _imports];

  /// As the Dart scanner: a licence header or doc comment can hold an example
  /// directive, and the line-anchored patterns would match it inside a block
  /// comment. Naive on purpose — dropping code it should have kept costs at
  /// most a missed namespace, while the opposite mistake produces a wrong
  /// report.
  static String _withoutBlockComments(String source) =>
      source.contains('/*') ? source.replaceAll(_blockComment, '\n') : source;

  static final _blockComment = RegExp(r'/\*.*?\*/', dotAll: true);
}
