import 'package:backend/src/services/import_scanner.dart';
import 'package:test/test.dart';

void main() {
  group('directives', () {
    test('reads imports and exports, ignoring dart: and relative URIs', () {
      final found = ImportScanner.scan([
        '''
import 'dart:async';
import 'package:http/http.dart' as http;
import '../src/thing.dart';
export 'package:shared/shared.dart';

void main() {}
''',
      ]);

      expect(found, {'http', 'shared'});
    });

    test('reads the package named inside a conditional import', () {
      final found = ImportScanner.scan([
        "import 'stub.dart'\n"
            "    if (dart.library.io) 'package:crypto/crypto.dart'\n"
            "    if (dart.library.js) 'package:web/web.dart';\n",
      ]);

      expect(found, {'crypto', 'web'});
    });

    test('unions across files', () {
      final found = ImportScanner.scan([
        "import 'package:a/a.dart';\n",
        "import 'package:b/b.dart';\nimport 'package:a/a.dart';\n",
      ]);

      expect(found, {'a', 'b'});
    });
  });

  // A false import is worse than a missed one: it turns into a claim that the
  // project depends on something undeclared, which sends someone editing a
  // pubspec for no reason.
  group('things that only look like imports', () {
    test('ignores a commented-out import', () {
      final found = ImportScanner.scan([
        "// import 'package:ghost/ghost.dart';\n"
            "  //import 'package:ghost2/ghost2.dart';\n"
            "import 'package:real/real.dart';\n",
      ]);

      expect(found, {'real'});
    });

    test('ignores an import inside a doc or licence block', () {
      final found = ImportScanner.scan([
        '''
/*
 * Usage:
 * import 'package:example/example.dart';
 */
import 'package:real/real.dart';
''',
      ]);

      expect(found, {'real'});
    });

    test('ignores a package URI in a string literal mid-file', () {
      final found = ImportScanner.scan([
        "const uri = 'package:not_imported/x.dart';\n"
            "import 'package:real/real.dart';\n",
      ]);

      expect(found, {'real'});
    });
  });

  group('analysis options', () {
    // Without this, every project that uses a lint set gets told to delete it.
    test('reads a package: include', () {
      final found = ImportScanner.scan(
        const [],
        optionsFiles: ['include: package:lints/recommended.yaml\n'],
      );

      expect(found, {'lints'});
    });

    test('reads a quoted include', () {
      final found = ImportScanner.scan(
        const [],
        optionsFiles: ['include: "package:very_good_analysis/analysis.yaml"\n'],
      );

      expect(found, {'very_good_analysis'});
    });

    test('ignores a relative include', () {
      final found = ImportScanner.scan(
        const [],
        optionsFiles: ['include: ../analysis_options.yaml\n'],
      );

      expect(found, isEmpty);
    });
  });

  test('a file with no imports scans to nothing rather than failing', () {
    expect(ImportScanner.scan(['void main() {}\n']), isEmpty);
  });
}
