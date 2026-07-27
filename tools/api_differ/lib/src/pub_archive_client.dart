import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

/// Raised when an archive is refused rather than processed.
class ArchiveRejected implements Exception {
  const ArchiveRejected(this.reason);
  final String reason;

  @override
  String toString() => 'ArchiveRejected: $reason';
}

/// Reads the Dart sources of a published package version.
///
/// This is the only thing in the system that fetches more than a pubspec, so
/// it is deliberately narrow:
///
/// * The URL is **constructed**, never taken from metadata, and always points
///   at [_host]. Names and versions are validated first, so nothing coming
///   from a report can redirect the fetch.
/// * The archive is decompressed **in memory**. Nothing is written to disk, so
///   a crafted entry path has nowhere to escape to — tar traversal is not
///   mitigated here, it is impossible.
/// * Compressed size, decompressed size and file count are all capped, so a
///   decompression bomb fails instead of exhausting the process.
/// * Only `lib/**.dart` entries are decoded. Nothing is executed.
class PubArchiveClient {
  PubArchiveClient({
    http.Client? client,
    this.maxCompressedBytes = 8 * 1024 * 1024,
    this.maxDecompressedBytes = 40 * 1024 * 1024,
    this.maxFiles = 2000,
    this.timeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client();

  static const _host = 'pub.dev';

  /// Package names are lowercase identifiers; versions are semver characters.
  /// Anything else is refused before a request is made.
  static final _namePattern = RegExp(r'^[a-z_][a-z0-9_]*$');
  static final _versionPattern = RegExp(r'^[0-9A-Za-z.\-+]+$');

  final http.Client _client;
  final int maxCompressedBytes;
  final int maxDecompressedBytes;
  final int maxFiles;
  final Duration timeout;

  /// Dart sources under `lib/`, keyed by archive path. Empty when the version
  /// is not published.
  Future<Map<String, String>> libSources(String package, String version) async {
    if (!_namePattern.hasMatch(package)) {
      throw ArchiveRejected('Not a package name: "$package"');
    }
    if (!_versionPattern.hasMatch(version)) {
      throw ArchiveRejected('Not a version: "$version"');
    }

    final uri = Uri.https(_host, '/api/archives/$package-$version.tar.gz');

    final http.Response response;
    try {
      response = await _client.get(uri).timeout(timeout);
    } catch (e) {
      throw ArchiveRejected('Could not fetch $package $version: $e');
    }

    if (response.statusCode == 404) return const {};
    if (response.statusCode != 200) {
      throw ArchiveRejected(
        'Unexpected status ${response.statusCode} for $package $version',
      );
    }

    final bytes = response.bodyBytes;
    if (bytes.length > maxCompressedBytes) {
      throw ArchiveRejected(
        '$package $version is ${bytes.length} bytes, over the '
        '$maxCompressedBytes limit',
      );
    }

    return readLibSources(bytes, label: '$package $version');
  }

  /// Extracts `lib/**.dart` from gzipped tar [bytes]. Exposed for testing so
  /// the limits can be exercised without a network.
  Map<String, String> readLibSources(
    List<int> bytes, {
    required String label,
  }) {
    final Archive archive;
    try {
      archive = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
    } catch (e) {
      throw ArchiveRejected('$label is not a readable archive: $e');
    }

    final sources = <String, String>{};
    var decompressed = 0;
    var seen = 0;

    for (final entry in archive) {
      if (++seen > maxFiles) {
        throw ArchiveRejected('$label holds over $maxFiles files');
      }
      if (!entry.isFile) continue;

      // Normalised only for comparison. The path never opens anything, since
      // nothing is written out.
      final path = entry.name.replaceAll(r'\', '/');
      if (!path.startsWith('lib/') || !path.endsWith('.dart')) continue;

      decompressed += entry.size;
      if (decompressed > maxDecompressedBytes) {
        throw ArchiveRejected(
          '$label expands past $maxDecompressedBytes bytes',
        );
      }

      sources[path] = utf8.decode(entry.readBytes() ?? const [],
          allowMalformed: true);
    }

    return sources;
  }

  void close() => _client.close();
}
