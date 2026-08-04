import '../ecosystem.dart';

/// Reads which packages JavaScript and TypeScript source reaches for.
///
/// A scanner, not a parser, for the same reason the Dart one is: it reads
/// specifiers, not programs. A regex over comment-stripped source answers
/// "which package names appear in an import" in microseconds per file, where
/// building a module graph for a repository would cost orders of magnitude
/// more to answer the same question.
///
/// Where it errs, it errs towards silence. A missed import costs a suggestion
/// nobody was obliged to take; a claimed import the project does not have is a
/// wrong report, and a wrong report costs the reader's trust in every other
/// line of it.
class JsSourceScanner implements SourceScanner {
  const JsSourceScanner();

  @override
  Set<String> scan(
    Iterable<String> sources, {
    Iterable<String> auxiliary = const [],
  }) {
    final found = <String>{};

    for (final source in sources) {
      final code = _withoutComments(source);
      for (final pattern in _patterns) {
        for (final match in pattern.allMatches(code)) {
          final package = packageOf(match.group(1)!);
          if (package != null) found.add(package);
        }
      }

      // Read from the *raw* source, because a triple-slash directive is a
      // comment — it is the one construction here that means something
      // precisely because of where it sits, and stripping comments first would
      // delete every one of them.
      //
      // The name it carries is not a module specifier: `types="node"` names
      // the `@types/node` package, which is the whole point of the directive.
      // Reading it as a specifier would report a dependency on a package
      // called `node`, and there is one published under that name.
      for (final match in _reference.allMatches(source)) {
        final name = match.group(1)!.trim();
        if (name.isEmpty) continue;
        found.add(name.startsWith('@') ? name : '@types/$name');
      }
    }

    return found;
  }

  /// The package a module specifier names, or null when it names no package.
  ///
  /// Three kinds are not packages and must not be reported as one:
  ///
  /// * relative and absolute paths (`./util`, `../lib/x`, `/etc/thing`) — the
  ///   project's own files;
  /// * Node's built-in modules, with or without the `node:` prefix. `path`,
  ///   `crypto`, `util`, `events` and `stream` are all *also* real packages on
  ///   npm, so importing the builtin and reporting the package would attribute
  ///   a dependency — and its advisories — to a project that has none;
  /// * bare `@scope`, which is not a complete name.
  ///
  /// A subpath is dropped, since `lodash/fp` and `@types/node/fs` are the
  /// `lodash` and `@types/node` packages.
  static String? packageOf(String specifier) {
    var text = specifier.trim();
    if (text.isEmpty) return null;

    if (text.startsWith('node:')) return null;
    if (text.startsWith('.') || text.startsWith('/')) return null;
    // A URL import, and a Windows path that slipped through.
    if (text.contains('://') || text.contains(':\\')) return null;

    // A scoped name keeps two segments; anything else keeps one.
    final segments = text.split('/');
    if (text.startsWith('@')) {
      if (segments.length < 2 || segments[1].isEmpty) return null;
      text = '${segments[0]}/${segments[1]}';
    } else {
      text = segments.first;
    }

    if (text.isEmpty) return null;
    if (_nodeBuiltins.contains(text)) return null;
    return text;
  }

  /// The ways a module specifier is written.
  ///
  /// One pattern per construction rather than one clever alternation, because
  /// each has a different lead-in and reading them separately is how they stay
  /// readable.
  static final _patterns = <RegExp>[
    // `import x from 'pkg'`, `import 'pkg'`, `export * from 'pkg'`.
    RegExp(
      r'''(?:^|[\s;}])(?:import|export)\s*(?:[\w*{}\s,$]*?\s*from\s*)?['"]([^'"]+)['"]''',
      multiLine: true,
    ),
    // `require('pkg')`, and dynamic `import('pkg')`.
    RegExp(r'''(?:^|[^\w.])(?:require|import)\s*\(\s*['"]([^'"]+)['"]\s*\)'''),
  ];

  /// TypeScript's `/// <reference types="pkg" />`, which is how a project
  /// depends on a `@types` package without importing anything from it — the
  /// same shape of problem `analysis_options.yaml` solves for Dart lint sets.
  static final _reference = RegExp(
    r'''<reference\s+types\s*=\s*['"]([^'"]+)['"]''',
  );

  /// Node's built-in modules.
  ///
  /// Kept as a list rather than derived, because the point is the collision
  /// with real npm packages: `path`, `util`, `crypto`, `events`, `stream`,
  /// `url`, `assert`, `buffer`, `process` and `punycode` are all published on
  /// npm by somebody. Treating an import of the builtin as a dependency on the
  /// package would put another author's advisories on this project's report.
  static const _nodeBuiltins = {
    'assert', 'async_hooks', 'buffer', 'child_process', 'cluster', 'console',
    'constants', 'crypto', 'dgram', 'diagnostics_channel', 'dns', 'domain',
    'events', 'fs', 'http', 'http2', 'https', 'inspector', 'module', 'net',
    'os', 'path', 'perf_hooks', 'process', 'punycode', 'querystring',
    'readline', 'repl', 'stream', 'string_decoder', 'sys', 'timers', 'tls',
    'trace_events', 'tty', 'url', 'util', 'v8', 'vm', 'wasi', 'worker_threads',
    'zlib',
  };

  /// Strips comments so an example import in a doc block is not read as one.
  ///
  /// Deliberately naive about strings: a `//` inside a string literal makes
  /// this drop code it should have kept, which costs at most a missed import.
  /// The opposite mistake produces a wrong report.
  static String _withoutComments(String source) {
    var code = source;
    if (code.contains('/*')) code = code.replaceAll(_blockComment, '\n');
    if (code.contains('//')) code = code.replaceAll(_lineComment, '');
    return code;
  }

  static final _blockComment = RegExp(r'/\*.*?\*/', dotAll: true);

  /// A `//` comment, but not the one inside `https://`.
  static final _lineComment = RegExp(r'(?<!:)//[^\n]*');
}
