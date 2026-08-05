/// What a repository's dependencies look like, read on the machine that holds
/// the repository.
///
/// This is the whole of what `depcontrol collect` uploads, and it is deliberately
/// small: package names, the versions they resolved to, and where each manifest
/// sits. No file contents, no source, no URLs, no absolute paths, no credentials
/// and no internal feed hostnames. A repository somebody will not hand to a
/// hosted service is the premise of the feature, so the bundle is parsed locally
/// and reduced to facts rather than uploaded and parsed there.
///
/// What that still discloses is written down rather than glossed: the package
/// names and versions the repository depends on, its root package name, the set
/// of packages its own source imports, and the repo-relative directory of each
/// manifest. Onward from the server, those package names are queried against
/// pub.dev, registry.npmjs.org, nuget.org and OSV, exactly as they are for any
/// scan. **It discloses a repository's dependency list and module layout instead
/// of its contents** — a large reduction, and not zero.
///
/// Every field is tolerated absent on the way in (rule 1): a bundle is written
/// by a CLI on somebody's laptop, and a laptop is under no obligation to have
/// the same version of that CLI as the server it uploads to.
library;

/// A collected repository, as it travels.
class CollectedBundle {
  const CollectedBundle({
    required this.generatedAt,
    required this.manifests,
    this.schema = currentSchema,
    this.toolVersion = 'unknown',
    this.rootPackageName,
    this.pathsRedacted = false,
    this.privatePackagesWithheld = 0,
    this.coverageNote,
  });

  /// The bundle format this was written to.
  ///
  /// Bumped when a change would make an older server misread a newer bundle —
  /// not when a field is merely added, since every reader here tolerates a field
  /// it has never heard of and every writer tolerates one it cannot fill.
  static const currentSchema = 1;

  final int schema;

  /// Which `depcontrol collect` wrote this, for the report to name when
  /// something read oddly. Free text: it is a client's self-description.
  final String toolVersion;

  /// When the collector ran — **on the developer's machine, by their clock**.
  ///
  /// This is the freshness of a local project, and it is not the same claim a
  /// server scan time makes: it says when somebody last ran the CLI, not when
  /// anybody last looked at the registries. A consumer treating a future
  /// timestamp as fresh is trusting a clock it has no reason to.
  final DateTime generatedAt;

  /// The repository's own name, from its root manifest, or null when no
  /// manifest states one.
  final String? rootPackageName;

  /// Whether [CollectedManifest.directory] holds real directory names or opaque
  /// ids.
  ///
  /// Carried on the bundle rather than inferred, because a report built from a
  /// redacted bundle has to *say* it is redacted. Redaction without the label
  /// would render an opaque id where a name belongs and quietly claim to be
  /// naming something — the same lie a report tells when it renders "nobody
  /// looked" as "nothing found".
  final bool pathsRedacted;

  /// How many packages were dropped by `--exclude-private`.
  ///
  /// A count rather than a list, obviously — the names are the thing being
  /// withheld. Reported beside the totals for the reason every other total is
  /// reported: a number that is quietly short is worse than one that says so.
  final int privatePackagesWithheld;

  /// Set when the collector knowingly read less than the whole repository —
  /// the manifest cap, most often. Becomes the report's `coverageNote`.
  final String? coverageNote;

  final List<CollectedManifest> manifests;

  /// Every package named anywhere in this bundle, which is what the ingest caps
  /// are counted against.
  int get packageCount => manifests.fold(
        0,
        (total, manifest) =>
            total + manifest.dependencies.length + manifest.locked.length,
      );

  factory CollectedBundle.fromJson(Map<String, dynamic> json) =>
      CollectedBundle(
        schema: (json['schema'] as num?)?.toInt() ?? currentSchema,
        toolVersion: json['toolVersion'] as String? ?? 'unknown',
        generatedAt:
            DateTime.tryParse(json['generatedAt'] as String? ?? '')?.toUtc() ??
                DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        rootPackageName: json['rootPackageName'] as String?,
        pathsRedacted: json['pathsRedacted'] as bool? ?? false,
        privatePackagesWithheld:
            (json['privatePackagesWithheld'] as num?)?.toInt() ?? 0,
        coverageNote: json['coverageNote'] as String?,
        manifests: [
          for (final m in (json['manifests'] as List? ?? const []))
            if (m is Map<String, dynamic>) CollectedManifest.fromJson(m),
        ],
      );

  Map<String, dynamic> toJson() => {
        'schema': schema,
        'toolVersion': toolVersion,
        'generatedAt': generatedAt.toUtc().toIso8601String(),
        if (rootPackageName != null) 'rootPackageName': rootPackageName,
        'pathsRedacted': pathsRedacted,
        'privatePackagesWithheld': privatePackagesWithheld,
        if (coverageNote != null) 'coverageNote': coverageNote,
        'manifests': [for (final m in manifests) m.toJson()],
      };
}

/// One package's manifest, as read.
class CollectedManifest {
  const CollectedManifest({
    required this.directory,
    required this.ecosystem,
    this.fileName,
    this.packageName,
    this.dependencies = const [],
    this.locked = const [],
    this.importedPackages,
  });

  /// Where the manifest sits, relative to the repository root; empty for the
  /// root itself. A stable opaque id when the bundle is redacted.
  ///
  /// Repo-relative, never absolute: `services/PayrollEngine` says something
  /// about a private repository, but `C:\Users\someone\work\...` says something
  /// about the person.
  final String directory;

  /// The manifest's own file name, where knowing it adds something — a
  /// directory can hold `Acme.csproj` and `Acme.Tests.csproj`.
  final String? fileName;

  /// The `Ecosystem.id` that parsed it.
  final String ecosystem;

  /// The package's own name, where the manifest states one.
  final String? packageName;

  final List<CollectedDependency> dependencies;

  /// What the lockfile resolved, empty when the repository has none.
  ///
  /// The second reason this feature exists: a lockfile is generated locally and
  /// routinely gitignored, so a remote scan resolves declared constraints
  /// instead and labels the versions inferred. An advisory applies to a resolved
  /// version, not to a constraint.
  final List<CollectedPackage> locked;

  /// Packages this manifest's own source imports, or null when no scanner ran.
  ///
  /// Names only. The source was read on the developer's machine and discarded
  /// there; what travels is the set of package names it reached for, which is
  /// the whole of what unused-dependency detection needs.
  final List<String>? importedPackages;

  factory CollectedManifest.fromJson(Map<String, dynamic> json) =>
      CollectedManifest(
        directory: json['directory'] as String? ?? '',
        fileName: json['fileName'] as String?,
        ecosystem: json['ecosystem'] as String? ?? 'dart',
        packageName: json['packageName'] as String?,
        dependencies: [
          for (final d in (json['dependencies'] as List? ?? const []))
            if (d is Map<String, dynamic>) CollectedDependency.fromJson(d),
        ],
        locked: [
          for (final p in (json['locked'] as List? ?? const []))
            if (p is Map<String, dynamic>) CollectedPackage.fromJson(p),
        ],
        importedPackages: json['importedPackages'] == null
            ? null
            : [
                for (final name in (json['importedPackages'] as List))
                  if (name is String) name,
              ],
      );

  Map<String, dynamic> toJson() => {
        'directory': directory,
        if (fileName != null) 'fileName': fileName,
        'ecosystem': ecosystem,
        if (packageName != null) 'packageName': packageName,
        'dependencies': [for (final d in dependencies) d.toJson()],
        'locked': [for (final p in locked) p.toJson()],
        if (importedPackages != null) 'importedPackages': importedPackages,
      };
}

/// A dependency as declared in a manifest.
class CollectedDependency {
  const CollectedDependency({
    required this.name,
    this.constraint,
    this.origin,
    this.dev = false,
  });

  final String name;

  /// The version range the manifest asks for, in the ecosystem's own syntax.
  final String? constraint;

  /// Where this dependency comes from when it is *not* a public registry — 'a
  /// git dependency', 'a path dependency', 'the SDK', 'a private registry'.
  /// Null means the registry, and null is the only value that makes a package
  /// worth looking up.
  ///
  /// **This is where the URLs go to die.** A git dependency's URL can carry a
  /// credential and a path dependency's target is a location on somebody's disk;
  /// both reduce to one of these words before anything is written down. A
  /// package resolved from an internal feed reduces the same way, so the feed's
  /// hostname never travels either — the server needs to know it cannot look the
  /// package up, and nothing more than that.
  final String? origin;

  /// Whether it is a dev dependency. The distinction decides whether a copyleft
  /// license is a problem, so it is carried rather than flattened.
  final bool dev;

  factory CollectedDependency.fromJson(Map<String, dynamic> json) =>
      CollectedDependency(
        name: json['name'] as String? ?? '',
        constraint: json['constraint'] as String?,
        origin: json['origin'] as String?,
        dev: json['dev'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        if (constraint != null) 'constraint': constraint,
        if (origin != null) 'origin': origin,
        if (dev) 'dev': true,
      };
}

/// A package as resolved in a lockfile.
class CollectedPackage {
  const CollectedPackage({
    required this.name,
    required this.version,
    this.origin,
  });

  final String name;
  final String version;

  /// As [CollectedDependency.origin].
  final String? origin;

  factory CollectedPackage.fromJson(Map<String, dynamic> json) =>
      CollectedPackage(
        name: json['name'] as String? ?? '',
        version: json['version'] as String? ?? '(unknown)',
        origin: json['origin'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'version': version,
        if (origin != null) 'origin': origin,
      };
}
