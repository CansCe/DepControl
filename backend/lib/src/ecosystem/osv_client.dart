import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../services/request_cache.dart';
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

  /// Advisory lookups already made, keyed `ecosystem:package`.
  ///
  /// One query per package per *scan*, rather than per package per manifest.
  /// An advisory list is a few small documents even for a package with a long
  /// history, so this is cheap to hold and it removes a whole round trip from
  /// every repeated package in a monorepo.
  ///
  /// Deliberately short-lived. An advisory appearing is the single most
  /// consequential thing this application exists to notice, and a cache with
  /// no expiry would mean a server that has been up for a week reports the
  /// advisories that existed when it started.
  final _queries = RequestCache<String, _Queried>(
    capacity: 2000,
    ttl: const Duration(minutes: 10),
  );

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
    final result = await _queries.run(
      '$ecosystem:$package',
      () => _query(package, ecosystem),
      // An unreachable OSV must not be remembered as a clean bill of health.
      keep: (result) => result.answered,
    );
    return result.advisories;
  }

  Future<_Queried> _query(String package, String ecosystem) async {
    final fetched = await _post('/v1/query', {
      'package': {'name': package, 'ecosystem': ecosystem},
    });
    if (fetched.json == null) {
      return (advisories: const <Advisory>[], answered: fetched.answered);
    }

    final vulns = fetched.json!['vulns'];
    if (vulns is! List) return (advisories: const <Advisory>[], answered: true);

    return (
      advisories: vulns
          .whereType<Map<String, dynamic>>()
          .map(Advisory.fromJson)
          .whereType<Advisory>()
          .toList(),
      answered: true,
    );
  }

  /// POSTs [payload] to [path] and decodes the reply.
  ///
  /// Reports whether OSV answered as well as what it said. The distinction did
  /// not matter while every query went to the network, because an empty list
  /// was recomputed the next time somebody asked; now that answers are cached
  /// it decides whether a moment of unreachability gets remembered as "this
  /// package has no advisories" for the rest of the process's life.
  Future<_Fetched> _post(
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
      return (json: null, answered: false);
    } on http.ClientException {
      return (json: null, answered: false);
    }

    if (response.statusCode >= 500) return (json: null, answered: false);
    if (response.statusCode != 200) return (json: null, answered: true);

    try {
      final decoded = jsonDecode(response.body);
      return (
        json: decoded is Map<String, dynamic> ? decoded : null,
        answered: true,
      );
    } on FormatException {
      return (json: null, answered: true);
    }
  }

  void close() => _client.close();
}

/// One POST's outcome: what OSV said, and whether it said anything.
typedef _Fetched = ({Map<String, dynamic>? json, bool answered});

/// A cached advisory lookup, carrying whether OSV was reachable.
typedef _Queried = ({List<Advisory> advisories, bool answered});
