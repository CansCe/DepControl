import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:backend/src/services/changelog_reader.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  /// A gzipped tar holding [files].
  List<int> tarGz(Map<String, String> files) {
    final archive = Archive();
    for (final entry in files.entries) {
      final bytes = utf8.encode(entry.value);
      archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
    }
    return GZipEncoder().encode(TarEncoder().encode(archive));
  }

  group('finding the changelog in an archive', () {
    test('at the root, in the usual spelling', () {
      final markdown = ChangelogReader().extractChangelog(
        tarGz({
          'CHANGELOG.md': '## 1.0.0\nFirst.',
          'lib/thing.dart': 'void main() {}',
        }),
        label: 'thing 1.0.0',
      );

      expect(markdown, contains('## 1.0.0'));
    });

    test('under npm\'s package/ wrapper', () {
      // npm archives wrap everything in a directory that is not part of any
      // path the package itself knows.
      final markdown = ChangelogReader().extractChangelog(
        tarGz({'package/CHANGELOG.md': '## 2.0.0\nBreaking.'}),
        label: 'thing 2.0.0',
      );

      expect(markdown, contains('## 2.0.0'));
    });

    test('in the other names projects use', () {
      for (final name in const [
        'CHANGELOG',
        'changelog.md',
        'CHANGES.md',
        'HISTORY.md',
      ]) {
        expect(
          ChangelogReader().extractChangelog(
            tarGz({name: '## 1.0.0\nNotes.'}),
            label: 'thing',
          ),
          contains('## 1.0.0'),
          reason: '$name should be recognised',
        );
      }
    });

    test('not one belonging to something else', () {
      // A changelog under example/ or a bundled dependency is not this
      // package's, and npm archives in particular ship other projects' files.
      final markdown = ChangelogReader().extractChangelog(
        tarGz({
          'example/CHANGELOG.md': '## 9.9.9\nSomebody else.',
          'test/fixtures/CHANGELOG.md': '## 8.8.8\nA fixture.',
        }),
        label: 'thing',
      );

      expect(markdown, isNull);
    });

    test('a package that ships none reads as null, not as an error', () {
      expect(
        ChangelogReader().extractChangelog(
          tarGz({'lib/thing.dart': 'void main() {}'}),
          label: 'thing',
        ),
        isNull,
      );
    });
  });

  group('caps', () {
    test('a changelog past the limit is refused rather than decoded', () {
      final reader = ChangelogReader(maxChangelogBytes: 32);

      expect(
        () => reader.extractChangelog(
          tarGz({'CHANGELOG.md': '#' * 200}),
          label: 'thing',
        ),
        throwsA(isA<ChangelogUnavailable>()),
      );
    });

    test('an archive with too many files is refused', () {
      final reader = ChangelogReader(maxFiles: 3);

      expect(
        () => reader.extractChangelog(
          tarGz({
            for (var i = 0; i < 10; i++) 'lib/file$i.dart': 'x',
          }),
          label: 'thing',
        ),
        throwsA(isA<ChangelogUnavailable>()),
      );
    });

    test('an archive that expands past the limit is refused', () {
      final reader = ChangelogReader(maxDecompressedBytes: 64);

      expect(
        () => reader.extractChangelog(
          tarGz({'lib/big.dart': 'x' * 5000}),
          label: 'thing',
        ),
        throwsA(isA<ChangelogUnavailable>()),
      );
    });

    test('bytes that are not an archive are refused, not crashed on', () {
      expect(
        () => ChangelogReader()
            .extractChangelog(utf8.encode('not an archive'), label: 'thing'),
        throwsA(isA<ChangelogUnavailable>()),
      );
    });
  });

  group('fetching', () {
    ChangelogReader readerServing(
      Map<String, List<int>> bodies, {
      List<Uri>? asked,
    }) =>
        ChangelogReader(
          pubHost: 'pub.test',
          npmHost: 'npm.test',
          client: MockClient((request) async {
            asked?.add(request.url);
            final body = bodies[request.url.path];
            if (body == null) return http.Response('', 404);
            return http.Response.bytes(body, 200);
          }),
        );

    test('constructs the pub.dev archive URL', () async {
      final asked = <Uri>[];
      final reader = readerServing(
        {'/api/archives/http-1.2.0.tar.gz': tarGz({'CHANGELOG.md': '## 1.2.0\nX.'})},
        asked: asked,
      );

      final entries = await reader.read('http', '1.2.0');
      expect(entries.single.version, '1.2.0');
      expect(asked.single.host, 'pub.test');
    });

    test('constructs the npm tarball URL, unscoping the file name', () async {
      // `@babel/core` sits at `/@babel/core/-/core-7.0.0.tgz`.
      final asked = <Uri>[];
      final reader = readerServing(
        {
          '/@babel/core/-/core-7.0.0.tgz':
              tarGz({'package/CHANGELOG.md': '## 7.0.0\nX.'}),
        },
        asked: asked,
      );

      final entries =
          await reader.read('@babel/core', '7.0.0', ecosystem: 'npm');
      expect(entries.single.version, '7.0.0');
      expect(asked.single.path, '/@babel/core/-/core-7.0.0.tgz');
    });

    test('a version that was never published is empty, not an error', () async {
      final reader = readerServing(const {});
      expect(await reader.read('http', '99.0.0'), isEmpty);
    });

    test('a name that is not a package makes no request at all', () async {
      final asked = <Uri>[];
      final reader = readerServing(const {}, asked: asked);

      await expectLater(
        reader.read('../../etc/passwd', '1.0.0'),
        throwsA(isA<ChangelogUnavailable>()),
      );
      expect(asked, isEmpty);
    });

    test('a version that is not a version makes no request either', () async {
      final asked = <Uri>[];
      final reader = readerServing(const {}, asked: asked);

      await expectLater(
        reader.read('http', '../../../secret'),
        throwsA(isA<ChangelogUnavailable>()),
      );
      expect(asked, isEmpty);
    });

    test('an ecosystem with no known archive location refuses', () async {
      await expectLater(
        ChangelogReader().read('thing', '1.0.0', ecosystem: 'cargo'),
        throwsA(isA<ChangelogUnavailable>()),
      );
    });

    test('a compressed body past the cap is refused', () async {
      final reader = ChangelogReader(
        pubHost: 'pub.test',
        maxCompressedBytes: 16,
        client: MockClient(
          (_) async => http.Response.bytes(
            Uint8List(1024),
            200,
          ),
        ),
      );

      await expectLater(
        reader.read('http', '1.0.0'),
        throwsA(isA<ChangelogUnavailable>()),
      );
    });
  });
}
