import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// The two pubspec files fetched from a repo.
class FetchedPubspecs {
  const FetchedPubspecs({required this.pubspecYaml, this.pubspecLock});

  final String pubspecYaml;
  final String? pubspecLock; // may be absent in a repo

  bool get hasLock => pubspecLock != null;
}

/// One package's pubspec files, and where in the repository they live.
class RepositoryManifest {
  const RepositoryManifest({required this.directory, required this.files});

  /// Path from the repository root, empty for the root itself.
  final String directory;

  final FetchedPubspecs files;

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

/// Fetches just `pubspec.yaml` (+ `pubspec.lock`) from a Git URL.
///
/// Targets the common hosts (GitHub/GitLab) via their raw-file HTTP endpoints,
/// avoiding a full clone. For arbitrary hosts, swap in a shallow `git archive`
/// in a sandboxed temp dir (see [fetchViaGitArchive]).
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
  })  : _client = client ?? http.Client(),
        _timeout = timeout;

  final http.Client _client;

  /// How long a single request may take. Injectable so tests can exercise the
  /// give-up path without waiting for it.
  final Duration _timeout;

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
  /// Each costs two requests, and a repository with hundreds of packages is not
  /// something anyone is going to read a single report about.
  static const maxManifests = 25;

  Future<FetchedPubspecs> fetch(String gitUrl, {String ref = 'HEAD'}) async {
    final raw = _rawBaseFor(gitUrl, ref);

    final yaml = await _get(raw.resolve('pubspec.yaml'));
    if (yaml == null) {
      throw StateError('No pubspec.yaml found at $gitUrl ($ref).');
    }
    final lock = await _get(raw.resolve('pubspec.lock'));
    return FetchedPubspecs(pubspecYaml: yaml, pubspecLock: lock);
  }

  /// Every pubspec in the repository, root first.
  ///
  /// Falls back to the root alone — with a note saying so — when the repository
  /// cannot be listed. Discovery runs against a rate-limited API that is not
  /// worth failing a whole scan over.
  Future<FetchedRepository> fetchAll(
    String gitUrl, {
    String ref = 'HEAD',
  }) async {
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
      'gitlab.com' => Uri.https(
          'gitlab.com',
          '/api/v4/projects/${Uri.encodeComponent('$owner/$repo')}'
              '/repository/tree',
          {'ref': safeRef, 'recursive': 'true', 'per_page': '100'},
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

  /// Placeholder for the sandboxed shallow-fetch path (Phase 4).
  Future<FetchedPubspecs> fetchViaGitArchive(String gitUrl, String ref) {
    throw UnimplementedError('Sandboxed git archive fetch — Phase 4.');
  }

  void close() => _client.close();
}
