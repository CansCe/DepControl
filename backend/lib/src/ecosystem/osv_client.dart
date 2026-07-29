import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package_registry.dart';

/// Queries OSV.dev for a package's advisories.
///
/// pub.dev serves its own `/advisories` endpoint, which is a view onto the
/// GitHub Advisory Database. npm serves nothing comparable — `npm audit` is a
/// bulk endpoint built around a lockfile rather than a package, and it answers
/// in a shape of its own. OSV is the database both of those are downstream of,
/// and it speaks one format for every ecosystem, which is why [Advisory] parses
/// what comes back here without a line of translation.
///
/// Docs: https://google.github.io/osv.dev/post-v1-query/
class OsvClient {
  OsvClient({http.Client? client, this.baseUrl = 'https://api.osv.dev'})
      : _client = client ?? http.Client();

  final http.Client _client;
  final String baseUrl;

  static const _timeout = Duration(seconds: 20);

  /// Every advisory OSV holds for [package] in [ecosystem], unfiltered.
  ///
  /// [ecosystem] is OSV's own name for it — `npm`, `Pub`, `PyPI` — which is
  /// case-sensitive and not the same string as [Ecosystem.id].
  ///
  /// Deliberately queries without a version, so the caller receives everything
  /// and decides what applies. Asking OSV to filter would be one fewer thing to
  /// do here and would put the version matching behind a network call, where
  /// this application cannot test it or explain its answer — and matching an
  /// advisory to a version is the single most consequential judgement in a
  /// dependency report.
  ///
  /// Returns empty when OSV has nothing *or* cannot be reached. That is the
  /// same failure mode as pub.dev's advisories endpoint and it is a real
  /// weakness of both: a report cannot presently distinguish "no advisories"
  /// from "the advisory database was down". Callers should not read an empty
  /// list as a clean bill of health.
  Future<List<Advisory>> advisoriesFor(
    String package, {
    required String ecosystem,
  }) async {
    final body = await _post('/v1/query', {
      'package': {'name': package, 'ecosystem': ecosystem},
    });
    if (body == null) return const [];

    final vulns = body['vulns'];
    if (vulns is! List) return const [];

    return vulns
        .whereType<Map<String, dynamic>>()
        .map(Advisory.fromJson)
        .whereType<Advisory>()
        .toList();
  }

  Future<Map<String, dynamic>?> _post(
    String path,
    Map<String, dynamic> payload,
  ) async {
    final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$baseUrl$path'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(_timeout);
    } on TimeoutException {
      // One slow package must not fail a whole report; the node reports what
      // could not be established instead.
      return null;
    } on http.ClientException {
      return null;
    }

    if (response.statusCode != 200) return null;

    try {
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  void close() => _client.close();
}
