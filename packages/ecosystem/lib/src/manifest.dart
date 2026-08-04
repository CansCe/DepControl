/// The manifest-shaped half of an [Ecosystem]: what its files are called, and
/// what they say once read.
///
/// Everything here is deliberately free of any particular package manager's
/// vocabulary. A `pubspec.yaml` and a `package.json` disagree about almost
/// every detail of spelling and nothing of substance: both name a package,
/// declare dependencies with version ranges, separate the ones that ship from
/// the ones that only build, and are accompanied by a lockfile that records
/// what those ranges actually resolved to.
library;

/// What an ecosystem's files are called, so repository discovery can find them
/// without knowing which ecosystem it is looking at.
class ManifestNaming {
  const ManifestNaming({
    required this.ecosystem,
    required this.manifests,
    required this.lockFiles,
    this.companionFiles = const [],
    this.sourceExtensions = const [],
    this.auxiliaryFiles = const [],
  });

  /// The [Ecosystem.id] these names belong to.
  ///
  /// Carried here so repository discovery can find every ecosystem's manifests
  /// in one pass over the tree and label what it found, without holding a
  /// registry client it has no use for. A repository is quite often more than
  /// one ecosystem — a Flutter app with a JavaScript web front end is the
  /// ordinary case, not the exotic one.
  final String ecosystem;

  /// What this ecosystem's manifests are called — `pubspec.yaml`,
  /// `package.json`, `*.csproj`.
  ///
  /// A file matching one of these is a package, and that is the whole rule
  /// discovery applies. An entry beginning with `*` matches by suffix; anything
  /// else is an exact file name.
  ///
  /// A list because .NET names its project file after the project rather than
  /// after the tool — there is no fixed name to look for, and a repository
  /// holds `.csproj`, `.fsproj` and `.vbproj` side by side. Where pub and npm
  /// answer "is this directory a package" from the directory listing alone,
  /// .NET only answers it from the file names.
  final List<String> manifests;

  /// The canonical manifest name, for messages and for the single-manifest
  /// endpoints.
  ///
  /// The first entry, which is the one worth naming when a repository has none:
  /// "no `pubspec.yaml` found" is a useful sentence and "no `*.csproj`" is at
  /// least an honest one.
  String get manifest => manifests.first;

  /// Files a manifest needs read alongside it, found at or above its own
  /// directory — `Directory.Packages.props` holds the versions a `.csproj`
  /// under central package management deliberately omits.
  ///
  /// Distinct from [auxiliaryFiles], which are scanned for *imports*. These are
  /// parsed as part of the manifest itself: without them the manifest is not
  /// merely less informative, it is incomplete in a way that would be reported
  /// as packages with no version.
  final List<String> companionFiles;

  /// Lockfile names in order of preference.
  ///
  /// A list rather than a single name because ecosystems accumulate them: npm
  /// alone has `package-lock.json`, `npm-shrinkwrap.json`, `yarn.lock` and
  /// `pnpm-lock.yaml`, and a repository can hold more than one. The first that
  /// exists wins, so the order is a statement about which is most likely to be
  /// authoritative rather than an arbitrary one.
  final List<String> lockFiles;

  /// File extensions whose contents are this ecosystem's source code, for
  /// import scanning. Empty where no scanner is wired up, which makes the scan
  /// skip the work rather than report an empty import set — see
  /// [SourceScanner] for why those two must not look alike.
  final List<String> sourceExtensions;

  /// Non-source files that nonetheless name packages — `analysis_options.yaml`
  /// pulls in a lint set through `include:` without any import mentioning it.
  final List<String> auxiliaryFiles;

  /// Whether [fileName] is one of this ecosystem's manifests.
  bool isManifest(String fileName) {
    for (final name in manifests) {
      if (name.startsWith('*')) {
        final suffix = name.substring(1);
        // `.csproj` alone is a hidden file, not a project called nothing.
        if (fileName.length > suffix.length && fileName.endsWith(suffix)) {
          return true;
        }
      } else if (fileName == name) {
        return true;
      }
    }
    return false;
  }

  /// Whether [fileName] is a lockfile for this ecosystem.
  bool isLockFile(String fileName) => lockFiles.contains(fileName);

  /// Whether [fileName] is one of the companion files above.
  bool isCompanion(String fileName) => companionFiles.contains(fileName);

  /// Whether [path] names source code worth scanning for imports.
  bool isSource(String path) =>
      sourceExtensions.any((extension) => path.endsWith(extension));

  /// Whether [fileName] is one of the auxiliary files above.
  bool isAuxiliary(String fileName) => auxiliaryFiles.contains(fileName);
}

/// One package's manifest and lockfile text, as fetched.
///
/// Text rather than a parsed structure: fetching and parsing are separate
/// concerns, and the fetcher has no business knowing YAML from JSON.
class ManifestFiles {
  const ManifestFiles({
    required this.manifest,
    this.lock,
    this.companions = const {},
  });

  final String manifest;

  /// The lockfile's contents, or null when the repository does not commit one —
  /// which is ordinary for a library and near-universal for a Dart package.
  final String? lock;

  /// The [ManifestNaming.companionFiles] that were found, by file name.
  ///
  /// Empty for pub and npm, whose manifests state everything themselves. A
  /// `.csproj` under central package management does not: it names its packages
  /// and leaves every version in a `Directory.Packages.props` somewhere above
  /// it, and a parser handed only the project file would report a dozen
  /// dependencies whose version is unknown.
  final Map<String, String> companions;

  bool get hasLock => lock != null;
}

/// A dependency as *declared* in a manifest.
class DeclaredDependency {
  const DeclaredDependency({this.constraint, this.foreignOrigin});

  /// The version range the manifest asks for, in the ecosystem's own syntax
  /// (`^1.2.3`, `>=1.0.0 <2.0.0`, `~1.2`). Null for a dependency declared
  /// without one, which every ecosystem allows somewhere.
  final String? constraint;

  /// Where this dependency comes from when it is *not* the registry — 'a git
  /// dependency', 'a path dependency', 'the SDK'. Null means the registry, and
  /// null is the only value that makes a package worth looking up.
  ///
  /// This exists because looking a non-registry dependency up by name returns
  /// an answer about entirely different software. pub.dev serves packages
  /// called `flutter` and `sky_engine`; npm serves thousands of names squatted
  /// on by something other than what a git URL in a manifest points at.
  /// Printing a license or an advisory read from one of those beside the real
  /// dependency's name is a fabricated answer that happens to look plausible.
  final String? foreignOrigin;

  /// Whether this dependency can be looked up in the ecosystem's registry.
  bool get isFromRegistry => foreignOrigin == null;
}

/// A dependency as *resolved* in a lockfile.
class LockedDependency {
  const LockedDependency({required this.version, this.foreignOrigin});

  final String version;

  /// As [DeclaredDependency.foreignOrigin]. A lockfile is the last place that
  /// still records where a package came from once resolution has flattened
  /// everything into a list of versions.
  final String? foreignOrigin;

  bool get isFromRegistry => foreignOrigin == null;
}

/// A manifest and its lockfile, read.
class ParsedManifest {
  const ParsedManifest({
    this.packageName,
    this.dependencies = const {},
    this.devDependencies = const {},
    this.locked = const {},
  });

  /// The package's own name, where the manifest states one. Null for the
  /// manifests that do not — a private `package.json` need not be named.
  final String? packageName;

  /// Dependencies that ship.
  final Map<String, DeclaredDependency> dependencies;

  /// Dependencies used to build and test, which do not ship. The distinction
  /// decides whether a copyleft license is a problem, so it is carried through
  /// rather than flattened.
  final Map<String, DeclaredDependency> devDependencies;

  /// What the lockfile resolved, empty when there is no lockfile.
  ///
  /// Empty is not "no dependencies": it means nothing authoritative was
  /// available and the constraints have to be resolved instead. Callers check
  /// [hasLock] rather than the emptiness of this map.
  final Map<String, LockedDependency> locked;

  bool get hasLock => locked.isNotEmpty;

  /// The declared constraint for [name], looking in both dependency sets.
  DeclaredDependency? declarationOf(String name) =>
      dependencies[name] ?? devDependencies[name];

  /// Where each package comes from when it is not the registry, keyed by name.
  ///
  /// The lockfile goes last and wins, because it is the authoritative statement
  /// of what a dependency actually resolved to — a manifest can declare a
  /// registry dependency that an override or a workspace link redirected
  /// elsewhere.
  Map<String, String?> get origins => {
        for (final entry in dependencies.entries)
          entry.key: entry.value.foreignOrigin,
        for (final entry in devDependencies.entries)
          entry.key: entry.value.foreignOrigin,
        for (final entry in locked.entries)
          entry.key: entry.value.foreignOrigin,
      };

  /// Constraints for the dependencies that can actually be resolved against the
  /// registry, which is the only input a resolver can use. Git, path and SDK
  /// dependencies are dropped: the registry publishes no versions for them.
  Map<String, String> registryConstraints(
    Map<String, DeclaredDependency> from,
  ) =>
      {
        for (final entry in from.entries)
          if (entry.value.isFromRegistry && entry.value.constraint != null)
            entry.key: entry.value.constraint!,
      };
}
