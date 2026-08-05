import 'dart:convert';

import 'package:pub_semver/pub_semver.dart';

import '../ecosystem.dart';
import 'js_source_scanner.dart';
import 'npm_version_range.dart';

/// npm packages: `package.json`, `package-lock.json`, registry.npmjs.org.
class NpmEcosystem implements Ecosystem {
  const NpmEcosystem();

  @override
  String get id => 'npm';

  @override
  String get displayName => 'npm';

  @override
  ManifestNaming get naming => const ManifestNaming(
        ecosystem: 'npm',
        manifests: ['package.json'],
        // Only the two this can actually read. `yarn.lock` and
        // `pnpm-lock.yaml` are deliberately absent: listing a file the parser
        // does not understand would have the scan find it, read nothing out of
        // it, and report a project as having no locked versions — which is a
        // worse answer than the one it gets by their absence, where the
        // constraints are resolved instead and the report says the versions
        // were inferred.
        lockFiles: ['package-lock.json', 'npm-shrinkwrap.json'],
        sourceExtensions: [
          '.js', '.mjs', '.cjs', '.jsx',
          '.ts', '.mts', '.cts', '.tsx',
        ],
      );

  @override
  SourceScanner? get sourceScanner => const JsSourceScanner();

  @override
  ParsedManifest parse(ManifestFiles files) {
    final Object? decoded;
    try {
      decoded = jsonDecode(files.manifest);
    } on FormatException catch (e) {
      throw FormatException('package.json is not valid JSON: ${e.message}');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('package.json is not a JSON object.');
    }

    return ParsedManifest(
      packageName: decoded['name'] as String?,
      // `optionalDependencies` ship when they install, so they are regular
      // dependencies for every purpose this report has. `peerDependencies` are
      // not: a peer is a requirement this package makes of whoever installs
      // it, and counting them would attribute another project's choices here.
      dependencies: {
        ..._declarations(decoded['dependencies']),
        ..._declarations(decoded['optionalDependencies']),
      },
      devDependencies: _declarations(decoded['devDependencies']),
      locked: files.lock == null ? const {} : _parseLock(files.lock!),
    );
  }

  @override
  VersionConstraint? parseConstraint(String text) => parseNpmRange(text);

  @override
  String constraintAtLeast(Version version) => '^$version';

  Map<String, DeclaredDependency> _declarations(Object? raw) {
    if (raw is! Map<String, dynamic>) return const {};
    return {
      for (final entry in raw.entries)
        if (entry.value case final String spec)
          entry.key: () {
            final origin = _originOf(spec);
            return DeclaredDependency(
              // npm's specifier field is a union, and only the registry arm of
              // it is a version range. The others are URLs and paths —
              // `git+https://token@host/repo.git` is the specifier as written,
              // token included — and recording one as a "constraint" put it in
              // the node, the stored report and the UI. `foreignOrigin` says
              // what a reader needs; the URL only ever leaked.
              constraint: origin == null ? spec : null,
              foreignOrigin: origin,
            );
          }(),
    };
  }

  /// Where a dependency comes from when it is not the registry, or null when it
  /// is.
  ///
  /// npm's specifier field is a union of half a dozen things wearing the same
  /// clothes, and getting this wrong in the permissive direction means looking
  /// a name up on the registry and reporting a different package's version,
  /// advisories and licence beside it. npm has no namespacing and 3 million
  /// packages, so the odds that a name is taken by something unrelated are not
  /// small.
  static String? _originOf(String spec) {
    final text = spec.trim();

    if (text.startsWith('file:') || text.startsWith('link:')) {
      return 'a path dependency';
    }
    if (text.startsWith('workspace:')) return 'a workspace dependency';
    if (text.startsWith('git:') ||
        text.startsWith('git+') ||
        text.startsWith('github:') ||
        text.startsWith('gitlab:') ||
        text.startsWith('bitbucket:') ||
        text.startsWith('gist:')) {
      return 'a git dependency';
    }
    if (text.startsWith('http://') || text.startsWith('https://')) {
      return 'a URL dependency';
    }
    // `npm:other-package@^1.0.0` — the name in the manifest is a local alias
    // for a different package. Resolving it would need the aliased name
    // followed through, and looking up the alias itself answers about whatever
    // happens to be published under it.
    if (text.startsWith('npm:')) return 'an aliased dependency';

    // `owner/repo` with no scheme is GitHub shorthand. A scoped package name
    // also contains a slash, so the leading `@` distinguishes them.
    if (!text.startsWith('@') && text.contains('/')) return 'a git dependency';

    // Whatever is left should be a range. One that cannot be read is not
    // treated as foreign — it is a registry dependency whose constraint this
    // build does not understand, and the report says the version is unknown
    // rather than inventing a provenance for it.
    return null;
  }

  /// Reads `package-lock.json` / `npm-shrinkwrap.json`.
  ///
  /// Two formats. Lockfile v2 and v3 key a flat `packages` object by
  /// installation path (`node_modules/lodash`); v1 nests a `dependencies` tree
  /// by name. v2 files carry both, and the flat form is preferred because it
  /// states each installed copy's path, which is what tells the hoisted version
  /// from a nested one.
  ///
  /// **A known limitation.** npm installs several versions of one package at
  /// once, and this reduces them to one entry per name — the shallowest, which
  /// is the hoisted copy nearly everything resolves to. A nested copy at a
  /// different version is therefore missing from the report, along with any
  /// advisory that applies to it. Reporting them all needs the analyzer to hold
  /// more than one version per name, which is a change above this layer.
  static Map<String, LockedDependency> _parseLock(String content) {
    final Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException {
      // A broken lockfile is not a broken project: fall through to resolving
      // the declared constraints, which the report labels as inferred.
      return const {};
    }
    if (decoded is! Map<String, dynamic>) return const {};

    final packages = decoded['packages'];
    if (packages is Map<String, dynamic>) return _fromPaths(packages);

    final dependencies = decoded['dependencies'];
    if (dependencies is Map<String, dynamic>) return _fromTree(dependencies);

    return const {};
  }

  /// Lockfile v2/v3: `"node_modules/a/node_modules/b": {"version": ...}`.
  static Map<String, LockedDependency> _fromPaths(
    Map<String, dynamic> packages,
  ) {
    final out = <String, LockedDependency>{};
    final depth = <String, int>{};

    for (final entry in packages.entries) {
      final path = entry.key;
      // The root project itself, which is not one of its own dependencies.
      if (path.isEmpty) continue;

      final marker = path.lastIndexOf('node_modules/');
      if (marker < 0) continue;
      final name = path.substring(marker + 'node_modules/'.length);
      if (name.isEmpty) continue;

      final doc = entry.value;
      if (doc is! Map<String, dynamic>) continue;

      final nesting = 'node_modules/'.allMatches(path).length;
      // Shallowest wins: that is the hoisted copy, which is what the rest of
      // the tree resolves to unless it was forced not to.
      if (depth[name] != null && depth[name]! <= nesting) continue;

      depth[name] = nesting;
      out[name] = LockedDependency(
        version: _lockedVersion(doc['version']),
        foreignOrigin: _lockOrigin(doc),
      );
    }

    return out;
  }

  /// Lockfile v1: a `dependencies` tree keyed by name, nested under each
  /// package's own `dependencies`.
  static Map<String, LockedDependency> _fromTree(
    Map<String, dynamic> tree, [
    Map<String, LockedDependency>? into,
    int depth = 0,
  ]) {
    final out = into ?? <String, LockedDependency>{};

    for (final entry in tree.entries) {
      final doc = entry.value;
      if (doc is! Map<String, dynamic>) continue;

      // Shallowest wins, as above; the top level is the hoisted copy.
      if (depth == 0 || !out.containsKey(entry.key)) {
        out[entry.key] = LockedDependency(
          version: _lockedVersion(doc['version']),
          foreignOrigin: _lockOrigin(doc),
        );
      }

      final nested = doc['dependencies'];
      if (nested is Map<String, dynamic>) _fromTree(nested, out, depth + 1);
    }

    return out;
  }

  /// The version a lockfile entry states, or `(unknown)` when what it states is
  /// not a version at all.
  ///
  /// npm writes the *specifier* into `version` for anything it did not install
  /// from the registry — `file:../internal/thing`, or a git URL with whatever
  /// credential was in it. Carried through, that becomes the node's `installed`
  /// string: printed in the report, stored in the revision, and part of what a
  /// local collector would upload. The entry's origin already says it is a path
  /// or a git dependency, which is the part that means anything to a reader.
  static String _lockedVersion(Object? version) {
    if (version is! String || version.isEmpty) return '(unknown)';
    if (version.contains('://') ||
        version.startsWith('file:') ||
        version.startsWith('link:') ||
        version.startsWith('workspace:')) {
      return '(unknown)';
    }
    return version;
  }

  /// Where a locked entry came from, or null for the registry.
  ///
  /// `resolved` is the URL npm installed from, and it is the only thing in a
  /// lockfile that still records provenance once versions are flattened. A
  /// `link` entry is a workspace symlink; a `version` that is itself a
  /// specifier — npm writes `file:../thing` there for a local dependency —
  /// says the same.
  static String? _lockOrigin(Map<String, dynamic> doc) {
    if (doc['link'] == true) return 'a workspace dependency';

    final version = doc['version'];
    if (version is String) {
      if (version.startsWith('file:') || version.startsWith('link:')) {
        return 'a path dependency';
      }
      if (version.contains('://')) return 'a git dependency';
    }

    final resolved = doc['resolved'];
    if (resolved is! String || resolved.isEmpty) return null;
    if (resolved.startsWith('file:')) return 'a path dependency';
    if (resolved.startsWith('git+') || resolved.startsWith('git:')) {
      return 'a git dependency';
    }

    return null;
  }
}
