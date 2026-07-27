import 'package:api_differ/api_differ.dart';
import 'package:test/test.dart';

void main() {
  group('extractSurface', () {
    test('collects public top-level declarations', () {
      final surface = extractSurface({
        'lib/demo.dart': '''
String greet(int times) => 'hi';
const answer = 42;
typedef Handler = void Function(String);
enum Mode { fast, slow }
''',
      });

      expect(surface.keys, contains('greet'));
      expect(surface['greet'], 'String (int times)');
      expect(surface.keys, contains('answer'));
      expect(surface.keys, contains('typedef Handler'));
      expect(surface['enum Mode'], 'fast, slow');
    });

    test('ignores anything private', () {
      final surface = extractSurface({
        'lib/demo.dart': '''
void _hidden() {}
class _Secret {}
class Visible {
  void _internal() {}
  void shown() {}
  int _count = 0;
}
''',
      });

      expect(surface.keys, isNot(contains('_hidden')));
      expect(surface.keys, isNot(contains('class _Secret')));
      expect(surface.keys, contains('class Visible'));
      expect(surface.keys, contains('Visible.shown'));
      expect(surface.keys, isNot(contains('Visible._internal')));
      expect(surface.keys, isNot(contains('Visible._count')));
    });

    test('records members, constructors and getters', () {
      final surface = extractSurface({
        'lib/demo.dart': '''
class Client {
  Client(this.url);
  Client.timeout(this.url, Duration d);
  final String url;
  String get host => '';
  Future<void> send(String body, {int retries = 0}) async {}
}
''',
      });

      expect(surface['Client.new'], '(this.url)');
      expect(surface['Client.timeout'], '(this.url, Duration d)');
      expect(surface['Client.url'], 'String');
      expect(surface['Client.host'], 'String get');
      expect(surface['Client.send'], 'Future<void> (String body, {int retries = 0})');
    });

    test('marks abstract classes distinctly', () {
      final surface = extractSurface({
        'lib/demo.dart': 'abstract class Base {}\nclass Impl {}',
      });

      expect(surface.keys, contains('abstract class Base'));
      expect(surface.keys, contains('class Impl'));
    });

    // lib/src is implementation detail; it only counts when exported.
    test('skips lib/src that no entry point exports', () {
      final surface = extractSurface({
        'lib/demo.dart': 'class Public {}',
        'lib/src/internal.dart': 'class Internal {}',
      });

      expect(surface.keys, contains('class Public'));
      expect(surface.keys, isNot(contains('class Internal')));
    });

    test('follows exports into lib/src', () {
      final surface = extractSurface({
        'lib/demo.dart': "export 'src/client.dart';",
        'lib/src/client.dart': 'class Client {}',
      });

      expect(surface.keys, contains('class Client'));
    });

    test('follows exports transitively', () {
      final surface = extractSurface({
        'lib/demo.dart': "export 'src/a.dart';",
        'lib/src/a.dart': "export 'b.dart';\nclass A {}",
        'lib/src/b.dart': 'class B {}',
      });

      expect(surface.keys, containsAll(['class A', 'class B']));
    });

    test('ignores package: and dart: exports', () {
      final surface = extractSurface({
        'lib/demo.dart': "export 'dart:async';\nexport 'package:http/http.dart';",
      });

      expect(surface, isEmpty);
    });

    test('an unparseable file does not lose the package', () {
      final surface = extractSurface({
        'lib/demo.dart': 'class Good {}',
        'lib/broken.dart': 'class {{{ not dart',
      });

      expect(surface.keys, contains('class Good'));
    });
  });

  group('diffSurfaces', () {
    test('reports a removed declaration', () {
      final changes = diffSurfaces({'Client.send': 'void ()'}, {});

      expect(changes.single.kind, ApiChangeKind.removed);
      expect(changes.single.declaration, 'Client.send');
      expect(changes.single.before, 'void ()');
    });

    test('reports a changed signature', () {
      final changes = diffSurfaces(
        {'Client.send': 'void (String)'},
        {'Client.send': 'void (Uri)'},
      );

      expect(changes.single.kind, ApiChangeKind.changed);
      expect(changes.single.before, 'void (String)');
      expect(changes.single.after, 'void (Uri)');
    });

    test('reports an addition', () {
      final changes = diffSurfaces({}, {'Client.retry': 'void ()'});

      expect(changes.single.kind, ApiChangeKind.added);
    });

    test('says nothing when the surface is identical', () {
      final surface = {'Client.send': 'void ()'};
      expect(diffSurfaces(surface, {...surface}), isEmpty);
    });

    test('orders removals before changes before additions', () {
      final changes = diffSurfaces(
        {'gone': 'a', 'moved': 'a'},
        {'moved': 'b', 'fresh': 'c'},
      );

      expect(
        changes.map((c) => c.kind).toList(),
        [ApiChangeKind.removed, ApiChangeKind.changed, ApiChangeKind.added],
      );
    });
  });

  group('PubArchiveClient input validation', () {
    final client = PubArchiveClient();

    test('refuses a package name that is not an identifier', () {
      expect(
        () => client.libSources('../etc/passwd', '1.0.0'),
        throwsA(isA<ArchiveRejected>()),
      );
    });

    test('refuses a version with path characters', () {
      expect(
        () => client.libSources('http', '../../1.0.0'),
        throwsA(isA<ArchiveRejected>()),
      );
    });

    test('refuses a name with a slash', () {
      expect(
        () => client.libSources('a/b', '1.0.0'),
        throwsA(isA<ArchiveRejected>()),
      );
    });

    test('rejects bytes that are not an archive', () {
      expect(
        () => client.readLibSources(
          List<int>.filled(64, 0),
          label: 'bogus',
        ),
        throwsA(isA<ArchiveRejected>()),
      );
    });
  });
}
