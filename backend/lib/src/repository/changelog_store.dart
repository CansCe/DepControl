import 'package:shared/shared.dart';

/// A package version whose changelog somebody wanted and nobody has read.
class ChangelogRequest {
  const ChangelogRequest({
    required this.ecosystem,
    required this.package,
    required this.version,
    this.requestedAt,
  });

  final String ecosystem;
  final String package;

  /// The version whose *archive* to read.
  ///
  /// One version, not a pair, because a changelog is cumulative: the archive of
  /// 3.0.0 carries the sections for 2.x and 1.x as well. Reading the version a
  /// project moved *to* populates every version it moved across, and every
  /// other project that later crosses any part of that range is served from
  /// what is already stored.
  final String version;

  final DateTime? requestedAt;

  @override
  String toString() => '$package $version ($ecosystem)';
}

/// Where release notes live between being read and being served.
///
/// Modelled on [ApiDiffStore], and for the same reason: the server never
/// fetches an archive, so a lookup that misses records what it wanted and
/// `tool/fill_changelogs.dart` drains the backlog. Demand comes from reports
/// somebody actually opened rather than a guess at which of pub.dev's packages
/// might be asked about.
///
/// Entries are not owner-scoped. What an author wrote about `yaml 3.1.3` is the
/// same text for everyone, and it names only published packages — so one
/// project's upgrade populates the notes for every other project that makes it.
abstract class ChangelogStore {
  /// Every stored section for [package], in no order.
  ///
  /// Deliberately not a range query. Which sections a move crosses is decided
  /// by [ChangelogParser.entriesBetween], and a store that also knew how
  /// versions compare would be a second place for that decision to live — and
  /// eventually to disagree. The set is bounded by one package's release
  /// history, which is a changelog's worth of rows rather than a registry's.
  Future<List<ChangelogEntry>> entriesFor(
    String package, {
    required String ecosystem,
  });

  /// Whether the archive at [version] has been read, whatever it yielded.
  ///
  /// Distinct from "there are entries": a package that ships no changelog reads
  /// successfully and stores nothing, and asking for it again every day would
  /// be a standing request that can never be satisfied.
  Future<bool> hasRead(
    String package, {
    required String ecosystem,
    required String version,
  });

  /// Records that [version]'s archive was read, and what came out of it.
  ///
  /// [entries] may be empty — that is the answer for a package with no
  /// changelog, and storing it is what stops it being asked for forever.
  Future<void> saveRead(
    String package, {
    required String ecosystem,
    required String version,
    required List<ChangelogEntry> entries,
    String? failure,
  });

  /// Records that somebody wanted this version's changelog and it was missing.
  Future<void> request(
    String package, {
    required String ecosystem,
    required String version,
  });

  /// Versions asked for and not yet read, oldest first.
  Future<List<ChangelogRequest>> pendingRequests({int limit = 50});
}

/// In-memory [ChangelogStore], used when no database is configured and by
/// tests. State is lost on restart, so every changelog has to be re-read.
class InMemoryChangelogStore implements ChangelogStore {
  /// `ecosystem:package@version` -> the entry published under it.
  final _entries = <String, ChangelogEntry>{};

  /// `ecosystem:package@version` of every archive that has been read.
  final _read = <String, String?>{};

  final _requests = <String, ChangelogRequest>{};

  static String _key(String ecosystem, String package, String version) =>
      '$ecosystem:$package@$version';

  @override
  Future<List<ChangelogEntry>> entriesFor(
    String package, {
    required String ecosystem,
  }) async {
    final prefix = '$ecosystem:$package@';
    return [
      for (final entry in _entries.entries)
        if (entry.key.startsWith(prefix)) entry.value,
    ];
  }

  @override
  Future<bool> hasRead(
    String package, {
    required String ecosystem,
    required String version,
  }) async =>
      _read.containsKey(_key(ecosystem, package, version));

  @override
  Future<void> saveRead(
    String package, {
    required String ecosystem,
    required String version,
    required List<ChangelogEntry> entries,
    String? failure,
  }) async {
    _read[_key(ecosystem, package, version)] = failure;
    for (final entry in entries) {
      _entries[_key(ecosystem, package, entry.version)] = entry;
    }
    _requests.remove(_key(ecosystem, package, version));
  }

  @override
  Future<void> request(
    String package, {
    required String ecosystem,
    required String version,
  }) async {
    final key = _key(ecosystem, package, version);
    if (_read.containsKey(key) || _requests.containsKey(key)) return;
    _requests[key] = ChangelogRequest(
      ecosystem: ecosystem,
      package: package,
      version: version,
      requestedAt: DateTime.now().toUtc(),
    );
  }

  // Appended only, so insertion order is already oldest-first — and unlike
  // sorting on the timestamps, it does not depend on two requests in the same
  // millisecond comparing unequal.
  @override
  Future<List<ChangelogRequest>> pendingRequests({int limit = 50}) async =>
      _requests.values.take(limit).toList();
}
