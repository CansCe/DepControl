import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

import 'import_scanner.dart';

/// The two pubspec files fetched from a repo.
class FetchedPubspecs {
  const FetchedPubspecs({required this.pubspecYaml, this.pubspecLock});

  final String pubspecYaml;
  final String? pubspecLock; // may be absent in a repo

  bool get hasLock => pubspecLock != null;
}

/// One package's pubspec files, and where in the repository they live.
class RepositoryManifest {
  const RepositoryManifest({
    required this.directory,
    required this.files,
    this.importedPackages,
  });

  /// Path from the repository root, empty for the root itself.
  final String directory;

  final FetchedPubspecs files;

  /// Packages this manifest's own Dart source imports, or null when the source
  /// was never read.
  ///
  /// Null and empty are different answers. Empty says a scan ran and found no
  /// imports, which makes every declared dependency suspect; null says nobody
  /// looked, and a report must not turn that into an accusation.
  final Set<String>? importedPackages;

  /// What to call this manifest in a report.
  String get label => directory.isEmpty ? 'repository root' : directory;
}

/// Every pubspec in a repository, root first.
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
    Duration timeout = const Duration(seconds: 15),
    int maxArchiveBytes = defaultMaxArchiveBytes,
  })  : _client = client ?? http.Client(),
        _timeout = timeout,
        _maxArchiveBytes = maxArchiveBytes;

  final http.Client _client;

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

  Future<FetchedPubspecs> fetch(String gitUrl, {String ref = 'HEAD'}) async {
    final raw = _rawBaseFor(gitUrl, ref);

    final yaml = await _get(raw.resolve('pubspec.yaml'));
    if (yaml == null) {
      throw StateError('No pubspec.yaml found at $gitUrl ($ref).');
    }
    final lock = await _get(raw.resolve('pubspec.lock'));
    return FetchedPubspecs(pubspecYaml: yaml, pubspecLock: lock);
  }

  /// Every pubspec in the repository, root first, with the packages each one's
  /// source imports where the source could be read.
  ///
  /// Tries the tarball first and falls back to reading files one at a time; see
  /// the class doc for why. A repository holding no `pubspec.yaml` anywhere is
  /// an error either way — that is an answer about the repository, not a
  /// failure of the strategy, so it is not retried down the other path.
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

  /// The original path: list the tree, then fetch each pubspec over raw HTTP.
  ///
  /// Falls back to the root alone — with a note saying so — when the repository
  /// cannot be listed. Discovery runs against a rate-limited API that is not
  /// worth failing a whole scan over.
  Future<FetchedRepository> _fetchFileByFile(
    String gitUrl,
    String ref,
  ) async {
    final root = await fetch(gitUrl, ref: ref);
    final rootManifest = RepositoryManifest(directory: '', files: root);

    final String? note;
    List<String> directories;
    try {
      final found = await _discoverManifestDirectories(gitUrl, ref);
      if (found == null) {
        return FetchedRepository(
          manifests: [rootManifest],
          discoveryNote: 'Could not list this repository, so only the '
              'pubspec.yaml at its root was read. Any package in a '
              'subdirectory is missing from this report.',
        );
      }
      directories = found.where((d) => d.isNotEmpty).toList();
      note = directories.length > maxManifests
          ? 'This repository has ${directories.length} pubspecs; the first '
              '$maxManifests were read.'
          : null;
      directories = directories.take(maxManifests).toList();
    } on StateError {
      rethrow;
    }

    final manifests = <RepositoryManifest>[rootManifest];
    final raw = _rawBaseFor(gitUrl, ref);

    for (final directory in directories) {
      final base = raw.resolve('$directory/');
      final yaml = await _get(base.resolve('pubspec.yaml'));
      if (yaml == null) continue; // listed but unreadable; not worth failing on

      manifests.add(
        RepositoryManifest(
          directory: directory,
          files: FetchedPubspecs(
            pubspecYaml: yaml,
            pubspecLock: await _get(base.resolve('pubspec.lock')),
          ),
        ),
      );
    }

    return FetchedRepository(manifests: manifests, discoveryNote: note);
  }

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
      if (path.isNotEmpty && !_isIgnored(path)) entries[path] = file;
    }

    // Pass one: where the packages are, most likely to be the point of the
    // repository first — because [maxManifests] decides what gets dropped.
    final directories = <String>[];
    for (final path in entries.keys) {
      if (_directoryOfPubspec(path) case final directory?) {
        directories.add(directory);
      }
    }
    if (directories.isEmpty) {
      throw StateError('No pubspec.yaml found in $gitUrl.');
    }
    directories.sort((a, b) {
      // Demonstrations before shallowness: `bloc` keeps 23 example apps under
      // `examples/` and its actual libraries under `packages/`, and a plain
      // alphabetical sort spends the whole budget on the examples and reports
      // nothing about the library anyone came to read about.
      final byRole = _isIncidental(a) == _isIncidental(b)
          ? 0
          : (_isIncidental(a) ? 1 : -1);
      if (byRole != 0) return byRole;

      // Then shallowest first, so the root leads when there is one.
      final byDepth = _depth(a).compareTo(_depth(b));
      return byDepth != 0 ? byDepth : a.compareTo(b);
    });

    final note = directories.length > maxManifests
        ? 'This repository has ${directories.length} pubspecs; the first '
            '$maxManifests were read.'
        : null;
    final kept = directories.take(maxManifests).toList();

    // Pass two: attribute each source file to the package that owns it, and
    // reduce it to the set of packages it imports. Sources are scanned and
    // discarded one at a time — the archive is already in memory and there is
    // no reason to hold a second copy of it as strings.
    final imports = {for (final directory in kept) directory: <String>{}};
    for (final entry in entries.entries) {
      final path = entry.key;
      final isDart = path.endsWith('.dart');
      final isOptions = _fileName(path) == 'analysis_options.yaml';
      if (!isDart && !isOptions) continue;
      if (entry.value.size > maxSourceFileBytes) continue;

      final owner = _nearestManifest(path, kept);
      if (owner == null) continue;

      final text = _decode(entry.value);
      if (text == null) continue;
      imports[owner]!.addAll(
        isDart
            ? ImportScanner.scan([text])
            : ImportScanner.scan(const [], optionsFiles: [text]),
      );
    }

    final manifests = <RepositoryManifest>[];
    for (final directory in kept) {
      final prefix = directory.isEmpty ? '' : '$directory/';
      final yaml = _decode(entries['${prefix}pubspec.yaml']!);
      if (yaml == null) continue;

      manifests.add(
        RepositoryManifest(
          directory: directory,
          files: FetchedPubspecs(
            pubspecYaml: yaml,
            pubspecLock: _decode(entries['${prefix}pubspec.lock']),
          ),
          importedPackages: imports[directory],
        ),
      );
    }

    if (manifests.isEmpty) throw StateError('No pubspec.yaml found in $gitUrl.');
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

  /// The directory of [path] when it names a `pubspec.yaml`, else null. The
  /// repository root is the empty string.
  static String? _directoryOfPubspec(String path) {
    if (_fileName(path) != 'pubspec.yaml') return null;
    final slash = path.lastIndexOf('/');
    return slash < 0 ? '' : path.substring(0, slash);
  }

  /// The deepest directory in [directories] that contains [path].
  ///
  /// A file belongs to the package nearest above it, not to the root: in a
  /// monorepo `tools/differ/lib/x.dart` is the differ's source, and counting its
  /// imports against the root would report the root as depending on packages it
  /// has never heard of.
  static String? _nearestManifest(String path, List<String> directories) {
    String? best;
    for (final directory in directories) {
      if (directory.isEmpty) {
        best ??= '';
        continue;
      }
      if (!path.startsWith('$directory/')) continue;
      if (best == null || directory.length > best.length) best = directory;
    }
    return best;
  }

  /// Whether a repository path is generated, vendored, or otherwise not the
  /// project's own code.
  static bool _isIgnored(String path) {
    for (final segment in path.split('/')) {
      if (_ignoredSegments.contains(segment)) return true;
    }
    return false;
  }

  /// Directories whose contents are outputs or third-party copies. `build` is
  /// here because Dart and Flutter both write there; a repository that keeps
  /// hand-written source in a directory of that name loses those imports, which
  /// costs a false "declared but not imported" rather than a false accusation
  /// of using something undeclared.
  static const _ignoredSegments = {
    '.dart_tool',
    '.git',
    '.symlinks',
    'build',
    'node_modules',
    'Pods',
  };

  /// Whether a package is a demonstration or fixture rather than something the
  /// repository exists to ship.
  ///
  /// These are still read and still reported — an example app's dependencies
  /// are as capable of carrying an advisory as any other. They just go last,
  /// so that when a repository has more packages than [maxManifests] the ones
  /// dropped are the ones nobody opened the report to see.
  static bool _isIncidental(String directory) {
    for (final segment in directory.split('/')) {
      if (_incidentalSegments.contains(segment)) return true;
    }
    return false;
  }

  static const _incidentalSegments = {
    'example',
    'examples',
    'sample',
    'samples',
    'demo',
    'demos',
    'fixture',
    'fixtures',
    'testdata',
  };

  static String _fileName(String path) {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }

  static int _depth(String directory) =>
      directory.isEmpty ? 0 : directory.split('/').length;

  /// Text of an archive entry, or null when it is missing or unreadable.
  ///
  /// Malformed bytes are allowed through for the same reason as over HTTP: the
  /// pubspec parser downstream explains a broken manifest far better than a
  /// decoder error here would.
  static String? _decode(ArchiveFile? file) {
    final bytes = file?.readBytes();
    return bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
  }

  /// Directories holding a `pubspec.yaml`, or null when the repository could
  /// not be listed.
  ///
  /// Uses each forge's tree API, which returns the whole file list in one
  /// request rather than walking directories.
  Future<List<String>?> _discoverManifestDirectories(
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

    final directories = <String>{};
    for (final entry in entries.whereType<Map<String, dynamic>>()) {
      final path = entry['path']?.toString();
      if (path == null || !path.endsWith('pubspec.yaml')) continue;

      // Generated and vendored trees are not the project's own packages.
      if (path.contains('.dart_tool/') || path.contains('/build/')) continue;

      final slash = path.lastIndexOf('/');
      directories.add(slash < 0 ? '' : path.substring(0, slash));
    }

    final sorted = directories.toList()..sort();
    return sorted;
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
