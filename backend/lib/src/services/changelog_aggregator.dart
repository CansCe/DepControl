import 'package:pub_semver/pub_semver.dart';
import 'package:shared/shared.dart';

import '../repository/changelog_store.dart';
import 'changelog_parser.dart';

/// Turns "these packages moved" into "here is what their authors said about it".
///
/// Reads only. Where a version's archive has not been read, it records the want
/// and says so — `tool/fill_changelogs.dart` drains that backlog. The first
/// person to open a report gets "not read yet"; everyone after gets the notes,
/// including every other project that later crosses any part of the same range.
class ChangelogAggregator {
  const ChangelogAggregator(this._store);

  final ChangelogStore _store;

  /// The release notes for every version move in [diff].
  ///
  /// Only moves. An added package has no "since" to report from — its whole
  /// changelog is not news about an upgrade, it is the package — and a removed
  /// one has no notes anybody is about to act on.
  Future<List<PackageChangelog>> forDiff(ReportDiff diff) async {
    final changelogs = <PackageChangelog>[];

    for (final change in diff.moved) {
      final from = change.fromVersion;
      final to = change.toVersion;
      if (from == null || to == null) continue;

      changelogs.add(
        await forMove(
          package: change.name,
          ecosystem: change.ecosystem,
          from: from,
          to: to,
        ),
      );
    }

    return changelogs;
  }

  /// The release notes covering one package's move.
  Future<PackageChangelog> forMove({
    required String package,
    required String ecosystem,
    required String from,
    required String to,
  }) async {
    // What is stored comes first, before any question about which archive was
    // read. A changelog is cumulative, so another project's upgrade to 3.0.0
    // may already have stored the sections this move crosses — and asking
    // "was 2.0.0's archive read" would queue a fetch for notes already in hand.
    final stored = await _store.entriesFor(package, ecosystem: ecosystem);
    final entries = ChangelogParser.entriesBetween(stored, from: from, to: to);

    if (entries.isNotEmpty) {
      return PackageChangelog(
        package: package,
        ecosystem: ecosystem,
        from: from,
        to: to,
        entries: entries,
      );
    }

    // Nothing covers the range. Which of the two reasons that is decides
    // whether it is worth checking back on, so the archive that *would* hold
    // these sections settles it.
    //
    // The newer end, whichever way the move went: a newer archive carries the
    // older sections and not the other way round. A downgrade therefore reads
    // the version being left behind, which is exactly the one whose notes say
    // what is being given up.
    final archive = _newerOf(from, to);
    final read =
        await _store.hasRead(package, ecosystem: ecosystem, version: archive);

    if (!read) {
      // Recorded, not fetched. Downloading an archive has no business in a
      // request path — and a changelog nobody has read must never render as a
      // release that said nothing.
      await _store.request(package, ecosystem: ecosystem, version: archive);
    }

    return PackageChangelog(
      package: package,
      ecosystem: ecosystem,
      from: from,
      to: to,
      note: read
          ? 'The archive was read and nothing covers this range: the package '
              'may ship no changelog, or may not have written about these '
              'versions.'
          : 'Not read yet — queued. Run tool/fill_changelogs.dart, or wait '
              'for the next scheduled fill.',
    );
  }

  /// The later of two versions, or [to] when they cannot be compared.
  ///
  /// Falling back to [to] rather than refusing: an unreadable version is the
  /// `(unresolved)` sentinel or something equally unhelpful, and the version
  /// moved *to* is the better guess at which archive holds the most history.
  static String _newerOf(String from, String to) {
    final a = _tryParse(from);
    final b = _tryParse(to);
    if (a == null || b == null) return to;
    return a > b ? from : to;
  }

  static Version? _tryParse(String raw) {
    try {
      return Version.parse(raw.trim());
    } on FormatException {
      return null;
    }
  }
}
