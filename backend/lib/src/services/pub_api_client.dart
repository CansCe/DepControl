import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart';

/// A security advisory published for a package, in the OSV shape pub.dev serves.
///
/// An advisory applies to specific versions, not to the package as a whole, so
/// [affects] must be consulted before reporting a dependency as vulnerable.
class Advisory {
  const Advisory({
    required this.id,
    this.aliases = const [],
    this.summary,
    this.affectedVersions = const {},
    this.ranges = const [],
  });

  final String id;

  /// Other identifiers for the same issue, e.g. `CVE-2020-35669`.
  final List<String> aliases;
  final String? summary;

  /// Exact versions pub.dev lists as affected. Authoritative when present.
  final Set<String> affectedVersions;

  /// Version ranges, used when no explicit version list is published.
  final List<AdvisoryRange> ranges;

  /// Whether [version] is actually affected by this advisory.
  bool affects(Version version) {
    if (affectedVersions.isNotEmpty) {
      return affectedVersions.contains(version.toString());
    }
    if (ranges.isEmpty) return false;
    return ranges.any((r) => r.contains(version));
  }

  static Advisory? fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString();
    if (id == null) return null;

    final affected = (json['affected'] as List?) ?? const [];
    final versions = <String>{};
    final ranges = <AdvisoryRange>[];

    for (final entry in affected.whereType<Map<String, dynamic>>()) {
      versions.addAll(
        ((entry['versions'] as List?) ?? const []).map((v) => v.toString()),
      );
      for (final range in ((entry['ranges'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()) {
        ranges.addAll(AdvisoryRange.fromEvents(range['events'] as List?));
      }
    }

    return Advisory(
      id: id,
      aliases:
          ((json['aliases'] as List?) ?? const []).map((a) => '$a').toList(),
      summary: json['summary']?.toString(),
      affectedVersions: versions,
      ranges: ranges,
    );
  }
}

/// A half-open version range `[introduced, fixed)`, as described by OSV events.
class AdvisoryRange {
  const AdvisoryRange({this.introduced, this.fixed, this.lastAffected});

  final Version? introduced;
  final Version? fixed;
  final Version? lastAffected;

  bool contains(Version version) {
    if (introduced != null && version < introduced!) return false;
    if (fixed != null && version >= fixed!) return false;
    if (lastAffected != null && version > lastAffected!) return false;
    return true;
  }

  /// Walks an OSV `events` array, which is an ordered stream of `introduced`
  /// and `fixed`/`last_affected` markers rather than a list of range objects.
  static List<AdvisoryRange> fromEvents(List<dynamic>? events) {
    if (events == null) return const [];

    final ranges = <AdvisoryRange>[];
    Version? introduced;
    var open = false;

    for (final event in events.whereType<Map<String, dynamic>>()) {
      if (event['introduced'] != null) {
        introduced = _parse('${event['introduced']}');
        open = true;
      }
      if (event['fixed'] != null) {
        ranges.add(
          AdvisoryRange(
            introduced: introduced,
            fixed: _parse('${event['fixed']}'),
          ),
        );
        open = false;
      } else if (event['last_affected'] != null) {
        ranges.add(
          AdvisoryRange(
            introduced: introduced,
            lastAffected: _parse('${event['last_affected']}'),
          ),
        );
        open = false;
      }
    }

    // An `introduced` with no closing event means everything from there on.
    if (open) ranges.add(AdvisoryRange(introduced: introduced));
    return ranges;
  }

  /// OSV uses `"0"` to mean "from the beginning", which is not valid semver.
  static Version? _parse(String raw) {
    if (raw == '0') return Version.none;
    try {
      return Version.parse(raw);
    } on FormatException {
      return null;
    }
  }
}

/// Latest version + advisory info for a package from pub.dev.
class PubInfo {
  const PubInfo({required this.latest, this.advisories = const []});

  final String? latest;

  /// Every advisory published for the package, unfiltered. Callers must use
  /// [Advisory.affects] to decide which apply to the version in use.
  final List<Advisory> advisories;
}

/// Thin client over the public pub.dev API.
///
/// Docs: https://pub.dev/help/api
class PubApiClient {
  PubApiClient({http.Client? client, this.baseUrl = 'https://pub.dev'})
      : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;

  Future<PubInfo> info(String package) async {
    final latest = await _latest(package);
    final advisories = await _advisories(package);
    return PubInfo(latest: latest, advisories: advisories);
  }

  Future<String?> _latest(String package) async {
    final res =
        await _client.get(Uri.parse('$baseUrl/api/packages/$package'));
    if (res.statusCode != 200) return null;
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final latest = json['latest'] as Map<String, dynamic>?;
    return latest?['version'] as String?;
  }

  Future<List<Advisory>> _advisories(String package) async {
    final res = await _client
        .get(Uri.parse('$baseUrl/api/packages/$package/advisories'));
    if (res.statusCode != 200) return const [];
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final list = (json['advisories'] as List?) ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(Advisory.fromJson)
        .whereType<Advisory>()
        .toList();
  }

  /// The names of the regular (non-dev) dependencies declared by a specific
  /// published version of [package]. Used to build the dependency graph's
  /// edges. Returns empty for versions pub.dev doesn't know (git/sdk/path deps).
  ///
  /// Endpoint: `/api/packages/<package>/versions/<version>` -> `pubspec`.
  Future<List<String>> dependencyNames(String package, String version) async {
    final res = await _client.get(
      Uri.parse('$baseUrl/api/packages/$package/versions/$version'),
    );
    if (res.statusCode != 200) return const [];
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final pubspec = json['pubspec'] as Map<String, dynamic>?;
    final deps = pubspec?['dependencies'] as Map<String, dynamic>?;
    return deps?.keys.toList() ?? const [];
  }

  void close() => _client.close();
}
