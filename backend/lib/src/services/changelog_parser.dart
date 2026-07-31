import 'package:pub_semver/pub_semver.dart';
import 'package:shared/shared.dart';

/// Reads a `CHANGELOG.md` into the sections a version move crosses.
///
/// There is no changelog format, only a convention: a heading per release,
/// naming a version, with the notes underneath. Every variation on that
/// convention is in the wild — `## 1.2.3`, `# [1.2.3]`, `## [1.2.3] - 2024-05-01`,
/// `## v1.2.3`, `## 1.2.3 (2024-05-01)` — and a parser that insists on one of
/// them reads most changelogs as empty.
///
/// So this is deliberately permissive about the heading and completely
/// unopinionated about the body: anything between two release headings is that
/// release's notes, kept verbatim. It is the author's account of their own
/// software, and rewriting it would be this application making claims about
/// somebody else's work.
///
/// Where it cannot find a version it says so rather than guessing. A changelog
/// nobody can parse and a package with no changelog are different answers, and
/// only one of them is worth a second look.
abstract final class ChangelogParser {
  /// Every release section in [markdown], in the order it appears.
  ///
  /// A changelog is conventionally newest-first, but that is not relied on:
  /// callers that need an order sort by version, and [entriesBetween] does.
  static List<ChangelogEntry> parse(String markdown) {
    final lines = markdown.split('\n');

    final headings = <({int line, String version, DateTime? released})>[];
    var inFence = false;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];

      // A fenced code block can contain anything, including something that
      // looks exactly like a heading. Tracked rather than ignored because
      // migration instructions in release notes routinely paste YAML with
      // `## 1.2.3` in it.
      if (_fence.hasMatch(line.trimLeft())) {
        inFence = !inFence;
        continue;
      }
      if (inFence) continue;

      final heading = _headingOf(line);
      if (heading != null) headings.add((line: i, version: heading.version, released: heading.released));
    }

    final entries = <ChangelogEntry>[];
    for (var i = 0; i < headings.length; i++) {
      final start = headings[i].line + 1;
      final end = i + 1 < headings.length ? headings[i + 1].line : lines.length;
      final body = lines.sublist(start, end).join('\n').trim();

      entries.add(
        ChangelogEntry(
          version: headings[i].version,
          notes: body,
          released: headings[i].released,
        ),
      );
    }

    return entries;
  }

  /// The sections covering `(from, to]`, newest first.
  ///
  /// Half-open at the bottom on purpose: `from`'s notes describe a release the
  /// project already had, and including them would present old news as part of
  /// an upgrade.
  ///
  /// Versions that cannot be parsed as semver are dropped rather than guessed
  /// at — an entry that cannot be placed in the range cannot be said to be in
  /// it. Where `from` or `to` themselves are unreadable, nothing is returned,
  /// because every entry would be equally unplaceable.
  static List<ChangelogEntry> entriesBetween(
    List<ChangelogEntry> entries, {
    required String from,
    required String to,
  }) {
    final lower = _tryParse(from);
    final upper = _tryParse(to);
    if (lower == null || upper == null) return const [];

    // A downgrade has release notes too — the ones being given up — and which
    // direction the reader is going is their business, not this function's.
    final low = lower < upper ? lower : upper;
    final high = lower < upper ? upper : lower;

    final within = <({Version version, ChangelogEntry entry})>[];
    for (final entry in entries) {
      final version = _tryParse(entry.version);
      if (version == null) continue;
      if (version <= low || version > high) continue;
      within.add((version: version, entry: entry));
    }

    within.sort((a, b) => b.version.compareTo(a.version));
    return [for (final each in within) each.entry];
  }

  /// A Markdown heading naming a version, or null.
  ///
  /// Only `#` headings count. A bold line or a bare version on its own is used
  /// by some projects, but matching those turns any line beginning with a
  /// number into a release boundary and shreds the notes.
  static ({String version, DateTime? released})? _headingOf(String line) {
    final heading = _heading.firstMatch(line);
    if (heading == null) return null;

    final text = heading.group(1)!.trim();
    final version = _version.firstMatch(text);
    if (version == null) return null;

    // The heading has to be *about* the version rather than merely mention it.
    // `## Upgrading to 2.0.0` is prose in someone's notes, not a release
    // boundary, and treating it as one splits that release in half.
    if (version.start > 2) return null;

    return (version: version.group(1)!, released: _dateIn(text));
  }

  /// A date in a heading, in the two spellings that turn up:
  /// `## 1.2.3 - 2024-05-01` and `## 1.2.3 (2024-05-01)`.
  ///
  /// Read as UTC. A changelog date carries no timezone because it is a calendar
  /// date rather than an instant, and `DateTime.parse` would otherwise make it
  /// local — so the same changelog would report a different release date
  /// depending on where the server happened to be running.
  static DateTime? _dateIn(String text) {
    final match = _date.firstMatch(text);
    if (match == null) return null;
    return DateTime.tryParse('${match.group(1)!}T00:00:00Z');
  }

  static Version? _tryParse(String raw) {
    try {
      return Version.parse(raw.trim());
    } on FormatException {
      return null;
    }
  }

  /// `#` through `######`, capturing the text after it.
  static final _heading = RegExp(r'^\s{0,3}#{1,6}\s+(.*)$');

  /// A version at the head of a heading, optionally wrapped in the brackets
  /// `keep a changelog` uses and optionally prefixed `v`.
  static final _version = RegExp(
    r'^\[?v?(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.\-]+)?)\]?',
  );

  static final _date = RegExp(r'(\d{4}-\d{2}-\d{2})');

  /// A fenced code block, in either spelling.
  static final _fence = RegExp('^(```|~~~)');
}
