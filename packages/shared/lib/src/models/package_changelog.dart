/// What an author wrote about one published version.
class ChangelogEntry {
  const ChangelogEntry({
    required this.version,
    required this.notes,
    this.released,
  });

  /// The version this section documents, as the changelog spelled it.
  final String version;

  /// The section's body, as Markdown, with the heading removed.
  ///
  /// Kept verbatim rather than summarised. It is the author's account of their
  /// own release, and a paraphrase of it would be this application inventing
  /// claims about somebody else's software.
  final String notes;

  /// The release date, where the heading carried one — `## [1.2.3] - 2024-05-01`
  /// is a common convention. Null otherwise, which is most of the time.
  final DateTime? released;

  bool get isEmpty => notes.trim().isEmpty;

  factory ChangelogEntry.fromJson(Map<String, dynamic> json) => ChangelogEntry(
        version: json['version'] as String,
        notes: (json['notes'] as String?) ?? '',
        released: switch (json['released']) {
          final String s => DateTime.tryParse(s),
          _ => null,
        },
      );

  Map<String, dynamic> toJson() => {
        'version': version,
        'notes': notes,
        if (released != null) 'released': released!.toIso8601String(),
      };
}

/// The release notes covering one package's move between two versions.
///
/// Aggregated rather than linked. A link tells somebody where to go and read
/// twelve releases' worth of notes and work out which of them apply; this is
/// the ones that do.
class PackageChangelog {
  const PackageChangelog({
    required this.package,
    required this.ecosystem,
    required this.from,
    required this.to,
    this.entries = const [],
    this.note,
  });

  final String package;
  final String ecosystem;

  /// The version moved from, exclusive — its notes describe a release the
  /// project already had.
  final String from;

  /// The version moved to, inclusive.
  final String to;

  /// The sections covering `(from, to]`, newest first.
  final List<ChangelogEntry> entries;

  /// Why this is empty or partial, when it is.
  ///
  /// An empty list is ambiguous on its own — nobody has read the changelog yet,
  /// the package does not ship one, or it ships one this could not parse are
  /// three different situations and only one of them is worth waiting for.
  final String? note;

  bool get isEmpty => entries.isEmpty;

  factory PackageChangelog.fromJson(Map<String, dynamic> json) =>
      PackageChangelog(
        package: json['package'] as String,
        ecosystem: (json['ecosystem'] as String?) ?? 'dart',
        from: json['from'] as String,
        to: json['to'] as String,
        entries: [
          for (final entry in (json['entries'] as List?) ?? const [])
            ChangelogEntry.fromJson((entry as Map).cast<String, dynamic>()),
        ],
        note: json['note'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'package': package,
        'ecosystem': ecosystem,
        'from': from,
        'to': to,
        'entries': [for (final entry in entries) entry.toJson()],
        if (note != null) 'note': note,
      };
}
