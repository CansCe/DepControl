import 'package:ecosystem/ecosystem.dart';
import 'package:test/test.dart';

/// What a dependency that does not come from the registry records.
///
/// The rule is one sentence: a constraint is a *version range*, or nothing. Both
/// parsers used to record the declaration's debug rendering instead — for pub, a
/// `GitDependency: url@...`; for npm, the raw specifier — and both of those are
/// URLs. A git URL routinely carries a deploy token and a path dependency names
/// a location on somebody's disk, and either one then travelled into the node,
/// the stored report, the digest, the UI and, once the local collector existed,
/// off the machine that had been promised neither would leave it.
///
/// `foreignOrigin` says the part a reader can act on. Nothing else about a
/// foreign dependency is worth recording, and everything else about one is worth
/// not recording.
void main() {
  group('pub', () {
    const dart = DartEcosystem();

    ParsedManifest parse(String pubspec) =>
        dart.parse(ManifestFiles(manifest: pubspec));

    test('a git dependency keeps its origin and loses its URL', () {
      final parsed = parse('''
name: app
dependencies:
  internal_tools:
    git:
      url: https://deploy-token:s3cr3t@git.acme.internal/tools.git
      ref: main
''');

      final dependency = parsed.dependencies['internal_tools']!;
      expect(dependency.foreignOrigin, 'a git dependency');
      expect(dependency.constraint, isNull);
      expect(dependency.isFromRegistry, isFalse);
    });

    test('a path dependency loses the path', () {
      final parsed = parse('''
name: app
dependencies:
  widgets:
    path: /home/someone/work/widgets
''');

      final dependency = parsed.dependencies['widgets']!;
      expect(dependency.foreignOrigin, 'a path dependency');
      expect(dependency.constraint, isNull);
    });

    test('an SDK dependency keeps its range, which names only the SDK', () {
      final parsed = parse('''
name: app
dependencies:
  flutter:
    sdk: flutter
  flutter_test:
    sdk: flutter
    version: ^0.0.0
''');

      expect(parsed.dependencies['flutter']!.foreignOrigin, 'the SDK');
      // `any` is what an SDK dependency with no stated range parses to, and it
      // is still a range: it names a version set, not a location.
      expect(parsed.dependencies['flutter']!.constraint, 'any');
      expect(parsed.dependencies['flutter_test']!.constraint, '^0.0.0');
    });

    test('an ordinary hosted dependency is untouched', () {
      final parsed = parse('''
name: app
dependencies:
  http: ^1.2.0
''');

      final dependency = parsed.dependencies['http']!;
      expect(dependency.constraint, '^1.2.0');
      expect(dependency.foreignOrigin, isNull);
      expect(dependency.isFromRegistry, isTrue);
    });
  });

  group('npm', () {
    const npm = NpmEcosystem();

    ParsedManifest parse(String packageJson, {String? lock}) =>
        npm.parse(ManifestFiles(manifest: packageJson, lock: lock));

    test('a git specifier is an origin, not a constraint', () {
      final parsed = parse('''
{"name":"app","dependencies":{
  "tools":"git+https://x-token:s3cr3t@git.acme.internal/tools.git#main"
}}
''');

      final dependency = parsed.dependencies['tools']!;
      expect(dependency.foreignOrigin, 'a git dependency');
      expect(dependency.constraint, isNull);
    });

    test('a file specifier loses the path', () {
      final parsed = parse('''
{"name":"app","dependencies":{"widgets":"file:../../internal/widgets"}}
''');

      expect(parsed.dependencies['widgets']!.foreignOrigin, 'a path dependency');
      expect(parsed.dependencies['widgets']!.constraint, isNull);
    });

    test('a range is still a range', () {
      final parsed = parse('{"name":"app","dependencies":{"react":"^18.2.0"}}');

      expect(parsed.dependencies['react']!.constraint, '^18.2.0');
      expect(parsed.dependencies['react']!.foreignOrigin, isNull);
    });

    test('a lockfile that writes a specifier where a version goes', () {
      // npm puts the specifier in `version` for anything it did not install
      // from the registry, so the field that becomes a node's `installed`
      // string is where the URL turns up.
      final parsed = parse(
        '{"name":"app"}',
        lock: '''
{"lockfileVersion":3,"packages":{
  "": {"name":"app"},
  "node_modules/widgets":{"version":"file:../../internal/widgets"},
  "node_modules/tools":{"version":"git+ssh://git@git.acme.internal/t.git#abc"},
  "node_modules/react":{"version":"18.2.0","resolved":"https://registry.npmjs.org/react/-/react-18.2.0.tgz"}
}}
''',
      );

      expect(parsed.locked['widgets']!.version, '(unknown)');
      expect(parsed.locked['widgets']!.foreignOrigin, 'a path dependency');
      expect(parsed.locked['tools']!.version, '(unknown)');
      expect(parsed.locked['react']!.version, '18.2.0');
    });
  });
}
