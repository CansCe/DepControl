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
/// Phase 1 implementation targets the common hosts (GitHub/GitLab) via their
/// raw-file HTTP endpoints, avoiding a full clone. For arbitrary hosts, swap in
/// a shallow `git archive` in a sandboxed temp dir (see [fetchViaGitArchive]).
class GitFetcher {
  GitFetcher({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<FetchedPubspecs> fetch(String gitUrl, {String ref = 'HEAD'}) async {
    final raw = _rawBaseFor(gitUrl, ref);
    if (raw == null) {
      // TODO(phase2): fall back to `git archive` for non-GitHub/GitLab hosts.
      throw UnsupportedError(
        'Only GitHub/GitLab URLs are supported in the scaffold: $gitUrl',
      );
    }

    final yaml = await _get('$raw/pubspec.yaml');
    if (yaml == null) {
      throw StateError('No pubspec.yaml found at $gitUrl ($ref).');
    }
    final lock = await _get('$raw/pubspec.lock');
    return FetchedPubspecs(pubspecYaml: yaml, pubspecLock: lock);
  }

  Future<String?> _get(String url) async {
    final res = await _client.get(Uri.parse(url));
    return res.statusCode == 200 ? utf8.decode(res.bodyBytes) : null;
  }

  /// Maps a repo URL to its raw-content base, or null if unsupported.
  static String? _rawBaseFor(String gitUrl, String ref) {
    final u = Uri.parse(gitUrl.replaceAll(RegExp(r'\.git$'), ''));
    final segs = u.pathSegments;
    if (segs.length < 2) return null;
    final owner = segs[0];
    final repo = segs[1];
    final r = ref == 'HEAD' ? 'HEAD' : ref;
    switch (u.host) {
      case 'github.com':
        return 'https://raw.githubusercontent.com/$owner/$repo/$r';
      case 'gitlab.com':
        return 'https://gitlab.com/$owner/$repo/-/raw/$r';
      default:
        return null;
    }
  }

  /// Placeholder for the sandboxed shallow-fetch path (Phase 2/4).
  Future<FetchedPubspecs> fetchViaGitArchive(String gitUrl, String ref) {
    throw UnimplementedError('Sandboxed git archive fetch — Phase 2.');
  }

  void close() => _client.close();
}
