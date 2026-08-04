import 'dart:convert';

import 'package:pub_semver/pub_semver.dart';
import 'package:xml/xml.dart';

import '../ecosystem.dart';
import 'dotnet_source_scanner.dart';
import 'nuget_version.dart';
import 'nuget_version_range.dart';

/// .NET packages: `*.csproj`, `packages.lock.json`, nuget.org.
///
/// The third ecosystem, and the first that does not fit the shape the other two
/// share. pub and npm each have one manifest with a fixed name that states
/// every dependency and every version. .NET has none of those three things:
///
/// * the project file is named after the project, so discovery matches by
///   extension rather than by name;
/// * under **central package management** the versions are not in the project
///   file at all — it names packages and a `Directory.Packages.props` above it
///   holds what they resolve to, which is why [ManifestFiles.companions]
///   exists;
/// * a **legacy** project keeps its packages in a `packages.config` beside the
///   project file and leaves the project file listing raw assembly references.
///   That is not a historical curiosity, it is what a .NET Framework
///   application in maintenance looks like, and it is most of what anybody
///   wants scanned.
///
/// All three are read into one [ParsedManifest], because they describe one
/// project. A `.csproj` that uses both `PackageReference` and `packages.config`
/// is unusual but legal, and reporting it as two packages would double every
/// dependency it has.
class NuGetEcosystem implements Ecosystem {
  const NuGetEcosystem();

  @override
  String get id => 'nuget';

  @override
  String get displayName => 'NuGet';

  @override
  ManifestNaming get naming => const ManifestNaming(
        ecosystem: 'nuget',
        // C#, F# and Visual Basic. Ordered by how much of .NET is written in
        // each, since the first is what a message names.
        manifests: ['*.csproj', '*.fsproj', '*.vbproj'],
        lockFiles: ['packages.lock.json'],
        companionFiles: ['Directory.Packages.props', 'packages.config'],
        sourceExtensions: ['.cs', '.fs', '.vb'],
      );

  @override
  SourceScanner? get sourceScanner => const DotNetSourceScanner();

  @override
  ParsedManifest parse(ManifestFiles files) {
    final project = _document(files.manifest, 'The project file');

    final central = _centralVersions(files.companions['Directory.Packages.props']);

    final dependencies = <String, DeclaredDependency>{};
    final devDependencies = <String, DeclaredDependency>{};

    for (final reference in _elements(project, 'packagereference')) {
      // `Update` is how a project overrides a centrally managed version; it
      // names a package as surely as `Include` does.
      final id = _attribute(reference, 'include') ??
          _attribute(reference, 'update');
      if (id == null || id.trim().isEmpty) continue;

      final version = _attribute(reference, 'version') ??
          _childText(reference, 'version') ??
          central.versions[id.trim().toLowerCase()];

      final into = _isDevelopmentOnly(reference) ? devDependencies : dependencies;
      into[id.trim()] = DeclaredDependency(constraint: version?.trim());
    }

    // A package listed centrally as global applies to every project under that
    // props file without being named in any of them.
    for (final entry in central.global.entries) {
      devDependencies.putIfAbsent(
        entry.key,
        () => DeclaredDependency(constraint: entry.value),
      );
    }

    final legacy = _packagesConfig(files.companions['packages.config']);
    for (final entry in legacy.entries) {
      final into = entry.value.isDevelopment ? devDependencies : dependencies;
      into[entry.key] = DeclaredDependency(constraint: entry.value.constraint);
    }

    return ParsedManifest(
      packageName: _projectName(project),
      dependencies: dependencies,
      devDependencies: devDependencies,
      locked: files.lock != null
          ? _parseLock(files.lock!)
          // `packages.config` states the exact installed version of every
          // package, which is what a lockfile is. A legacy project therefore
          // needs no resolution and must not be reported as unlocked.
          : {
              for (final entry in legacy.entries)
                entry.key: LockedDependency(version: entry.value.installed),
            },
    );
  }

  @override
  VersionConstraint? parseConstraint(String text) => parseNuGetRange(text);

  @override
  String constraintAtLeast(Version version) => NuGetVersion.atLeast(version);

  /// The project's own package id, where it states one.
  ///
  /// `PackageId` is the authoritative answer and `AssemblyName` the usual
  /// fallback; a project stating neither is named after its file, which this
  /// function is not given. Null rather than a guess — the field exists to be
  /// excluded from a project's own dependency list, and guessing it wrong would
  /// exclude somebody else's package instead.
  String? _projectName(XmlDocument project) {
    for (final name in const ['packageid', 'assemblyname']) {
      for (final element in _elements(project, name)) {
        final text = element.innerText.trim();
        // An unexpanded MSBuild property says nothing this can use.
        if (text.isNotEmpty && !text.contains(r'$(')) return text;
      }
    }
    return null;
  }

  /// `PrivateAssets="all"` — a dependency that does not flow to whoever
  /// installs this project.
  ///
  /// Analyzers, source generators and build tooling are declared this way, and
  /// they are exactly what the other two ecosystems call a dev dependency: used
  /// to build, never shipped. The distinction decides whether a copyleft
  /// licence is a problem, so it is worth reading rather than flattening.
  static bool _isDevelopmentOnly(XmlElement reference) {
    final assets = _attribute(reference, 'privateassets') ??
        _childText(reference, 'privateassets');
    if (assets == null) return false;
    final value = assets.trim().toLowerCase();
    return value == 'all' || value.split(';').contains('all');
  }

  /// `Directory.Packages.props`: the versions a centrally managed project
  /// leaves out, plus the packages it never mentions at all.
  ///
  /// Unreadable props are treated as absent rather than fatal. The project file
  /// is the manifest and it parsed; failing the whole project because a file
  /// beside it is malformed would report a project as broken when what is
  /// broken is one of its versions.
  static ({Map<String, String> versions, Map<String, String> global})
      _centralVersions(String? content) {
    if (content == null) return (versions: const {}, global: const {});

    final XmlDocument props;
    try {
      props = XmlDocument.parse(content);
    } on XmlException {
      return (versions: const {}, global: const {});
    }

    final versions = <String, String>{};
    for (final element in _elements(props, 'packageversion')) {
      final id = _attribute(element, 'include')?.trim();
      final version =
          _attribute(element, 'version') ?? _childText(element, 'version');
      if (id == null || id.isEmpty || version == null) continue;
      // Package ids are case-insensitive, and a props file spelling one
      // differently from the project that uses it is not an error.
      versions[id.toLowerCase()] = version.trim();
    }

    final global = <String, String>{};
    for (final element in _elements(props, 'globalpackagereference')) {
      final id = _attribute(element, 'include')?.trim();
      final version =
          _attribute(element, 'version') ?? _childText(element, 'version');
      if (id == null || id.isEmpty || version == null) continue;
      global[id] = version.trim();
    }

    return (versions: versions, global: global);
  }

  /// `packages.config`: the legacy format, which is both declaration and lock.
  ///
  /// `version` is the exact version installed. `allowedVersions` is the range
  /// the project would accept, and it is what the constraint should be where it
  /// exists — reporting the installed version as the constraint would claim the
  /// project pins something it left open.
  static Map<String, _LegacyPackage> _packagesConfig(String? content) {
    if (content == null) return const {};

    final XmlDocument config;
    try {
      config = XmlDocument.parse(content);
    } on XmlException {
      return const {};
    }

    final packages = <String, _LegacyPackage>{};
    for (final element in _elements(config, 'package')) {
      final id = _attribute(element, 'id')?.trim();
      final version = _attribute(element, 'version')?.trim();
      if (id == null || id.isEmpty || version == null || version.isEmpty) {
        continue;
      }

      final allowed = _attribute(element, 'allowedversions')?.trim();
      packages[id] = _LegacyPackage(
        constraint: allowed != null && allowed.isNotEmpty ? allowed : '[$version]',
        installed: NuGetVersion.normalise(version) ?? version,
        isDevelopment:
            _attribute(element, 'developmentdependency')?.toLowerCase() ==
                'true',
      );
    }
    return packages;
  }

  /// Reads `packages.lock.json`.
  ///
  /// The file is keyed by target framework first, and a project that multi-
  /// targets resolves each one separately — usually, but not always, to the
  /// same versions. This keeps the first reading of each package, which is the
  /// first framework the file lists.
  ///
  /// **A known limitation, and the same one npm has here.** Where two
  /// frameworks resolve a package differently, only one version is reported,
  /// along with any advisory that applies to it. Reporting both needs the
  /// analyzer to hold more than one version per name, which is a change above
  /// this layer.
  static Map<String, LockedDependency> _parseLock(String content) {
    final Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException {
      // A broken lockfile is not a broken project: fall through to the declared
      // constraints, which the report labels as inferred.
      return const {};
    }
    if (decoded is! Map<String, dynamic>) return const {};

    final frameworks = decoded['dependencies'];
    if (frameworks is! Map<String, dynamic>) return const {};

    final out = <String, LockedDependency>{};
    for (final framework in frameworks.values) {
      if (framework is! Map<String, dynamic>) continue;
      for (final entry in framework.entries) {
        if (out.containsKey(entry.key)) continue;
        final doc = entry.value;
        if (doc is! Map<String, dynamic>) continue;

        final resolved = doc['resolved'];
        if (resolved is! String || resolved.isEmpty) continue;
        out[entry.key] = LockedDependency(
          version: NuGetVersion.normalise(resolved) ?? resolved,
        );
      }
    }
    return out;
  }

  /// [content] as XML, or a [FormatException] naming what could not be read.
  ///
  /// The message says which file, because a scan reads three kinds of XML for
  /// one project and "invalid XML" on its own sends someone to the wrong file.
  static XmlDocument _document(String content, String what) {
    try {
      return XmlDocument.parse(content);
    } on XmlException catch (e) {
      throw FormatException('$what is not valid XML: ${e.message}');
    }
  }

  /// Every element named [lowerName], compared without case.
  ///
  /// MSBuild is case-insensitive about element and attribute names and real
  /// project files take it up on that — `packagereference` and `PackageReference`
  /// both build. A case-sensitive reader silently reports such a project as
  /// having no dependencies.
  static Iterable<XmlElement> _elements(XmlDocument document, String lowerName) =>
      document.descendantElements
          .where((e) => e.localName.toLowerCase() == lowerName);

  static String? _attribute(XmlElement element, String lowerName) {
    for (final attribute in element.attributes) {
      if (attribute.localName.toLowerCase() == lowerName) return attribute.value;
    }
    return null;
  }

  static String? _childText(XmlElement element, String lowerName) {
    for (final child in element.childElements) {
      if (child.localName.toLowerCase() == lowerName) return child.innerText;
    }
    return null;
  }
}

/// One `packages.config` entry: what the project asked for, and what it has.
class _LegacyPackage {
  const _LegacyPackage({
    required this.constraint,
    required this.installed,
    required this.isDevelopment,
  });

  final String constraint;
  final String installed;
  final bool isDevelopment;
}
