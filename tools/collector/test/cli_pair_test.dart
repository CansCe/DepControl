import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../bin/depcontrol.dart' as cli;

/// `depcontrol collect --pair` end to end, against a real local server rather
/// than a mocked HTTP client — `_pair` calls the top-level `http.post`
/// directly, and a loopback `HttpServer` is the least invasive way to see
/// what it actually sent without changing production code to accept an
/// injectable client for the sake of one test.
void main() {
  group('--pair', () {
    test('writes the bundle before posting it, to the paired endpoint', () async {
      final root = Directory.systemTemp.createTempSync('depcontrol-pair-');
      addTearDown(() => root.deleteSync(recursive: true));
      File('${root.path}/pubspec.yaml').writeAsStringSync('''
name: payroll_app
environment:
  sdk: ^3.6.0
dependencies:
  http: ^1.2.0
''');
      final outPath = '${root.path}/out.json';

      final received = <Map<String, dynamic>>[];
      var receivedPath = '';
      var fileExistedAtRequestTime = false;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        receivedPath = request.uri.path;
        // The file is written synchronously before `_pair`'s `http.post` is
        // even called, so by the time this handler runs — woken by the event
        // loop after that call goes out — the write is already done. Checking
        // it here is what "written before sent" actually means, rather than
        // trusting the source order to hold.
        fileExistedAtRequestTime = File(outPath).existsSync();
        final body = jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
        received.add(body);

        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'scanId': body['scanId']}));
        await request.response.close();
      });

      await cli.main([
        'collect',
        '--out',
        outPath,
        '--pair',
        'TEST-CODE-0000-0000',
        '--api',
        'http://127.0.0.1:${server.port}',
        root.path,
      ]);

      expect(exitCode, 0);
      expect(receivedPath, '/collector/bundles');
      expect(fileExistedAtRequestTime, isTrue);
      expect(received, hasLength(1));
      expect(received.single['code'], 'TEST-CODE-0000-0000');
      expect(received.single['scanId'], startsWith('collect-'));
      final bundle = received.single['bundle'] as Map<String, dynamic>;
      expect(bundle['rootPackageName'], 'payroll_app');

      final written = jsonDecode(File(outPath).readAsStringSync());
      expect((written as Map)['rootPackageName'], 'payroll_app');
    });

    test('--pair and --upload together are refused, not guessed between', () async {
      final root = Directory.systemTemp.createTempSync('depcontrol-pair-conflict-');
      addTearDown(() => root.deleteSync(recursive: true));
      File('${root.path}/pubspec.yaml').writeAsStringSync('name: x\n');

      await cli.main([
        'collect',
        root.path,
        '--pair',
        'SOME-CODE',
        '--upload',
        'https://example.invalid',
      ]);

      expect(exitCode, isNot(0));
    });

    test('a refused code exits non-zero without losing the bundle', () async {
      final root = Directory.systemTemp.createTempSync('depcontrol-pair-401-');
      addTearDown(() => root.deleteSync(recursive: true));
      File('${root.path}/pubspec.yaml').writeAsStringSync('name: x\n');
      final outPath = '${root.path}/out.json';

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
      });

      await cli.main([
        'collect',
        '--out',
        outPath,
        '--pair',
        'BAD-CODE',
        '--api',
        'http://127.0.0.1:${server.port}',
        root.path,
      ]);

      expect(exitCode, isNot(0));
      // Written first, then sent — a refused submission must not also cost
      // the bundle itself.
      expect(File(outPath).existsSync(), isTrue);
    });
  });
}
