import 'package:backend/src/ecosystem/ecosystems.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

void main() {
  final npm = NpmEcosystem();

  ParsedManifest parse(String manifest, [String? lock]) =>
      npm.parse(ManifestFiles(manifest: manifest, lock: lock));

  group('package.json', () {
    test('reads the name and both dependency sets', () {
      final parsed = parse('''
{
  "name": "acme-app",
  "version": "1.0.0",
  "dependencies": { "lodash": "^4.17.21" },
  "devDependencies": { "jest": "^29.0.0" }
}
''');

      expect(parsed.packageName, 'acme-app');
      expect(parsed.dependencies.keys, ['lodash']);
      expect(parsed.dependencies['lodash']!.constraint, '^4.17.21');
      expect(parsed.devDependencies.keys, ['jest']);
    });

    test('optional dependencies ship, so they are regular ones', () {
      final parsed = parse('''
{
  "dependencies": { "lodash": "^4.0.0" },
  "optionalDependencies": { "fsevents": "^2.3.0" }
}
''');

      expect(parsed.dependencies.keys, containsAll(['lodash', 'fsevents']));
    });

    test('peer dependencies are not this package to install', () {
      // A peer is a requirement made of whoever installs this, not something
      // it brings along. Counting them attributes another project's choices.
      final parsed = parse('''
{
  "dependencies": { "lodash": "^4.0.0" },
  "peerDependencies": { "react": "^18.0.0" }
}
''');

      expect(parsed.dependencies.keys, ['lodash']);
      expect(parsed.devDependencies, isEmpty);
    });

    test('a manifest that is not JSON is the user\'s to fix', () {
      expect(() => parse('{ not json'), throwsFormatException);
    });

    test('a manifest with no dependencies at all is not an error', () {
      final parsed = parse('{"name": "empty"}');
      expect(parsed.dependencies, isEmpty);
      expect(parsed.hasLock, isFalse);
    });
  });

  group('where a dependency comes from', () {
    String? originOf(String spec) => parse('{"dependencies":{"x":"$spec"}}')
        .dependencies['x']!
        .foreignOrigin;

    test('a plain range is the registry', () {
      expect(originOf('^1.0.0'), isNull);
      expect(originOf('*'), isNull);
      expect(originOf('>=1.0.0 <2.0.0'), isNull);
    });

    test('git specifiers in all their spellings', () {
      // npm has no namespacing and three million packages, so looking one of
      // these up by name would report a different package's advisories.
      expect(originOf('git+https://github.com/acme/thing.git'),
          'a git dependency');
      expect(originOf('github:acme/thing'), 'a git dependency');
      expect(originOf('gitlab:acme/thing'), 'a git dependency');
      // Bare owner/repo is GitHub shorthand.
      expect(originOf('acme/thing'), 'a git dependency');
    });

    test('a scoped name is not mistaken for owner/repo', () {
      // Both contain a slash; only one is a package name.
      final parsed = parse('{"dependencies":{"@types/node":"^20.0.0"}}');
      expect(parsed.dependencies['@types/node']!.foreignOrigin, isNull);
      expect(parsed.dependencies['@types/node']!.isFromRegistry, isTrue);
    });

    test('paths, workspaces, tarballs and aliases', () {
      expect(originOf('file:../local'), 'a path dependency');
      expect(originOf('link:../local'), 'a path dependency');
      expect(originOf('workspace:*'), 'a workspace dependency');
      expect(originOf('https://example.com/thing.tgz'), 'a URL dependency');
      expect(originOf('npm:other-package@^1.0.0'), 'an aliased dependency');
    });

    test('an unreadable range is still a registry dependency', () {
      // Not knowing what version it wants is different from it coming from
      // somewhere else, and inventing a provenance would be the worse error.
      expect(originOf('some-nonsense'), isNull);
    });
  });

  group('package-lock.json v2/v3', () {
    const lock = '''
{
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "acme-app", "version": "1.0.0" },
    "node_modules/lodash": { "version": "4.17.21", "resolved": "https://registry.npmjs.org/lodash/-/lodash-4.17.21.tgz" },
    "node_modules/ms": { "version": "2.1.3" },
    "node_modules/debug/node_modules/ms": { "version": "0.7.1" }
  }
}
''';

    test('reads the installed versions', () {
      final parsed = parse('{"dependencies":{"lodash":"^4.0.0"}}', lock);

      expect(parsed.hasLock, isTrue);
      expect(parsed.locked['lodash']!.version, '4.17.21');
    });

    test('the hoisted copy wins over a nested one', () {
      // A known limitation, and this pins which way it falls: npm installs
      // both, and the shallowest is what the tree resolves to unless forced.
      final parsed = parse('{}', lock);
      expect(parsed.locked['ms']!.version, '2.1.3');
    });

    test('the root entry is not one of its own dependencies', () {
      final parsed = parse('{}', lock);
      expect(parsed.locked.containsKey('acme-app'), isFalse);
      expect(parsed.locked.containsKey(''), isFalse);
    });

    test('a workspace link is not from the registry', () {
      final parsed = parse('{}', '''
{
  "lockfileVersion": 3,
  "packages": {
    "node_modules/shared": { "resolved": "packages/shared", "link": true }
  }
}
''');
      expect(parsed.locked['shared']!.foreignOrigin, 'a workspace dependency');
      expect(parsed.locked['shared']!.isFromRegistry, isFalse);
    });

    test('a file: version is a path dependency', () {
      final parsed = parse('{}', '''
{
  "lockfileVersion": 3,
  "packages": { "node_modules/local": { "version": "file:../local" } }
}
''');
      expect(parsed.locked['local']!.foreignOrigin, 'a path dependency');
    });
  });

  group('package-lock.json v1', () {
    test('reads the nested dependency tree', () {
      final parsed = parse('{}', '''
{
  "lockfileVersion": 1,
  "dependencies": {
    "lodash": { "version": "4.17.21" },
    "debug": {
      "version": "4.3.4",
      "dependencies": { "ms": { "version": "2.1.2" } }
    }
  }
}
''');

      expect(parsed.locked['lodash']!.version, '4.17.21');
      expect(parsed.locked['debug']!.version, '4.3.4');
      expect(parsed.locked['ms']!.version, '2.1.2');
    });

    test('a top-level entry beats a nested one of the same name', () {
      final parsed = parse('{}', '''
{
  "lockfileVersion": 1,
  "dependencies": {
    "ms": { "version": "2.1.3" },
    "debug": {
      "version": "4.3.4",
      "dependencies": { "ms": { "version": "0.7.1" } }
    }
  }
}
''');

      expect(parsed.locked['ms']!.version, '2.1.3');
    });
  });

  test('a broken lockfile falls back to resolving the constraints', () {
    // A broken lockfile is not a broken project. The report labels the
    // versions inferred rather than refusing to produce one.
    final parsed = parse('{"dependencies":{"lodash":"^4.0.0"}}', '{ not json');

    expect(parsed.hasLock, isFalse);
    expect(parsed.dependencies.keys, ['lodash']);
  });

  group('naming', () {
    test('claims only the lockfiles it can read', () {
      // Listing yarn.lock would have the scan find it, read nothing out of it,
      // and report a project as having no locked versions — worse than the
      // answer it gets from their absence.
      expect(npm.naming.lockFiles, ['package-lock.json', 'npm-shrinkwrap.json']);
      expect(npm.naming.isLockFile('yarn.lock'), isFalse);
    });

    test('recognises the JavaScript and TypeScript extensions', () {
      expect(npm.naming.isSource('src/index.ts'), isTrue);
      expect(npm.naming.isSource('src/index.mjs'), isTrue);
      expect(npm.naming.isSource('src/App.tsx'), isTrue);
      expect(npm.naming.isSource('lib/main.dart'), isFalse);
    });
  });

  test('remediation writes a caret constraint', () {
    expect(npm.constraintAtLeast(Version.parse('1.2.3')), '^1.2.3');
  });
}
