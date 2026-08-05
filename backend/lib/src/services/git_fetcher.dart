import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

import '../ecosystem/ecosystems.dart';

export 'package:ecosystem/ecosystem.dart' show ManifestFiles;

/// One package's manifest files, which ecosystem they belong to, and where in
/// the repository they live.
class RepositoryManifest {
  const RepositoryManifest({
    required this.directory,
    required this.files,
    this.ecosystem = 'dart',
    this.fileName,
    this.importedPackages,
  });

  /// Path from the repository root, empty for the root itself.
  final String directory;

  /// The manifest's own file name, where knowing it adds something.
  ///
  /// Null for the ecosystems whose manifest has one fixed name: saying
  /// `packages/shared/pubspec.yaml` where `packages/shared` will do is noise.
  /// A .NET project is named after itself, so a directory can hold
  /// `Acme.csproj` and `Acme.Tests.csproj` and the directory alone stops
  /// identifying which report line came from which project.
  final String? fileName;

  /// The [Ecosystem.id] whose manifest this is. Defaults to Dart, which is
  /// what every manifest was before there was a choice.
  final String ecosystem;

  final ManifestFiles files;

  /// Packages this manifest's own source imports, or null when the source was
  /// never read.
  ///
  /// Null and empty are different answers. Empty says a scan ran and found no
  /// imports, which makes every declared dependency suspect; null says nobody
  /// looked, and a report must not turn that into an accusation. An ecosystem
  /// with no [SourceScanner] wired up yields null for the same reason.
  final Set<String>? importedPackages;

  /// What to call this manifest in a report.
  String get label {
    if (fileName == null) {
      return directory.isEmpty ? 'repository root' : directory;
    }
    return directory.isEmpty ? fileName! : '$directory/$fileName';
  }
}

/// Every manifest in a repository, root first.
///
/// A repository is not always one package. A pub workspace resolves its members
/// into a single root lockfile, but a directory deliberately kept *out* of the
/// workspace — this project's own `tools/api_differ` is one — resolves
/// separately and can hold quite different versions of the same packages. Only
/// reading the root would report those as though they did not exist.
class FetchedRepository {
  const FetchedRepository({required this.manifests, this.discoveryNote});

  final List<RepositoryManifest> manifests;

  /// Set when the repository could not be listed and only the root was read.
  ///
  /// Discovery uses the forge's tree API, which is rate limited and can simply
  /// be unavailable. Falling back to the root is far better than failing the
  /// scan, but the report must say the coverage is partial rather than imply
  /// the repository holds one package.
  final String? discoveryNote;

  /// The root manifest, which is the one that exists in every repository.
  RepositoryManifest get primary => manifests.first;

  /// The ecosystems this repository turned out to hold, in discovery order.
  List<String> get ecosystems {
    final seen = <String>[];
    for (final manifest in manifests) {
      if (!seen.contains(manifest.ecosystem)) seen.add(manifest.ecosystem);
    }
    return seen;
  }

  /// What to call [manifest] in a report.
  ///
  /// Qualified by ecosystem only where it has to be: a repository whose root
  /// holds both a `pubspec.yaml` and a `package.json` has two manifests that
  /// would otherwise both be called "repository root", and a merged report
  /// naming the same origin for two unrelated dependency trees is unreadable.
  /// Where directories are unique the plain path is clearer, so it is kept.
  String labelOf(RepositoryManifest manifest) {
    // Compared on the label rather than the directory: two .NET projects in one
    // directory already have distinct labels, since each is named after its own
    // file, and qualifying both with `(nuget)` would say nothing.
    final shared =
        manifests.where((other) => other.label == manifest.label).length;
    return shared > 1
        ? '${manifest.label} (${manifest.ecosystem})'
        : manifest.label;
  }
}

/// Fetches a repository's manifests — and, where it can, its Dart source — from
/// a Git URL.
///
/// Two strategies, in order:
///
/// 1. **The source tarball.** One request to the forge's archive endpoint
///    returns the whole tree, so every pubspec is found without a rate-limited
///    listing API and the Dart source comes along for free. That source is what
///    [RepositoryManifest.importedPackages] is read from, and it is the only
///    way to tell a dependency a project uses from one it merely declares.
/// 2. **File by file.** The original path: list the tree, then fetch each
///    `pubspec.yaml` over raw HTTP. Used when the archive cannot be had — the
///    ref is gone, the download is oversized, the bytes do not decode. It still
///    produces a complete dependency report, just without import facts.
///
/// [fetch] stays on the raw-file endpoint throughout: the routes that call it
/// want one pubspec, and downloading a repository to read it would be absurd.
///
/// Everything here is driven by a URL and a ref the user supplied, so the
/// inputs are validated before they reach a request rather than after:
///
/// * the host must be one of the two known raw-content hosts, so a project URL
///   cannot aim the server at an internal address;
/// * the owner, repo and ref must look like what they claim to be. A ref of
///   `../../someone/else/main` normalises away the repository in the URL and
///   fetches a different project's pubspec — the report would then describe a
///   repository the user never named;
/// * responses are capped and timed out, because nothing about a remote host
///   obliges it to be small or prompt.
class GitFetcher {
  GitFetcher({
    http.Client? client,
    Ecosystems? ecosystems,
    Duration timeout = const Duration(seconds: 15),
    int maxArchiveBytes = defaultMaxArchiveBytes,
  })  : _client = client ?? http.Client(),
        _ecosystems = ecosystems ?? Ecosystems.standard(),
        _timeout = timeout,
        _maxArchiveBytes = maxArchiveBytes;

  final http.Client _client;

  /// Which manifests to look for, and whose source scanner reads which files.
  final Ecosystems _ecosystems;

  /// How long a single request may take. Injectable so tests can exercise the
  /// give-up path without waiting for it.
  final Duration _timeout;

  /// The [defaultMaxArchiveBytes] cap in force for this fetcher. Injectable so
  /// tests can reach the refusal without generating sixty megabytes to do it.
  final int _maxArchiveBytes;

  /// A pubspec is a few kilobytes. This is orders of magnitude above anything
  /// legitimate and still small enough to hold in memory without thinking
  /// about it.
  static const maxResponseBytes = 512 * 1024;

  /// Owner and repository segments: what the hosts themselves allow.
  static final _segment = RegExp(r'^[A-Za-z0-9._-]{1,100}$');

  /// A git ref: branch, tag or commit. Slashes are allowed because branch names
  /// such as `feature/thing` are ordinary, so the traversal check below is what
  /// keeps them honest.
  static final _refPattern = RegExp(r'^[A-Za-z0-9._\-/]{1,255}$');

  /// Most manifests to read from one repository.
  ///
  /// A repository with hundreds of packages is not something anyone is going to
  /// read a single report about — and on the file-by-file path each one costs
  /// two more requests.
  static const maxManifests = 25;

  /// Most **inflated** bytes to accept from a repository tarball.
  ///
  /// The cap is counted as the archive decompresses rather than on the download,
  /// because those are wildly different numbers for a hostile input: a few
  /// hundred kilobytes of gzip expands to gigabytes, and a limit on the
  /// compressed size would not notice until the process was already dead.
  /// Counting inflated bytes bounds both, since compressed can never usefully
  /// exceed inflated.
  static const defaultMaxArchiveBytes = 64 * 1024 * 1024;

  /// Largest single source file worth scanning for imports. Anything past this
  /// is generated or vendored, and its directives are not the project's own.
  static const maxSourceFileBytes = 1024 * 1024;

  /// The root manifest of one ecosystem, over raw HTTP.
  ///
  /// [naming] defaults to the first configured ecosystem — Dart — because the
  /// endpoints that call this (resolve, remediation, upgrade detail) still work
  /// only against pub.dev. They pass their own once the resolver takes an
  /// ecosystem.
  Future<ManifestFiles> fetch(
    String gitUrl, {
    String ref = 'HEAD',
    ManifestNaming? naming,
  }) async {
    final names = naming ?? _ecosystems.all.first.naming;
    final raw = _rawBaseFor(gitUrl, ref);

    final manifest = await _get(raw.resolve(names.manifest));
    if (manifest == null) {
      throw StateError('No ${names.manifest} found at $gitUrl ($ref).');
    }
    return ManifestFiles(
      manifest: manifest,
      lock: await _firstLock(raw, names),
    );
  }

  /// The first of [naming]'s lockfiles that exists under [base], or null.
  ///
  /// Ordered rather than exhaustive: npm alone has four lockfile formats and a
  /// repository can commit more than one, so the naming's order is the
  /// statement about which to believe. Stopping at the first hit also keeps the
  /// request count down on the file-by-file path, where each miss is a round
  /// trip.
  Future<String?> _firstLock(Uri base, ManifestNaming naming) async {
    for (final lock in naming.lockFiles) {
      final found = await _get(base.resolve(lock));
      if (found != null) return found;
    }
    return null;
  }

  /// Every manifest in the repository, root first, with the packages each one's
  /// source imports where the source could be read.
  ///
  /// Tries the tarball first and falls back to reading files one at a time; see
  /// the class doc for why. A repository holding no manifest anywhere is an
  /// error either way — that is an answer about the repository, not a failure
  /// of the strategy, so it is not retried down the other path.
  Future<FetchedRepository> fetchAll(
    String gitUrl, {
    String ref = 'HEAD',
  }) async {
    // Validates the URL and ref before anything is requested, on both paths.
    final archiveUrl = _archiveUrlFor(gitUrl, ref);

    if (archiveUrl != null) {
      final fromArchive = await _fetchFromArchive(archiveUrl, gitUrl);
      if (fromArchive != null) return fromArchive;
    }
    return _fetchFileByFile(gitUrl, ref);
  }

  /// The original path: list the tree, then fetch each manifest over raw HTTP.
  ///
  /// Falls back to the root alone — with a note saying so — when the repository
  /// cannot be listed. Discovery runs against a rate-limited API that is not
  /// worth failing a whole scan over.
  ///
  /// This path reads no source, so nothing it returns carries
  /// [RepositoryManifest.importedPackages]. That is why it is the fallback and
  /// not the strategy.
  Future<FetchedRepository> _fetchFileByFile(
    String gitUrl,
    String ref,
  ) async {
    final raw = _rawBaseFor(gitUrl, ref);

    // The root can hold a manifest for more than one ecosystem — a Flutter app
    // with a JavaScript web front end is the ordinary shape of that, not an
    // exotic one — so every configured ecosystem is asked.
    // The root can hold a manifest for more than one ecosystem — a Flutter app
    // with a JavaScript web front end is the ordinary shape of that, not an
    // exotic one — so every configured ecosystem is asked. Only the ones whose
    // manifest has a fixed name can be asked this way: a `.csproj` is named
    // after its project, so there is no URL to guess and it is found by the
    // listing below or not at all.
    final rootManifests = <RepositoryManifest>[];
    for (final ecosystem in _ecosystems.all) {
      final names = ecosystem.naming;
      if (names.manifest.startsWith('*')) continue;
      final manifest = await _get(raw.resolve(names.manifest));
      if (manifest == null) continue;
      rootManifests.add(
        RepositoryManifest(
          directory: '',
          ecosystem: ecosystem.id,
          files: ManifestFiles(
            manifest: manifest,
            lock: await _firstLock(raw, names),
          ),
        ),
      );
    }

    final discovered = await _discoverManifests(gitUrl, ref);
    if (discovered == null) {
      if (rootManifests.isEmpty) throw _nothingFound(gitUrl, ref);
      return FetchedRepository(
        manifests: rootManifests,
        discoveryNote: 'Could not list this repository, so only the '
            'manifests at its root were read. Any package in a '
            'subdirectory is missing from this report.',
      );
    }

    // Discovery sees the root too, so anything already fetched above is
    // dropped rather than fetched twice. One root manifest per ecosystem, since
    // only the fixed-name ecosystems were fetched that way.
    final alreadyRead = {for (final m in rootManifests) m.ecosystem};
    var rest = discovered.manifests
        .where((m) => !(m.directory.isEmpty && alreadyRead.contains(m.ecosystem)))
        .toList();

    if (rootManifests.isEmpty && rest.isEmpty) throw _nothingFound(gitUrl, ref);

    final budget = maxManifests - rootManifests.length;
    final note = rest.length > budget
        ? 'This repository has ${rest.length + rootManifests.length} '
            'manifests; the first $maxManifests were read.'
        : null;
    rest = rest.take(budget < 0 ? 0 : budget).toList();

    // Companions are fetched once per path rather than once per manifest: a
    // repository-root `Directory.Packages.props` is the companion of every
    // project in it, and asking for it twenty times would spend twenty requests
    // saying the same thing.
    final companionCache = <String, String?>{};
    Future<String?> companionAt(String path) async {
      if (!discovered.companionPaths.contains(path)) return null;
      if (companionCache.containsKey(path)) return companionCache[path];
      final content = await _get(raw.resolve(path));
      companionCache[path] = content;
      return content;
    }

    final manifests = <RepositoryManifest>[...rootManifests];
    for (final location in rest) {
      final names = _ecosystems.require(location.ecosystem).naming;
      final base = location.directory.isEmpty
          ? raw
          : raw.resolve('${location.directory}/');
      final manifest = await _get(raw.resolve(location.path));
      if (manifest == null) continue; // listed but unreadable; not fatal

      manifests.add(
        RepositoryManifest(
          directory: location.directory,
          ecosystem: location.ecosystem,
          fileName: location.fileName,
          files: ManifestFiles(
            manifest: manifest,
            lock: await _firstLock(base, names),
            companions: await _fetchCompanions(
              names,
              location.directory,
              companionAt,
            ),
          ),
        ),
      );
    }

    return FetchedRepository(manifests: manifests, discoveryNote: note);
  }

  /// The companions of a manifest in [directory], over HTTP.
  ///
  /// The same nearest-at-or-above walk [_companionsFor] does for an archive,
  /// except that a miss here would be a request. Only paths the listing already
  /// showed to exist are asked for, which is why this path needs the listing
  /// and cannot speculate.
  static Future<Map<String, String>> _fetchCompanions(
    ManifestNaming naming,
    String directory,
    Future<String?> Function(String path) read,
  ) async {
    if (naming.companionFiles.isEmpty) return const {};

    final found = <String, String>{};
    for (final name in naming.companionFiles) {
      var at = directory;
      while (true) {
        final content = await read(at.isEmpty ? name : '$at/$name');
        if (content != null) {
          found[name] = content;
          break;
        }
        if (at.isEmpty) break;
        final slash = at.lastIndexOf('/');
        at = slash < 0 ? '' : at.substring(0, slash);
      }
    }
    return found;
  }

  StateError _nothingFound(String gitUrl, String ref) => StateError(
        'No ${_ecosystems.all.map((e) => e.naming.manifest).join(' or ')} '
        'found at $gitUrl ($ref).',
      );

  /// Reads the whole repository out of one tarball, or null when the archive
  /// could not be downloaded or decoded and the caller should fall back.
  ///
  /// Throws only for a repository that was read successfully and holds no
  /// pubspec: falling back would spend three more requests confirming it.
  Future<FetchedRepository?> _fetchFromArchive(Uri url, String gitUrl) async {
    final Archive archive;
    try {
      archive = TarDecoder().decodeBytes(await _inflate(url));
    } on _ArchiveUnavailable {
      return null;
    } on ArchiveException {
      return null;
    } on FormatException {
      return null;
    } on RangeError {
      // A truncated tar indexes past the end of its own buffer.
      return null;
    }

    // The forge wraps everything in one top-level directory named for the repo
    // and ref, which is not part of any path the repository itself knows.
    final entries = <String, ArchiveFile>{};
    for (final file in archive) {
      if (!file.isFile) continue;
      final slash = file.name.indexOf('/');
      if (slash < 0) continue; // `pax_global_header` and friends
      final path = file.name.substring(slash + 1);
      if (path.isNotEmpty && !isGeneratedPath(path)) entries[path] = file;
    }

    // Pass one: where the packages are, most likely to be the point of the
    // repository first — because [maxManifests] decides what gets dropped.
    final locations = <ManifestLocation>[];
    for (final path in entries.keys) {
      if (manifestAt(path, _ecosystems.naming) case final location?) {
        locations.add(location);
      }
    }
    if (locations.isEmpty) {
      throw StateError('No package manifest found in $gitUrl.');
    }
    locations.sort(compareByReadingOrder);

    final note = locations.length > maxManifests
        ? 'This repository has ${locations.length} manifests; the first '
            '$maxManifests were read.'
        : null;
    final kept = locations.take(maxManifests).toList();

    // Pass two: attribute each source file to the package that owns it, and
    // reduce it to the set of packages it imports. Sources are scanned and
    // discarded one at a time — the archive is already in memory and there is
    // no reason to hold a second copy of it as strings.
    //
    // Attribution is per ecosystem: a `.dart` file belongs to the nearest
    // pubspec above it, not to the nearest `package.json`, and in a repository
    // holding both the nearest manifest of *any* kind is regularly the wrong
    // one.
    final imports = <String, Set<String>>{
      for (final location in kept)
        if (_ecosystems.byId(location.ecosystem)?.sourceScanner != null)
          location.key: <String>{},
    };

    for (final entry in entries.entries) {
      if (entry.value.size > maxSourceFileBytes) continue;
      final path = entry.key;

      for (final ecosystem in _ecosystems.all) {
        final scanner = ecosystem.sourceScanner;
        if (scanner == null) continue;

        final naming = ecosystem.naming;
        final isSource = naming.isSource(path);
        final isAuxiliary = naming.isAuxiliary(fileNameOf(path));
        if (!isSource && !isAuxiliary) continue;

        final owner = nearestManifest(path, kept, ecosystem.id);
        if (owner == null) continue;

        final text = _decode(entry.value);
        if (text == null) break; // undecodable for every ecosystem alike

        imports[owner.key]!.addAll(
          isSource
              ? scanner.scan([text])
              : scanner.scan(const [], auxiliary: [text]),
        );
      }
    }

    final manifests = <RepositoryManifest>[];
    for (final location in kept) {
      final naming = _ecosystems.require(location.ecosystem).naming;
      final prefix =
          location.directory.isEmpty ? '' : '${location.directory}/';

      final manifest = _decode(entries[location.path]);
      if (manifest == null) continue;

      String? lock;
      for (final name in naming.lockFiles) {
        lock = _decode(entries['$prefix$name']);
        if (lock != null) break;
      }

      manifests.add(
        RepositoryManifest(
          directory: location.directory,
          ecosystem: location.ecosystem,
          fileName: location.fileName,
          files: ManifestFiles(
            manifest: manifest,
            lock: lock,
            companions: companionsFor(
              naming,
              location.directory,
              (path) => _decode(entries[path]),
            ),
          ),
          importedPackages: imports[location.key],
        ),
      );
    }

    if (manifests.isEmpty) {
      throw StateError('No package manifest found in $gitUrl.');
    }
    return FetchedRepository(manifests: manifests, discoveryNote: note);
  }

  /// Downloads [url] and gunzips it, refusing anything that inflates past the
  /// archive cap.
  ///
  /// Throws [_ArchiveUnavailable] for every way the download can fail, so the
  /// caller has one thing to catch and one decision to make: fall back.
  Future<Uint8List> _inflate(Uri url) async {
    final http.StreamedResponse response;
    try {
      response = await _client.send(http.Request('GET', url)).timeout(_timeout);
    } on TimeoutException {
      throw const _ArchiveUnavailable();
    } on http.ClientException {
      throw const _ArchiveUnavailable();
    }

    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      throw const _ArchiveUnavailable();
    }

    // copy: false hands the chunks straight through; they are never reused.
    final inflated = BytesBuilder(copy: false);
    try {
      await for (final chunk in gzip.decoder.bind(response.stream)
          .timeout(_timeout)) {
        inflated.add(chunk);
        // Throwing out of `await for` cancels the subscription, so a bomb stops
        // being downloaded here rather than merely stopping being kept.
        if (inflated.length > _maxArchiveBytes) {
          throw const _ArchiveUnavailable();
        }
      }
    } on TimeoutException {
      throw const _ArchiveUnavailable();
    } on FormatException {
      throw const _ArchiveUnavailable(); // not gzip, or corrupt
    }

    return inflated.takeBytes();
  }

  // Where a manifest is, which package owns a source file, where a companion
  // file is found and which paths are generated all live in
  // `package:ecosystem`'s `discovery.dart` now. They are answered from paths
  // alone, and the collector walking somebody's working tree has to answer them
  // exactly as this does — two implementations would disagree eventually, and
  // the disagreement would read as a package attributed to the wrong manifest.

  /// Text of an archive entry, or null when it is missing or unreadable.
  ///
  /// Malformed bytes are allowed through for the same reason as over HTTP: the
  /// pubspec parser downstream explains a broken manifest far better than a
  /// decoder error here would.
  static String? _decode(ArchiveFile? file) {
    final bytes = file?.readBytes();
    return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
  }

  /// Every manifest in the repository — and where its companions are — or null
  /// when it could not be listed.
  ///
  /// Uses each forge's tree API, which returns the whole file list in one
  /// request rather than walking directories. Companion *paths* rather than
  /// contents: this is a listing, and knowing which exist is what turns the
  /// nearest-companion walk from a series of speculative 404s into one request
  /// for a file that is definitely there.
  Future<_Discovery?> _discoverManifests(
    String gitUrl,
    String ref,
  ) async {
    final url = _treeApiFor(gitUrl, ref);
    if (url == null) return null;

    final http.Response response;
    try {
      response = await _client.get(url).timeout(_timeout);
    } on TimeoutException {
      return null;
    }
    // 403 is the unauthenticated rate limit, which is low and shared by IP.
    if (response.statusCode != 200) return null;

    final Object? json;
    try {
      json = jsonDecode(response.body);
    } on FormatException {
      return null;
    }

    // GitHub wraps the list in an object; GitLab returns a bare array.
    final entries = switch (json) {
      final List list => list,
      final Map map => map['tree'] as List? ?? const [],
      _ => const [],
    };

    final found = <String, ManifestLocation>{};
    final companions = <String>{};
    for (final entry in entries.whereType<Map<String, dynamic>>()) {
      final path = entry['path']?.toString();
      if (path == null) continue;

      // Generated and vendored trees are not the project's own packages. This
      // path predates the archive reader's [_isIgnored] and is deliberately
      // narrower: the tree API lists only paths, and a repository that keeps
      // real source under one of these names loses a manifest rather than
      // gaining a spurious one.
      if (path.contains('.dart_tool/') ||
          path.contains('/build/') ||
          path.contains('node_modules/')) {
        continue;
      }

      final location = manifestAt(path, _ecosystems.naming);
      if (location != null) {
        found[location.key] = location;
        continue;
      }

      final fileName = fileNameOf(path);
      if (_ecosystems.naming.any((n) => n.isCompanion(fileName))) {
        companions.add(path);
      }
    }

    final manifests = found.values.toList()
      ..sort((a, b) {
        final byPath = a.directory.compareTo(b.directory);
        if (byPath != 0) return byPath;
        final byEcosystem = a.ecosystem.compareTo(b.ecosystem);
        return byEcosystem != 0
            ? byEcosystem
            : a.fileName.compareTo(b.fileName);
      });

    return (manifests: manifests, companionPaths: companions);
  }

  /// The endpoint serving a gzipped tar of the repository at [ref], or null for
  /// a host without one this knows.
  ///
  /// GitHub's `codeload` host is what `api.github.com/.../tarball` redirects to;
  /// going straight there skips both the redirect and the API rate limit, which
  /// is the whole reason this path exists. GitLab's archive lives behind its
  /// API, where the project is one URL-encoded path segment — so the URL is
  /// built as text rather than through [Uri.https], which would encode the `%`
  /// of that encoding a second time.
  static Uri? _archiveUrlFor(String gitUrl, String ref) {
    final base = _rawBaseFor(gitUrl, ref);
    final segments = base.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length < 2) return null;
    final owner = segments[0];
    final repo = segments[1];
    final safeRef = _validateRef(ref);

    return switch (base.host) {
      'raw.githubusercontent.com' => Uri.https(
          'codeload.github.com',
          '/$owner/$repo/tar.gz/$safeRef',
        ),
      'gitlab.com' => Uri.parse(
          'https://gitlab.com/api/v4/projects/'
          '${Uri.encodeComponent('$owner/$repo')}'
          '/repository/archive.tar.gz'
          '?sha=${Uri.encodeQueryComponent(safeRef)}',
        ),
      _ => null,
    };
  }

  /// The tree endpoint listing every file at [ref], or null for a host without
  /// one this knows.
  static Uri? _treeApiFor(String gitUrl, String ref) {
    final base = _rawBaseFor(gitUrl, ref);
    final segments = base.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length < 2) return null;
    final owner = segments[0];
    final repo = segments[1];
    final safeRef = _validateRef(ref);

    return switch (base.host) {
      'raw.githubusercontent.com' => Uri.https(
          'api.github.com',
          '/repos/$owner/$repo/git/trees/$safeRef',
          {'recursive': '1'},
        ),
      // Built as text, not through Uri.https: the project is one URL-encoded
      // path segment, and Uri.https would encode the `%` of that encoding again
      // and ask GitLab for a project literally called `acme%2Fdemo`.
      'gitlab.com' => Uri.parse(
          'https://gitlab.com/api/v4/projects/'
          '${Uri.encodeComponent('$owner/$repo')}'
          '/repository/tree'
          '?ref=${Uri.encodeQueryComponent(safeRef)}'
          '&recursive=true&per_page=100',
        ),
      _ => null,
    };
  }

  /// Fetches [url], returning null for a 404 and throwing for anything that
  /// suggests the remote is not behaving.
  Future<String?> _get(Uri url) async {
    final http.StreamedResponse response;
    try {
      response = await _client.send(http.Request('GET', url)).timeout(_timeout);
    } on TimeoutException {
      throw StateError('Timed out fetching $url.');
    }

    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      return null;
    }

    // Trust the declared length only to reject early; a hostile server can
    // understate it, so the running total below is what actually enforces this.
    final declared = response.contentLength;
    if (declared != null && declared > maxResponseBytes) {
      await response.stream.drain<void>();
      throw StateError('$url is larger than $maxResponseBytes bytes.');
    }

    final bytes = <int>[];
    try {
      await for (final chunk in response.stream.timeout(_timeout)) {
        bytes.addAll(chunk);
        if (bytes.length > maxResponseBytes) {
          throw StateError('$url is larger than $maxResponseBytes bytes.');
        }
      }
    } on TimeoutException {
      throw StateError('Timed out reading $url.');
    }

    // A pubspec that is not valid UTF-8 is malformed rather than fatal; the
    // parser downstream will say so more usefully than a decoder error here.
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Checks a repository URL and ref without fetching anything, throwing the
  /// same [StateError] a fetch would.
  ///
  /// Exists because a scan is queued now rather than run inside the request
  /// that asks for it. Everything else a scan can get wrong is only knowable
  /// from the network and belongs in the job's failure; this part is knowable
  /// immediately, and a caller who typed the wrong host should be told so at
  /// the time rather than by a report that turns up failed a minute later.
  static void validate(String gitUrl, {String ref = 'HEAD'}) =>
      _rawBaseFor(gitUrl, ref);

  /// Maps a repo URL to its raw-content base, throwing when the URL or ref is
  /// not something this can safely fetch.
  ///
  /// Returns a directory URI (trailing slash) so callers can [Uri.resolve] a
  /// file name onto it without rebuilding the path by hand.
  static Uri _rawBaseFor(String gitUrl, String ref) {
    final Uri url;
    try {
      url = Uri.parse(gitUrl.replaceAll(RegExp(r'\.git$'), ''));
    } on FormatException {
      throw StateError('"$gitUrl" is not a valid URL.');
    }

    if (url.scheme != 'https') {
      throw StateError(
        'Repository URLs must be https (got "${url.scheme}" in $gitUrl).',
      );
    }

    final segments = url.pathSegments;
    if (segments.length < 2) {
      throw StateError(
        '$gitUrl does not name a repository (expected .../owner/repo).',
      );
    }

    final owner = segments[0];
    final repo = segments[1];
    if (!_segment.hasMatch(owner) || !_segment.hasMatch(repo)) {
      throw StateError('$gitUrl does not name a repository this can fetch.');
    }

    final safeRef = _validateRef(ref);

    // Uri.https percent-encodes each segment, so nothing left in these values
    // can be reinterpreted as URL syntax.
    return switch (url.host) {
      'github.com' => Uri.https(
          'raw.githubusercontent.com',
          '/$owner/$repo/$safeRef/',
        ),
      'gitlab.com' => Uri.https(
          'gitlab.com',
          '/$owner/$repo/-/raw/$safeRef/',
        ),
      _ => throw StateError(
          'Only github.com and gitlab.com repositories are supported '
          '(got "${url.host}").',
        ),
    };
  }

  /// Checks a ref is a plausible branch, tag or commit and cannot escape the
  /// repository it is appended to.
  static String _validateRef(String ref) {
    if (ref.isEmpty) return 'HEAD';

    // The traversal that matters: `..` normalises the repository out of the
    // URL, so `../../other/repo/main` reads someone else's pubspec while the
    // stored project still points at this one.
    final invalid = !_refPattern.hasMatch(ref) ||
        ref.split('/').contains('..') ||
        ref.startsWith('/') ||
        ref.endsWith('/') ||
        ref.contains('//') ||
        ref.startsWith('-');

    if (invalid) {
      throw StateError(
        '"$ref" is not a usable git ref. Use a branch, tag or commit — '
        'letters, digits, ".", "_", "-" and "/".',
      );
    }
    return ref;
  }

  void close() => _client.close();
}

/// The tarball could not be had — any status but 200, a timeout, a body that
/// is not gzip, or one that inflates past the cap.
///
/// Private and deliberately detail-free: every one of those means the same
/// thing to the only code that catches it, which is "read the files instead".
class _ArchiveUnavailable implements Exception {
  const _ArchiveUnavailable();
}

/// What a tree listing turned up: the manifests, and where the files some of
/// them need to be read alongside are.
typedef _Discovery = ({
  List<ManifestLocation> manifests,
  Set<String> companionPaths,
});

