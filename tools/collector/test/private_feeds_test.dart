import 'package:collector/collector.dart';
import 'package:test/test.dart';

void main() {
  group('.npmrc', () {
    test('a scoped registry marks that scope', () {
      final feeds = PrivateFeeds.fromNpmrc('''
@acme:registry=https://npm.acme.internal/
//npm.acme.internal/:_authToken=s3cr3t
registry=https://registry.npmjs.org/
''');

      expect(feeds.contains('npm', '@acme/design'), isTrue);
      expect(feeds.contains('npm', 'react'), isFalse);
      expect(feeds.contains('npm', '@other/thing'), isFalse);
    });

    test('a bare registry line marks nothing', () {
      // Deliberate. The overwhelmingly common reason to redirect everything is
      // a caching proxy in front of npmjs, and marking every package private
      // would withhold the whole report to protect names that are public.
      final feeds = PrivateFeeds.fromNpmrc('registry=https://proxy.acme.io/\n');

      expect(feeds.isEmpty, isTrue);
      expect(feeds.contains('npm', 'react'), isFalse);
    });

    test('a scope pointing at npmjs is not private', () {
      final feeds = PrivateFeeds.fromNpmrc(
        '@types:registry=https://registry.npmjs.org/\n',
      );

      expect(feeds.contains('npm', '@types/node'), isFalse);
    });
  });

  group('NuGet.config', () {
    const withMapping = '''
<configuration>
  <packageSources>
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
    <add key="acme" value="https://nuget.acme.internal/v3/index.json" />
  </packageSources>
  <packageSourceMapping>
    <packageSource key="nuget.org"><package pattern="*" /></packageSource>
    <packageSource key="acme"><package pattern="Acme.*" /></packageSource>
  </packageSourceMapping>
</configuration>
''';

    test('source mapping says which ids come from the private feed', () {
      final feeds = PrivateFeeds.fromNuGetConfig(withMapping);

      expect(feeds.contains('nuget', 'Acme.Payroll.Core'), isTrue);
      // Ids are case-insensitive, and so is the match.
      expect(feeds.contains('nuget', 'acme.payroll.core'), isTrue);
      expect(feeds.contains('nuget', 'NHibernate'), isFalse);
      // `*` mapped to nuget.org must not make everything private.
      expect(feeds.contains('nuget', 'Newtonsoft.Json'), isFalse);
    });

    test('an exact pattern is exact', () {
      final feeds = PrivateFeeds.fromNuGetConfig('''
<configuration>
  <packageSources>
    <add key="acme" value="https://nuget.acme.internal/v3/index.json" />
  </packageSources>
  <packageSourceMapping>
    <packageSource key="acme"><package pattern="Acme.Payroll" /></packageSource>
  </packageSourceMapping>
</configuration>
''');

      expect(feeds.contains('nuget', 'Acme.Payroll'), isTrue);
      expect(feeds.contains('nuget', 'Acme.Payroll.Core'), isFalse);
    });

    test('a local folder source is as unreachable as an internal host', () {
      final feeds = PrivateFeeds.fromNuGetConfig(r'''
<configuration>
  <packageSources>
    <add key="local" value="\\build-server\packages" />
  </packageSources>
  <packageSourceMapping>
    <packageSource key="local"><package pattern="Acme.*" /></packageSource>
  </packageSourceMapping>
</configuration>
''');

      expect(feeds.contains('nuget', 'Acme.Thing'), isTrue);
    });

    test('a private source with no mapping is reported, not guessed at', () {
      // Without a mapping there is no way to know which packages came from the
      // private source — NuGet resolves that by asking every source in turn. So
      // nothing is marked, and the CLI says so rather than letting
      // `--exclude-private` appear to work while withholding nothing.
      final feeds = PrivateFeeds.fromNuGetConfig('''
<configuration>
  <packageSources>
    <add key="acme" value="https://nuget.acme.internal/v3/index.json" />
  </packageSources>
</configuration>
''');

      expect(feeds.isEmpty, isTrue);
      expect(feeds.unattributedNuGetSources, ['acme']);
    });

    test('a config that is not XML is not a crash', () {
      expect(PrivateFeeds.fromNuGetConfig('not xml at all').isEmpty, isTrue);
    });
  });

  group('pubspec.yaml', () {
    test('a custom hosted host marks the package', () {
      final feeds = PrivateFeeds.fromPubspec('''
name: app
dependencies:
  acme_secrets:
    hosted:
      url: https://dart.acme.internal
      name: acme_secrets
    version: ^2.0.0
  shorthand:
    hosted: https://dart.acme.internal
    version: ^1.0.0
  http: ^1.2.0
dev_dependencies:
  acme_lints:
    hosted: https://dart.acme.internal
    version: ^1.0.0
''');

      expect(feeds.contains('dart', 'acme_secrets'), isTrue);
      expect(feeds.contains('dart', 'shorthand'), isTrue);
      expect(feeds.contains('dart', 'acme_lints'), isTrue);
      expect(feeds.contains('dart', 'http'), isFalse);
    });

    test('pub.dev spelled out is still pub.dev', () {
      final feeds = PrivateFeeds.fromPubspec('''
name: app
dependencies:
  http:
    hosted: https://pub.dev
    version: ^1.2.0
''');

      expect(feeds.contains('dart', 'http'), isFalse);
    });
  });

  test('merging keeps both sides', () {
    final merged = PrivateFeeds.fromNpmrc('@acme:registry=https://npm.acme.io/')
        .merge(PrivateFeeds.fromPubspec('''
name: app
dependencies:
  acme_secrets:
    hosted: https://dart.acme.internal
    version: ^1.0.0
'''));

    expect(merged.contains('npm', '@acme/x'), isTrue);
    expect(merged.contains('dart', 'acme_secrets'), isTrue);
  });
}
