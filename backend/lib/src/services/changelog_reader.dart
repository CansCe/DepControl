import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:shared/shared.dart';

import 'changelog_parser.dart';

/// Raised when an archive is refused rather than read.
class ChangelogUnavailable implements Exception {
  const ChangelogUnavailable(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// Fetches a published version's archive and reads its `CHANGELOG.md`.
///
/// **Never called from a request.** Downloading and decompressing a package
/// archive has no business in a request path, so this runs from
/// `tool/fill_changelogs.dart` and the API only ever reads what was stored —
/// the same split `tools/api_differ` and [ApiDiffStore] already use.
///
/// One fetch answers many questions. A changelog is cumulative: the archive of
/// version 3.0.0 contains the sections for 2.x and 1.x as well, so reading the
/// newest version a project moved to populates every version it moved across.
/// That is why the backlog is keyed on a single version rather than on a pair.
///
/// The fetch is deliberately narrow, for the same reasons [PubArchiveClient]
/// is:
///
/// * the URL is **constructed**, never taken from metadata, and the package
///   name and version are validated before a request is made;
/// * the archive is decompressed **in memory**, so a crafted entry path has
///   nowhere to escape to — tar traversal is impossible rather than mitigated;
/// * compressed size, expanded size and file count are capped, so a
///   decompression bomb fails instead of exhausting the process;
/// * only the changelog is decoded, and nothing is executed.
class ChangelogReader {
  ChangelogReader({
    http.Client? client,
    this.maxCompressedBytes = 8 * 1024 * 1024,
    this.maxDecompressedBytes = 40 * 1024 * 1024,
    this.maxFiles = 4000,
    this.maxChangelogBytes = 2 * 1024 * 1024,
    this.timeout = const Duration(seconds: 30),
    this.pubHost = 'pub.dev',
    this.npmHost = 'registry.npmjs.org',
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final int maxCompressedBytes;
  final int maxDecompressedBytes;
  final int maxFiles;

  /// A changelog is prose. Anything past this is generated, and decoding it
  /// would cost more than the answer is worth.
  final int maxChangelogBytes;

  final Duration timeout;
  final String pubHost;
  final String npmHost;

  /// Package names, per ecosystem, and versions. Validated rather than escaped:
  /// both arrive from a fetched manifest, and an unchecked name is interpolated
  /// into a request path.
  static final _dartName = RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]{0,63}$');
  static final _npmName = RegExp(
    r'^(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$',
  );
  static final _version = RegExp(r'^[0-9A-Za-z.\-+]{1,64}$');

  /// The changelog entries published in [package] at [version], newest first.
  ///
  /// Returns an empty list when the package ships no changelog — which is
  /// ordinary and is not an error. Throws [ChangelogUnavailable] when the
  /// archive could not be had or refused a cap, which is a different answer and
  /// one the caller records rather than retries forever.
  Future<List<ChangelogEntry>> read(
    String package,
    String version, {
    String ecosystem = 'dart',
  }) async {
    final url = _archiveUrlFor(package, version, ecosystem);
    final bytes = await _download(url, '$package $version');
    final markdown = extractChangelog(bytes, label: '$package $version');
    return markdown == null ? const [] : ChangelogParser.parse(markdown);
  }

  /// Where a published version's archive lives.
  ///
  /// Constructed from validated parts rather than read from the registry's
  /// metadata — npm publishes a `dist.tarball` URL, and following it would let
  /// a package's own publisher choose which host this server contacts.
  Uri _archiveUrlFor(String package, String version, String ecosystem) {
    if (!_version.hasMatch(version)) {
      throw ChangelogUnavailable('Not a version: "$version"');
    }

    switch (ecosystem) {
      case 'dart':
        if (!_dartName.hasMatch(package)) {
          throw ChangelogUnavailable('Not a package name: "$package"');
        }
        return Uri.https(pubHost, '/api/archives/$package-$version.tar.gz');

      case 'npm':
        if (!_npmName.hasMatch(package) ||
            package.length > 214 ||
            package.contains('..')) {
          throw ChangelogUnavailable('Not a package name: "$package"');
        }
        // A scoped package's tarball sits under the *unscoped* name:
        // `@babel/core` is at `/@babel/core/-/core-7.0.0.tgz`.
        final bare = package.startsWith('@') ? package.split('/').last : package;
        return Uri.https(npmHost, '/$package/-/$bare-$version.tgz');

      default:
        throw ChangelogUnavailable(
          'No archive location is known for the "$ecosystem" ecosystem.',
        );
    }
  }

  Future<List<int>> _download(Uri url, String label) async {
    final http.Response response;
    try {
      response = await _client.get(url).timeout(timeout);
    } on TimeoutException {
      throw ChangelogUnavailable('Timed out fetching $label.');
    } on http.ClientException catch (e) {
      throw ChangelogUnavailable('Could not fetch $label: ${e.message}');
    }

    // A version that was never published, or was retracted. Not an error worth
    // retrying, and the caller records it as read-with-nothing-found.
    if (response.statusCode == 404) return const [];
    if (response.statusCode != 200) {
      throw ChangelogUnavailable(
        'Unexpected status ${response.statusCode} for $label.',
      );
    }

    final bytes = response.bodyBytes;
    if (bytes.length > maxCompressedBytes) {
      throw ChangelogUnavailable(
        '$label is ${bytes.length} bytes, over the $maxCompressedBytes limit.',
      );
    }
    return bytes;
  }

  /// The `CHANGELOG.md` inside a gzipped tar, or null when there is none.
  ///
  /// Exposed so the caps can be exercised without a network.
  String? extractChangelog(List<int> bytes, {required String label}) {
    if (bytes.isEmpty) return null;

    final Archive archive;
    try {
      archive = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
    } catch (e) {
      throw ChangelogUnavailable('$label is not a readable archive: $e');
    }

    var expanded = 0;
    var seen = 0;

    for (final entry in archive) {
      if (++seen > maxFiles) {
        throw ChangelogUnavailable('$label holds over $maxFiles files.');
      }
      if (!entry.isFile) continue;

      expanded += entry.size;
      if (expanded > maxDecompressedBytes) {
        throw ChangelogUnavailable(
          '$label expands past $maxDecompressedBytes bytes.',
        );
      }

      // Normalised for comparison only. The path never opens anything, because
      // nothing is written out.
      final path = entry.name.replaceAll(r'\', '/');
      if (!_isChangelog(path)) continue;

      if (entry.size > maxChangelogBytes) {
        throw ChangelogUnavailable(
          '$label ships a changelog of ${entry.size} bytes, over the '
          '$maxChangelogBytes limit.',
        );
      }

      return utf8.decode(entry.readBytes() ?? const [], allowMalformed: true);
    }

    return null;
  }

  /// Whether an archive path is the package's changelog.
  ///
  /// At the root only. A changelog under `example/` or `test/fixtures/` belongs
  /// to something else, and npm packages in particular ship other projects'
  /// files more often than one would like.
  ///
  /// npm archives wrap everything in a `package/` directory that is not part of
  /// any path the package itself knows, so it is stripped first.
  static bool _isChangelog(String path) {
    final withoutWrapper =
        path.startsWith('package/') ? path.substring('package/'.length) : path;
    if (withoutWrapper.contains('/')) return false;

    return const {
      'changelog.md',
      'changelog',
      'changelog.markdown',
      'changes.md',
      'history.md',
    }.contains(withoutWrapper.toLowerCase());
  }

  void close() => _client.close();
}
