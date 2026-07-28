import 'package:shared/shared.dart';

/// A pair of versions someone wanted compared, and when they asked.
class ApiDiffRequest {
  const ApiDiffRequest({
    required this.package,
    required this.from,
    required this.to,
    this.requestedAt,
  });

  final String package;
  final String from;
  final String to;
  final DateTime? requestedAt;

  @override
  String toString() => '$package $from -> $to';
}

/// Where public-API diffs live between being computed and being served.
///
/// The server never computes one. `tools/api_differ` fetches package archives
/// and parses Dart, neither of which belongs in a request path, and it is
/// pinned to an analyzer this workspace cannot resolve — so it runs out of
/// process and writes here, and the API only ever reads.
///
/// That split needs a way to know what is worth computing, which is what
/// [request] is for: a lookup that misses records the pair, and
/// [pendingRequests] hands the backlog to whoever runs the differ. Demand comes
/// from real page views rather than a guess at which of pub.dev's packages
/// someone might ask about.
///
/// Diffs are not scoped to an owner: `yaml 3.1.2 -> 3.1.3` is the same
/// comparison for everyone, and it names only published packages.
abstract class ApiDiffStore {
  /// The stored comparison of [package] between [from] and [to], or null when
  /// nobody has computed it yet.
  Future<ApiDiff?> find(String package,
      {required String from, required String to});

  /// Stores [diff], replacing any earlier copy, and clears a pending request
  /// for the same pair.
  Future<void> save(ApiDiff diff);

  /// Records that this comparison was asked for and is missing. Asking twice
  /// keeps the first request's timestamp — the backlog is a set of pairs, not a
  /// hit count.
  Future<void> request(String package,
      {required String from, required String to});

  /// Comparisons that have been asked for and not yet computed, oldest first.
  Future<List<ApiDiffRequest>> pendingRequests({int limit = 50});
}

/// In-memory [ApiDiffStore], used when no database is configured and by tests.
/// State is lost on restart, so every diff has to be recomputed.
class InMemoryApiDiffStore implements ApiDiffStore {
  final _diffs = <String, ApiDiff>{};
  final _requests = <String, ApiDiffRequest>{};

  @override
  Future<ApiDiff?> find(
    String package, {
    required String from,
    required String to,
  }) async =>
      _diffs[_key(package, from, to)];

  @override
  Future<void> save(ApiDiff diff) async {
    final key = _key(diff.package, diff.from, diff.to);
    _diffs[key] = diff.generatedAt == null
        ? ApiDiff(
            package: diff.package,
            from: diff.from,
            to: diff.to,
            changes: diff.changes,
            generatedAt: DateTime.now().toUtc(),
          )
        : diff;
    _requests.remove(key);
  }

  @override
  Future<void> request(
    String package, {
    required String from,
    required String to,
  }) async {
    final key = _key(package, from, to);
    if (_diffs.containsKey(key) || _requests.containsKey(key)) return;
    _requests[key] = ApiDiffRequest(
      package: package,
      from: from,
      to: to,
      requestedAt: DateTime.now().toUtc(),
    );
  }

  // Requests are only ever appended, so the map's insertion order is already
  // oldest-first — and unlike sorting on the timestamps, it does not depend on
  // two requests in the same millisecond comparing unequal.
  @override
  Future<List<ApiDiffRequest>> pendingRequests({int limit = 50}) async =>
      _requests.values.take(limit).toList();

  static String _key(String package, String from, String to) =>
      '$package@$from->$to';
}
