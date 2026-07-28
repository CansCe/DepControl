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

  Future<FetchedPubspecs> fetch(String gitUrl, {String ref = 'HEAD'}) async {
    final raw = _rawBaseFor(gitUrl, ref);

    final yaml = await _get(raw.resolve('pubspec.yaml'));
    if (yaml == null) {
      throw StateError('No pubspec.yaml found at $gitUrl ($ref).');
    }
    final lock = await _get(raw.resolve('pubspec.lock'));
    return FetchedPubspecs(pubspecYaml: yaml, pubspecLock: lock);
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
