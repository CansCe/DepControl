import 'dart:convert';

import 'package:http/http.dart' as http;

/// Latest version + advisory info for a package from pub.dev.
class PubInfo {
  const PubInfo({required this.latest, this.advisoryIds = const []});

  final String? latest;
  final List<String> advisoryIds;
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
    final advisories = await _advisoryIds(package);
    return PubInfo(latest: latest, advisoryIds: advisories);
  }

  Future<String?> _latest(String package) async {
    final res =
        await _client.get(Uri.parse('$baseUrl/api/packages/$package'));
    if (res.statusCode != 200) return null;
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final latest = json['latest'] as Map<String, dynamic>?;
    return latest?['version'] as String?;
  }

  Future<List<String>> _advisoryIds(String package) async {
    final res = await _client
        .get(Uri.parse('$baseUrl/api/packages/$package/advisories'));
    if (res.statusCode != 200) return const [];
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final list = (json['advisories'] as List?) ?? const [];
    return list
        .map((a) => (a as Map<String, dynamic>)['id']?.toString())
        .whereType<String>()
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
