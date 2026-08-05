import 'dart:convert';
import 'dart:io';

import 'package:ecosystem/ecosystem.dart';
import 'package:path/path.dart' as p;
import 'package:shared/shared.dart';

import 'private_feeds.dart';
import 'version.dart';

/// Reads a repository on the machine that holds it and reduces it to a
/// [CollectedBundle].
///
/// The server's own reader downloads a tarball and does the same work; this one
/// walks a working tree. They share every rule about *where* a manifest is and
/// which package owns a source file (`package:ecosystem`'s `discovery.dart`) and
/// every rule about what a manifest *says* (the [Ecosystem] parsers), which is
/// the whole reason those were extracted. A second set of rules here would
/// diverge, and the divergence would show up as a package attributed to the
/// wrong manifest in a report nobody re-derives.
///
/// Three things it does not do, each on purpose:
///
/// * **It executes nothing.** No `pub get`, no `npm install`, no
///   `dotnet restore`, no build hook, no subprocess of any kind. The server
///   promises this about its own inputs and a tool running on a developer's
///   machine has less licence, not more.
/// * **It ignores `.gitignore`.** That is the point: a lockfile is generated
///   locally and routinely gitignored, and it is the only authoritative
///   statement of what is installed.
/// * **It follows no symlinks.** A link out of the repository is a path to
///   somebody's home directory, and reading through it would put files nobody
///   named into a bundle they are about to upload.
class Collector {
  Collector({
    required this.root,
    this.ecosystems = standardEcosystems,
    this.maxManifests = defaultMaxManifests,
    this.maxSourceFileBytes = defaultMaxSourceFileBytes,
    this.redactPaths = false,
    this.excludePrivate = false,
    void Function(String message)? warn,
  }) : _warn = warn ?? _printWarning;

  /// The repository root. Everything is recorded relative to it, and nothing
  /// above it is read.
  final Directory root;

  final List<Ecosystem> ecosystems;

  /// Most manifests to read from one repository, matching the server's cap so a
  /// bundle cannot describe a repository the server would have refused to.
  final int maxManifests;

  /// Largest single source file worth scanning for imports. Anything past this
  /// is generated or vendored, and its directives are not the project's own.
  final int maxSourceFileBytes;

  /// Whether manifest directories are replaced by opaque positional ids.
  final bool redactPaths;

  /// Whether packages from a private feed are dropped entirely rather than
  /// marked unchecked.
  final bool excludePrivate;

  final void Function(String message) _warn;

  static const defaultMaxManifests = 25;
  static const defaultMaxSourceFileBytes = 1024 * 1024;

  /// The ecosystems a collector reads by default — every one the server scans.
  ///
  /// `const` and network-free, which is what phase 0.9 bought: the same three
  /// objects the server holds, constructed here with no registry behind them.
  static const standardEcosystems = <Ecosystem>[
    DartEcosystem(),
    NpmEcosystem(),
    NuGetEcosystem(),
  ];

  /// Directory names to skip on top of the ones a published repository would
  /// also have.
  ///
  /// `obj/` is MSBuild's intermediate directory and holds a generated
  /// `project.assets.json` naming every transitive package; reading it would
  /// report a project's build artefacts as its source.
  static const localOnlyIgnoredSegments = {'obj'};

  /// Reads the repository.
  ///
  /// Throws [StateError] when it holds no manifest at all — the same answer the
  /// server gives, and an answer about the repository rather than a failure of
  /// this tool.
  CollectedBundle collect() {
    final paths = _walk();
    final naming = [for (final e in ecosystems) e.naming];

    final located = <ManifestLocation>[];
    for (final path in paths.keys) {
      if (manifestAt(path, naming) case final location?) located.add(location);
    }
    if (located.isEmpty) {
      throw StateError(
        'No package manifest found under ${root.path}. Looked for '
        '${naming.map((n) => n.manifest).join(', ')}.',
      );
    }
    located.sort(compareByReadingOrder);

    final notes = <String>[];
    if (located.length > maxManifests) {
      notes.add(
        'This repository has ${located.length} manifests; the first '
        '$maxManifests were read.',
      );
    }
    final kept = located.take(maxManifests).toList();

    final imports = _scanSources(paths, kept);
    final feeds = _privateFeeds(paths, kept);
    if (feeds.unattributedNuGetSources.isNotEmpty) {
      _warn(
        'NuGet.config configures '
        '${feeds.unattributedNuGetSources.length} non-public source(s) with no '
        'packageSourceMapping, so which packages come from them cannot be '
        'known. They will be looked up on nuget.org like any other.',
      );
    }

    var withheld = 0;
    var unreadable = 0;
    final manifests = <CollectedManifest>[];
    for (final location in kept) {
      final ecosystem = ecosystems.firstWhere(
        (e) => e.id == location.ecosystem,
      );
      final files = _filesFor(location, ecosystem.naming, paths);
      if (files == null) continue;

      final ParsedManifest parsed;
      try {
        parsed = ecosystem.parse(files);
      } on FormatException catch (e) {
        // A broken manifest is the user's to fix, and they are standing right
        // here — so it is said out loud and left out, rather than failing a
        // collect that would otherwise describe the other twenty projects
        // correctly.
        unreadable++;
        _warn('Could not read ${location.path}: ${e.message}');
        continue;
      }

      // Pub's own private-feed spelling is a `hosted:` host, which the shared
      // parser deliberately does not surface — until this feature there was no
      // host it could name that the server could not reach.
      final local = location.ecosystem == 'dart'
          ? feeds.merge(PrivateFeeds.fromPubspec(files.manifest))
          : feeds;

      final collected = _collect(
        location,
        parsed,
        imports[location.key],
        local,
        kept.indexOf(location) + 1,
        kept.length,
      );
      withheld += collected.withheld;
      manifests.add(collected.manifest);
    }

    if (manifests.isEmpty) {
      throw StateError(
        'Every manifest under ${root.path} failed to parse; there is nothing '
        'to send.',
      );
    }
    if (unreadable > 0) {
      notes.add(
        '$unreadable manifest${unreadable == 1 ? '' : 's'} could not be parsed '
        'and ${unreadable == 1 ? 'is' : 'are'} missing from this report.',
      );
    }

    return CollectedBundle(
      schema: CollectedBundle.currentSchema,
      toolVersion: collectorVersion,
      generatedAt: DateTime.now().toUtc(),
      rootPackageName: _rootPackageName(manifests),
      pathsRedacted: redactPaths,
      privatePackagesWithheld: withheld,
      coverageNote: notes.isEmpty ? null : notes.join(' '),
      manifests: manifests,
    );
  }

  /// One manifest, reduced to what travels.
  ({CollectedManifest manifest, int withheld}) _collect(
    ManifestLocation location,
    ParsedManifest parsed,
    Set<String>? imported,
    PrivateFeeds feeds,
    int position,
    int total,
  ) {
    var withheld = 0;

    /// Whether this package is dropped, and if not, what origin it carries.
    ///
    /// A private package that is kept is marked rather than described: the
    /// marker says the registry cannot answer for it, which is all the analyzer
    /// needs and all the server is told.
    String? originFor(String name, String? declared) {
      if (!feeds.contains(location.ecosystem, name)) return declared;
      return declared ?? privateFeedOrigin;
    }

    bool isWithheld(String name) =>
        excludePrivate && feeds.contains(location.ecosystem, name);

    final dependencies = <CollectedDependency>[];
    for (final (dev, declarations) in [
      (false, parsed.dependencies),
      (true, parsed.devDependencies),
    ]) {
      for (final entry in declarations.entries) {
        if (isWithheld(entry.key)) {
          withheld++;
          continue;
        }
        dependencies.add(
          CollectedDependency(
            name: entry.key,
            constraint: entry.value.constraint,
            origin: originFor(entry.key, entry.value.foreignOrigin),
            dev: dev,
          ),
        );
      }
    }

    final locked = <CollectedPackage>[];
    for (final entry in parsed.locked.entries) {
      if (isWithheld(entry.key)) {
        withheld++;
        continue;
      }
      locked.add(
        CollectedPackage(
          name: entry.key,
          version: entry.value.version,
          origin: originFor(entry.key, entry.value.foreignOrigin),
        ),
      );
    }

    return (
      withheld: withheld,
      manifest: CollectedManifest(
        // Redaction is positional rather than a hash of the directory: a hash
        // of `services/PayrollEngine` is guessable from a wordlist by anybody
        // who ever sees it, and the person who asked for redaction asked
        // precisely because those names are worth guessing. The cost is that
        // adding or removing a manifest renumbers the rest — which registers as
        // a change in the project's history, and a repository whose manifest
        // set moved has in fact changed.
        directory: redactPaths ? 'manifest-$position' : location.directory,
        fileName: redactPaths ? null : location.fileName,
        ecosystem: location.ecosystem,
        // The package's own name is a name, so redaction covers it too.
        packageName: redactPaths ? null : parsed.packageName,
        dependencies: dependencies,
        locked: locked,
        importedPackages: imported == null ? null : (imported.toList()..sort()),
      ),
    );
  }

  /// Every file under [root], as repo-relative POSIX paths.
  ///
  /// Paths are the currency of everything downstream — attribution, companion
  /// lookup, the report's manifest labels — and a Windows separator in one of
  /// them would produce a bundle that describes a different repository shape
  /// from the same tree read on Linux.
  Map<String, File> _walk() {
    final files = <String, File>{};
    final rootPath = root.absolute.path;

    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = p.posix.joinAll(
        p.split(p.relative(entity.absolute.path, from: rootPath)),
      );
      if (relative.isEmpty || relative.startsWith('..')) continue;
      if (isGeneratedPath(relative) || _isLocallyIgnored(relative)) continue;
      files[relative] = entity;
    }
    return files;
  }

  /// Whether a path is working-tree clutter rather than repository content.
  ///
  /// **Every hidden directory is skipped**, which is a bigger rule than the
  /// server's and is the difference between reading a repository and reading a
  /// developer's machine. A working tree accumulates `.dart_tool`, `.idea`,
  /// `.vs`, `.venv`, `.gradle` — and, found the first time this was pointed at a
  /// real checkout, `.claude/worktrees`, which holds *entire duplicate copies of
  /// the repository*. Twelve of nineteen manifests came back as second and third
  /// readings of the same packages, and on a repository near the manifest cap
  /// that is not noise, it is the real packages being pushed out of the report
  /// by copies of themselves.
  ///
  /// Nothing legitimate is lost: no package manager keeps a project inside a
  /// dot-directory. Hidden *files* are untouched — `.npmrc` and `.gitignore` are
  /// still read, the first because it says where packages come from and the
  /// second because it is deliberately ignored.
  static bool _isLocallyIgnored(String path) {
    for (final segment in path.split('/')) {
      if (localOnlyIgnoredSegments.contains(segment)) return true;
    }
    // The last segment is the file itself, which may legitimately be hidden.
    final directories = path.split('/');
    directories.removeLast();
    return directories.any((segment) => segment.startsWith('.'));
  }

  /// The manifest, its lockfile and its companions, read off disk.
  ManifestFiles? _filesFor(
    ManifestLocation location,
    ManifestNaming naming,
    Map<String, File> paths,
  ) {
    final manifest = _read(paths[location.path]);
    if (manifest == null) return null;

    final prefix = location.directory.isEmpty ? '' : '${location.directory}/';
    String? lock;
    for (final name in naming.lockFiles) {
      lock = _read(paths['$prefix$name']);
      if (lock != null) break;
    }

    return ManifestFiles(
      manifest: manifest,
      lock: lock,
      companions: companionsFor(
        naming,
        location.directory,
        (path) => _read(paths[path]),
      ),
    );
  }

  /// Which packages each manifest's own source imports.
  ///
  /// The source is read here and discarded here. What leaves this method — and
  /// the only thing about the repository's code that ever leaves the machine —
  /// is a set of package names.
  Map<String, Set<String>> _scanSources(
    Map<String, File> paths,
    List<ManifestLocation> kept,
  ) {
    final imports = <String, Set<String>>{
      for (final location in kept)
        if (_ecosystemOf(location.ecosystem)?.sourceScanner != null)
          location.key: <String>{},
    };
    if (imports.isEmpty) return imports;

    for (final entry in paths.entries) {
      final path = entry.key;
      String? text;

      for (final ecosystem in ecosystems) {
        final scanner = ecosystem.sourceScanner;
        if (scanner == null) continue;

        final naming = ecosystem.naming;
        final isSource = naming.isSource(path);
        final isAuxiliary = naming.isAuxiliary(fileNameOf(path));
        if (!isSource && !isAuxiliary) continue;

        final owner = nearestManifest(path, kept, ecosystem.id);
        if (owner == null || !imports.containsKey(owner.key)) continue;

        text ??= _read(entry.value, max: maxSourceFileBytes);
        if (text == null) break; // too large, or unreadable, for every one alike

        imports[owner.key]!.addAll(
          isSource
              ? scanner.scan([text])
              : scanner.scan(const [], auxiliary: [text]),
        );
      }
    }
    return imports;
  }

  /// The private-feed configuration in force, merged across the tree.
  ///
  /// Read from every `.npmrc` and `NuGet.config` at or above a manifest anybody
  /// kept, rather than from the whole tree: a config beside a project nobody
  /// read describes packages nobody collected.
  PrivateFeeds _privateFeeds(
    Map<String, File> paths,
    List<ManifestLocation> kept,
  ) {
    var feeds = const PrivateFeeds();
    final seen = <String>{};

    for (final location in kept) {
      var at = location.directory;
      while (true) {
        for (final name in _feedConfigNames) {
          final path = at.isEmpty ? name : '$at/$name';
          if (!seen.add(path)) continue;
          final content = _read(paths[path]);
          if (content == null) continue;
          feeds = feeds.merge(
            name.toLowerCase() == '.npmrc'
                ? PrivateFeeds.fromNpmrc(content)
                : PrivateFeeds.fromNuGetConfig(content),
          );
        }
        if (at.isEmpty) break;
        final slash = at.lastIndexOf('/');
        at = slash < 0 ? '' : at.substring(0, slash);
      }
    }
    return feeds;
  }

  /// The spellings of these two files that turn up in real repositories.
  /// MSBuild reads `NuGet.config` case-insensitively and repositories are
  /// inconsistent about it; a case-sensitive filesystem then hides the file
  /// from a tool that only looks for one spelling.
  static const _feedConfigNames = [
    '.npmrc',
    'NuGet.config',
    'NuGet.Config',
    'nuget.config',
  ];

  Ecosystem? _ecosystemOf(String id) {
    for (final ecosystem in ecosystems) {
      if (ecosystem.id == id) return ecosystem;
    }
    return null;
  }

  /// The repository's own name: the first manifest that states one, in reading
  /// order — which puts the root first when there is one.
  static String? _rootPackageName(List<CollectedManifest> manifests) {
    for (final manifest in manifests) {
      if (manifest.packageName case final name? when name.isNotEmpty) {
        return name;
      }
    }
    return null;
  }

  /// Text of a file, or null when it is absent, too large, or unreadable.
  ///
  /// Malformed bytes are allowed through rather than rejected, for the reason
  /// the server's reader gives: the manifest parser downstream explains a broken
  /// file far better than a decoder error here would.
  String? _read(File? file, {int? max}) {
    if (file == null) return null;
    try {
      if (max != null && file.lengthSync() > max) return null;
      return utf8.decode(file.readAsBytesSync(), allowMalformed: true);
    } on FileSystemException {
      // Unreadable is not fatal: a permission-denied file in a working tree is
      // ordinary, and the rest of the repository still describes itself.
      return null;
    }
  }

  static void _printWarning(String message) => stderr.writeln('warning: $message');
}
