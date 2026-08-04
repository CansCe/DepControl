import 'package:ecosystem/ecosystem.dart';
import 'package:test/test.dart';

void main() {
  const nuget = NuGetEcosystem();

  ParsedManifest parse(
    String project, {
    String? lock,
    Map<String, String> companions = const {},
  }) =>
      nuget.parse(
        ManifestFiles(manifest: project, lock: lock, companions: companions),
      );

  group('PackageReference', () {
    test('reads a version stated as an attribute', () {
      final parsed = parse('''
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Newtonsoft.Json" Version="13.0.3" />
  </ItemGroup>
</Project>
''');

      expect(parsed.dependencies.keys, ['Newtonsoft.Json']);
      expect(parsed.dependencies['Newtonsoft.Json']!.constraint, '13.0.3');
    });

    test('and one stated as a child element, which MSBuild also allows', () {
      final parsed = parse('''
<Project>
  <ItemGroup>
    <PackageReference Include="Serilog">
      <Version>3.1.1</Version>
    </PackageReference>
  </ItemGroup>
</Project>
''');

      expect(parsed.dependencies['Serilog']!.constraint, '3.1.1');
    });

    test('element and attribute names are matched without case', () {
      // MSBuild is case-insensitive and real project files take it up on that.
      // A case-sensitive reader reports such a project as having no
      // dependencies at all, which looks like a clean report.
      final parsed = parse('''
<Project>
  <itemgroup>
    <packagereference include="Dapper" version="2.1.35" />
  </itemgroup>
</Project>
''');

      expect(parsed.dependencies['Dapper']!.constraint, '2.1.35');
    });

    test('PrivateAssets="all" is a dev dependency', () {
      final parsed = parse('''
<Project>
  <ItemGroup>
    <PackageReference Include="StyleCop.Analyzers" Version="1.1.118" PrivateAssets="all" />
    <PackageReference Include="Serilog" Version="3.1.1" />
  </ItemGroup>
</Project>
''');

      expect(parsed.dependencies.keys, ['Serilog']);
      expect(parsed.devDependencies.keys, ['StyleCop.Analyzers']);
    });

    test('a ProjectReference is not a package', () {
      final parsed = parse('''
<Project>
  <ItemGroup>
    <ProjectReference Include="..\\Core\\Core.csproj" />
    <Reference Include="System.Web" />
  </ItemGroup>
</Project>
''');

      expect(parsed.dependencies, isEmpty);
      expect(parsed.devDependencies, isEmpty);
    });

    test('the project states its own name where it has one', () {
      expect(
        parse('<Project><PropertyGroup><PackageId>Acme.Core</PackageId>'
                '</PropertyGroup></Project>')
            .packageName,
        'Acme.Core',
      );
      expect(
        parse('<Project><PropertyGroup><AssemblyName>Acme.App</AssemblyName>'
                '</PropertyGroup></Project>')
            .packageName,
        'Acme.App',
      );
      expect(parse('<Project />').packageName, isNull);
    });

    test('an unexpanded MSBuild property is not a name', () {
      final parsed = parse('<Project><PropertyGroup>'
          r'<PackageId>$(MSBuildProjectName)</PackageId>'
          '</PropertyGroup></Project>');

      expect(parsed.packageName, isNull);
    });

    test('a project file that is not XML is the user"s to fix', () {
      expect(
        () => parse('not xml at all'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('central package management', () {
    const project = '''
<Project>
  <ItemGroup>
    <PackageReference Include="Newtonsoft.Json" />
    <PackageReference Include="Serilog" />
  </ItemGroup>
</Project>
''';

    const props = '''
<Project>
  <ItemGroup>
    <PackageVersion Include="Newtonsoft.Json" Version="13.0.3" />
    <PackageVersion Include="Serilog" Version="3.1.1" />
  </ItemGroup>
</Project>
''';

    test('versions come from the companion props file', () {
      final parsed = parse(project, companions: {
        'Directory.Packages.props': props,
      });

      expect(parsed.dependencies['Newtonsoft.Json']!.constraint, '13.0.3');
      expect(parsed.dependencies['Serilog']!.constraint, '3.1.1');
    });

    test('without it, the packages are named with no version at all', () {
      // The failure this companion exists to prevent: the project parses
      // cleanly and every dependency it has is unresolvable.
      final parsed = parse(project);

      expect(parsed.dependencies.keys, ['Newtonsoft.Json', 'Serilog']);
      expect(parsed.dependencies['Newtonsoft.Json']!.constraint, isNull);
    });

    test('package ids are matched without case, as NuGet matches them', () {
      final parsed = parse(
        '<Project><ItemGroup><PackageReference Include="newtonsoft.json" />'
        '</ItemGroup></Project>',
        companions: {'Directory.Packages.props': props},
      );

      expect(parsed.dependencies['newtonsoft.json']!.constraint, '13.0.3');
    });

    test('a project may override a central version', () {
      final parsed = parse(
        '<Project><ItemGroup>'
        '<PackageReference Update="Serilog" Version="2.0.0" />'
        '</ItemGroup></Project>',
        companions: {'Directory.Packages.props': props},
      );

      expect(parsed.dependencies['Serilog']!.constraint, '2.0.0');
    });

    test('a global package reference applies without being named', () {
      final parsed = parse(project, companions: {
        'Directory.Packages.props': '''
<Project>
  <ItemGroup>
    <GlobalPackageReference Include="Nerdbank.GitVersioning" Version="3.6.133" />
  </ItemGroup>
</Project>
''',
      });

      expect(parsed.devDependencies.keys, ['Nerdbank.GitVersioning']);
    });

    test('unreadable props leave the project readable', () {
      // The project file is the manifest and it parsed. Failing the whole
      // project because a file beside it is malformed reports the wrong thing
      // as broken.
      final parsed = parse(project, companions: {
        'Directory.Packages.props': '<Project',
      });

      expect(parsed.dependencies.keys, ['Newtonsoft.Json', 'Serilog']);
    });
  });

  group('packages.config', () {
    const legacy = '''
<?xml version="1.0" encoding="utf-8"?>
<packages>
  <package id="NHibernate" version="5.2.7.4000" targetFramework="net48" />
  <package id="NUnit" version="3.13.3" targetFramework="net48" developmentDependency="true" />
</packages>
''';

    test('is read as both the declaration and the lock', () {
      // A legacy project commits no lockfile, but packages.config states the
      // exact installed version of everything. Treating it as unlocked would
      // resolve constraints the project has already resolved.
      final parsed = parse(
        '<Project ToolsVersion="15.0"><ItemGroup>'
        '<Reference Include="NHibernate"><HintPath>..\\packages\\x.dll</HintPath>'
        '</Reference></ItemGroup></Project>',
        companions: {'packages.config': legacy},
      );

      expect(parsed.hasLock, isTrue);
      expect(parsed.dependencies.keys, ['NHibernate']);
      expect(parsed.devDependencies.keys, ['NUnit']);
      expect(parsed.locked['NHibernate']!.version, '5.2.7+4000');
      expect(parsed.dependencies['NHibernate']!.constraint, '[5.2.7.4000]');
    });

    test('allowedVersions is the constraint where it is stated', () {
      final parsed = parse(
        '<Project />',
        companions: {
          'packages.config': '<packages><package id="A" version="1.2.0" '
              'allowedVersions="[1.0,2.0)" /></packages>',
        },
      );

      expect(parsed.dependencies['A']!.constraint, '[1.0,2.0)');
      expect(parsed.locked['A']!.version, '1.2.0');
    });
  });

  group('packages.lock.json', () {
    test('the resolved version is normalised on the way in', () {
      final parsed = parse(
        '<Project><ItemGroup>'
        '<PackageReference Include="NHibernate" Version="[5.2.7,)" />'
        '</ItemGroup></Project>',
        lock: '''
{
  "version": 1,
  "dependencies": {
    "net48": {
      "NHibernate": {
        "type": "Direct",
        "requested": "[5.2.7, )",
        "resolved": "5.2.7.4000"
      }
    }
  }
}
''',
      );

      expect(parsed.hasLock, isTrue);
      expect(parsed.locked['NHibernate']!.version, '5.2.7+4000');
    });

    test('the first target framework wins where they disagree', () {
      final parsed = parse('<Project />', lock: '''
{
  "dependencies": {
    "net8.0": {"Serilog": {"resolved": "3.1.1"}},
    "net48": {"Serilog": {"resolved": "2.0.0"}}
  }
}
''');

      expect(parsed.locked['Serilog']!.version, '3.1.1');
    });

    test('a broken lockfile is not a broken project', () {
      final parsed = parse(
        '<Project><ItemGroup>'
        '<PackageReference Include="Serilog" Version="3.1.1" />'
        '</ItemGroup></Project>',
        lock: '{ not json',
      );

      expect(parsed.hasLock, isFalse);
      expect(parsed.dependencies.keys, ['Serilog']);
    });
  });

  group('naming', () {
    test('matches project files by extension, not by name', () {
      expect(nuget.naming.isManifest('Acme.Core.csproj'), isTrue);
      expect(nuget.naming.isManifest('Acme.Core.fsproj'), isTrue);
      expect(nuget.naming.isManifest('Acme.Core.vbproj'), isTrue);
      expect(nuget.naming.isManifest('pubspec.yaml'), isFalse);
      // A bare extension is a hidden file, not a project called nothing.
      expect(nuget.naming.isManifest('.csproj'), isFalse);
    });

    test('names its lockfile and its companions', () {
      expect(nuget.naming.isLockFile('packages.lock.json'), isTrue);
      expect(nuget.naming.isCompanion('Directory.Packages.props'), isTrue);
      expect(nuget.naming.isCompanion('packages.config'), isTrue);
    });

    test('all three languages are source, so no project reports empty', () {
      expect(nuget.naming.isSource('src/Program.cs'), isTrue);
      expect(nuget.naming.isSource('src/Program.fs'), isTrue);
      expect(nuget.naming.isSource('src/Program.vb'), isTrue);
    });
  });

  test('constraints are written back in NuGet"s own syntax', () {
    expect(
      nuget.constraintAtLeast(NuGetVersion.tryParse('5.2.7.4000')!),
      '[5.2.7.4000,)',
    );
  });
}
