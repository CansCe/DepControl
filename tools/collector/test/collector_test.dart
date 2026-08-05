import 'dart:convert';
import 'dart:io';

import 'package:collector/collector.dart';
import 'package:shared/shared.dart';
import 'package:test/test.dart';

/// A repository holding one of everything that must not leave the machine.
///
/// A git dependency (whose URL can carry a credential), a path dependency
/// (whose target is a location on somebody's disk), a `.env`, a `NuGet.config`
/// naming an internal host, and an `.npmrc` naming another one.
Directory _fixture() {
  final root = Directory.systemTemp.createTempSync('depcontrol-collect-');
  addTearDown(() => root.deleteSync(recursive: true));

  void write(String path, String content) {
    final file = File('${root.path}/$path');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  write('pubspec.yaml', '''
name: payroll_app
environment:
  sdk: ^3.6.0
dependencies:
  http: ^1.2.0
  acme_secrets:
    hosted:
      url: https://dart.acme.internal
      name: acme_secrets
    version: ^2.0.0
  internal_tools:
    git:
      url: https://deploy-token:s3cr3t@git.acme.internal/tools.git
  local_widgets:
    path: ../../shared/local_widgets
dev_dependencies:
  test: ^1.25.0
''');

  write('pubspec.lock', '''
packages:
  http:
    dependency: "direct main"
    source: hosted
    version: "1.2.2"
  meta:
    dependency: transitive
    source: hosted
    version: "1.15.0"
  local_widgets:
    dependency: "direct main"
    source: path
    description:
      path: "/home/someone/work/shared/local_widgets"
    version: "0.1.0"
''');

  write('.env', 'SUPABASE_SERVICE_KEY=sk_live_do_not_leak\n');
  write('lib/main.dart', "import 'package:http/http.dart';\nvoid main() {}\n");
  write('node_modules/left-pad/package.json', '{"name":"left-pad"}');
  // A whole second copy of the repository, which is what a git worktree under a
  // tool's dot-directory actually is.
  write('.claude/worktrees/wip/pubspec.yaml', 'name: payroll_app\n');

  // A .NET project under central package management, with the internal feed
  // that goes with it.
  write('services/Payroll/Payroll.csproj', '''
<Project Sdk="Microsoft.NET.Sdk">
  <ItemGroup>
    <PackageReference Include="NHibernate" />
    <PackageReference Include="Acme.Payroll.Core" />
  </ItemGroup>
</Project>
''');
  write('Directory.Packages.props', '''
<Project>
  <ItemGroup>
    <PackageVersion Include="NHibernate" Version="5.2.7.4000" />
    <PackageVersion Include="Acme.Payroll.Core" Version="3.1.0" />
  </ItemGroup>
</Project>
''');
  write('services/Payroll/Payroll.cs', 'using NHibernate;\nusing Acme.Payroll.Core;\n');
  write('services/Payroll/obj/project.assets.json', '{"generated":"build output"}');
  write('NuGet.config', '''
<configuration>
  <packageSources>
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
    <add key="acme" value="https://nuget.acme.internal/v3/index.json" />
  </packageSources>
  <packageSourceMapping>
    <packageSource key="acme">
      <package pattern="Acme.*" />
    </packageSource>
  </packageSourceMapping>
</configuration>
''');

  // A JavaScript front end with a scoped internal registry.
  write('web/package.json', '''
{
  "name": "payroll-web",
  "dependencies": {"react": "^18.2.0", "@acme/design": "^4.0.0"}
}
''');
  write('web/.npmrc', '@acme:registry=https://npm.acme.internal/\n');
  write('web/src/app.js', "import React from 'react';\n");

  return root;
}

void main() {
  group('what it reads', () {
    test('finds every ecosystem\'s manifests, root first', () {
      final bundle = Collector(root: _fixture(), warn: (_) {}).collect();

      expect(
        bundle.manifests.map((m) => '${m.ecosystem}:${m.directory}'),
        containsAll(['dart:', 'nuget:services/Payroll', 'npm:web']),
      );
      expect(bundle.rootPackageName, 'payroll_app');
      expect(bundle.schema, 1);
    });

    test('reads the lockfile that a remote scan would never see', () {
      final bundle = Collector(root: _fixture(), warn: (_) {}).collect();
      final dart = bundle.manifests.firstWhere((m) => m.ecosystem == 'dart');

      // The whole second reason this feature exists: `pubspec.lock` is
      // routinely gitignored, and an advisory applies to a resolved version
      // rather than to a constraint.
      expect(
        dart.locked.firstWhere((p) => p.name == 'http').version,
        '1.2.2',
      );
      expect(dart.locked.map((p) => p.name), contains('meta'));
    });

    test('reads a companion file the project omits its versions from', () {
      final bundle = Collector(root: _fixture(), warn: (_) {}).collect();
      final nuget = bundle.manifests.firstWhere((m) => m.ecosystem == 'nuget');

      expect(
        nuget.dependencies
            .firstWhere((d) => d.name == 'NHibernate')
            .constraint,
        '5.2.7.4000',
      );
    });

    test('attributes imports to the nearest manifest of the right kind', () {
      final bundle = Collector(root: _fixture(), warn: (_) {}).collect();

      final dart = bundle.manifests.firstWhere((m) => m.ecosystem == 'dart');
      final npm = bundle.manifests.firstWhere((m) => m.ecosystem == 'npm');
      expect(dart.importedPackages, contains('http'));
      expect(npm.importedPackages, contains('react'));
      // The `.dart` file belongs to the pubspec above it, not to `web`.
      expect(npm.importedPackages, isNot(contains('http')));
    });

    test('skips build output, vendored trees and hidden directories', () {
      final bundle = Collector(root: _fixture(), warn: (_) {}).collect();
      final directories = bundle.manifests.map((m) => m.directory).toList();

      // `node_modules/left-pad/package.json` is a manifest by name and is not
      // this repository's package; `obj/` is MSBuild's own working directory.
      expect(directories, isNot(contains('node_modules/left-pad')));
      expect(directories.every((d) => !d.contains('obj')), isTrue);

      // A git worktree under a tool's dot-directory is an entire duplicate copy
      // of the repository. Read, it fills the manifest budget with second
      // readings of the same packages and pushes the real ones out.
      expect(directories.every((d) => !d.startsWith('.')), isTrue);
      expect(bundle.manifests.length, 3);
    });

    test('a repository with no manifest is an answer, not a crash', () {
      final empty = Directory.systemTemp.createTempSync('depcontrol-empty-');
      addTearDown(() => empty.deleteSync(recursive: true));
      File('${empty.path}/README.md').writeAsStringSync('nothing here');

      expect(
        () => Collector(root: empty, warn: (_) {}).collect(),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('what leaves the machine', () {
    // Asserted on the **serialised bundle**, not on the model: the model is not
    // what gets uploaded, and a field that is dropped or added by `toJson` is
    // exactly the mistake this is here to catch.
    late String wire;

    setUp(() {
      wire = jsonEncode(Collector(root: _fixture(), warn: (_) {}).collect());
    });

    test('no file contents', () {
      expect(wire, isNot(contains('SUPABASE_SERVICE_KEY')));
      expect(wire, isNot(contains('sk_live_do_not_leak')));
      expect(wire, isNot(contains('<Project')));
      expect(wire, isNot(contains('import ')));
    });

    test('no URLs, and no credential inside one', () {
      expect(wire, isNot(contains('https://')));
      expect(wire, isNot(contains('s3cr3t')));
      expect(wire, isNot(contains('.git')));
    });

    test('no internal feed hostnames', () {
      expect(wire, isNot(contains('acme.internal')));
      expect(wire, isNot(contains('nuget.acme')));
      expect(wire, isNot(contains('npm.acme')));
    });

    test('no absolute paths, from the manifests or from the lockfile', () {
      expect(wire, isNot(contains('/home/someone')));
      expect(wire, isNot(contains(Directory.systemTemp.path)));
      expect(wire, isNot(contains(r'C:\\')));
    });

    test('but repo-relative manifest directories do ship, by design', () {
      // Not "contains no paths": attributing a package to the manifest that
      // pulled it in is a core feature of the report, and phase 2's
      // cross-project drift is answered with it. A test asserting the opposite
      // would fail the moment the feature works.
      expect(wire, contains('services/Payroll'));
    });

    test('a non-registry dependency travels as a marker, not a location', () {
      final bundle = Collector(root: _fixture(), warn: (_) {}).collect();
      final dart = bundle.manifests.firstWhere((m) => m.ecosystem == 'dart');

      expect(
        dart.dependencies.firstWhere((d) => d.name == 'internal_tools').origin,
        'a git dependency',
      );
      expect(
        dart.dependencies.firstWhere((d) => d.name == 'local_widgets').origin,
        'a path dependency',
      );
    });
  });

  group('private feeds', () {
    test('a private-feed package is marked unchecked, not degraded', () {
      final bundle = Collector(root: _fixture(), warn: (_) {}).collect();
      final nuget = bundle.manifests.firstWhere((m) => m.ecosystem == 'nuget');
      final npm = bundle.manifests.firstWhere((m) => m.ecosystem == 'npm');
      final dart = bundle.manifests.firstWhere((m) => m.ecosystem == 'dart');

      // Marked, so the analyzer never asks nuget.org about it and never reports
      // somebody else's licence and advisories under this name.
      expect(
        nuget.dependencies
            .firstWhere((d) => d.name == 'Acme.Payroll.Core')
            .origin,
        privateFeedOrigin,
      );
      expect(
        npm.dependencies.firstWhere((d) => d.name == '@acme/design').origin,
        privateFeedOrigin,
      );
      expect(
        dart.dependencies.firstWhere((d) => d.name == 'acme_secrets').origin,
        privateFeedOrigin,
      );

      // The public ones beside them are untouched.
      expect(
        nuget.dependencies.firstWhere((d) => d.name == 'NHibernate').origin,
        isNull,
      );
      expect(bundle.privatePackagesWithheld, 0);
    });

    test('--exclude-private drops them and says how many', () {
      final bundle = Collector(
        root: _fixture(),
        excludePrivate: true,
        warn: (_) {},
      ).collect();

      final names = [
        for (final manifest in bundle.manifests)
          for (final dependency in manifest.dependencies) dependency.name,
      ];
      expect(names, isNot(contains('Acme.Payroll.Core')));
      expect(names, isNot(contains('@acme/design')));
      expect(names, isNot(contains('acme_secrets')));
      expect(names, contains('NHibernate'));

      // The count is the flag: a bundle that is quietly short is worse than one
      // that says so.
      expect(bundle.privatePackagesWithheld, 3);
    });
  });

  group('--redact-paths', () {
    test('replaces directories and names, and says that it did', () {
      final bundle = Collector(
        root: _fixture(),
        redactPaths: true,
        warn: (_) {},
      ).collect();

      // The failure worth catching is the half-implemented one: redaction
      // applied, flag missing, report silently claiming a completeness it does
      // not have.
      expect(bundle.pathsRedacted, isTrue);

      final wire = jsonEncode(bundle);
      expect(wire, isNot(contains('services/Payroll')));
      expect(wire, isNot(contains('payroll_app')));
      expect(wire, isNot(contains('Payroll.csproj')));
      expect(bundle.rootPackageName, isNull);

      expect(
        bundle.manifests.map((m) => m.directory),
        everyElement(startsWith('manifest-')),
      );
      // Still distinct, or two packages' dependencies would merge into one.
      expect(
        bundle.manifests.map((m) => m.directory).toSet().length,
        bundle.manifests.length,
      );
    });

    test('the packages themselves are still reported', () {
      final bundle = Collector(
        root: _fixture(),
        redactPaths: true,
        warn: (_) {},
      ).collect();

      final names = [
        for (final manifest in bundle.manifests)
          for (final dependency in manifest.dependencies) dependency.name,
      ];
      expect(names, containsAll(['http', 'NHibernate', 'react']));
    });
  });

  group('the bundle survives a round trip', () {
    test('through JSON, unchanged in what it claims', () {
      final original = Collector(root: _fixture(), warn: (_) {}).collect();
      final restored = CollectedBundle.fromJson(
        jsonDecode(jsonEncode(original)) as Map<String, dynamic>,
      );

      expect(restored.manifests.length, original.manifests.length);
      expect(restored.rootPackageName, original.rootPackageName);
      expect(restored.packageCount, original.packageCount);
      expect(
        restored.generatedAt.toIso8601String(),
        original.generatedAt.toIso8601String(),
      );
    });
  });
}
